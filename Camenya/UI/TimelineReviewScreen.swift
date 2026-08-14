import AVFoundation
import SwiftUI

struct TimelinePlaybackSource: Equatable, Sendable {
    let url: URL
    let selection: TakeRange?

    static func make(snapshot: ExportSnapshot) -> [TimelinePlaybackSource] {
        snapshot.clips.map {
            TimelinePlaybackSource(url: $0.mediaURL, selection: $0.selection)
        }
    }
}

struct TimelineReviewScreen: View {
    @StateObject private var playback: TimelinePlaybackController
    @Environment(\.dismiss) private var dismiss
    let title: String
    let format: ProjectFormat

    init(sources: [TimelinePlaybackSource], title: String, format: ProjectFormat) {
        _playback = StateObject(wrappedValue: TimelinePlaybackController(sources: sources))
        self.title = title
        self.format = format
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                PlayerLayerView(player: playback.player)
                    .aspectRatio(format == .portrait ? 9 / 16 : 16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Plays every Take in the current Timeline order with hard cuts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(playback.isPlaying ? "Pause" : "Play Project", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.togglePlayback()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onDisappear { playback.pause() }
    }
}

@MainActor
final class TimelinePlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    let player: AVQueuePlayer
    private let sources: [TimelinePlaybackSource]
    private var completedItemCount = 0
    private var completionObservers: [NSObjectProtocol] = []
    private var preparationTask: Task<Void, Never>?

    init(sources: [TimelinePlaybackSource]) {
        self.sources = sources
        player = AVQueuePlayer()
        reloadQueue()
    }

    deinit {
        preparationTask?.cancel()
        completionObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func togglePlayback() {
        if player.rate == 0 {
            if player.items().isEmpty { return }
            player.play()
        } else {
            player.pause()
        }
        isPlaying = player.rate != 0
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    private func itemDidFinish() {
        completedItemCount += 1
        guard completedItemCount >= sources.count else { return }
        player.pause()
        reloadQueue()
        isPlaying = false
    }

    private func reloadQueue() {
        completionObservers.forEach(NotificationCenter.default.removeObserver)
        completionObservers.removeAll()
        player.removeAllItems()
        preparationTask?.cancel()
        completedItemCount = 0
        preparationTask = Task { [weak self, sources] in
            guard let self else { return }
            var items: [AVPlayerItem] = []
            for source in sources {
                if Task.isCancelled { return }
                let item = AVPlayerItem(url: source.url)
                if let selection = source.selection {
                    let asset = AVURLAsset(url: source.url)
                    let videoRange = try? await asset.loadTracks(withMediaType: .video).first?.load(.timeRange)
                    let mediaStart = videoRange?.start.seconds ?? 0
                    item.forwardPlaybackEndTime = CMTime(
                        seconds: mediaStart + selection.end.seconds,
                        preferredTimescale: 600
                    )
                    await withCheckedContinuation { continuation in
                        item.seek(
                            to: CMTime(seconds: mediaStart + selection.start.seconds, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        ) { _ in continuation.resume() }
                    }
                }
                items.append(item)
            }
            guard !Task.isCancelled else { return }
            install(items: items)
        }
    }

    private func install(items: [AVPlayerItem]) {
        for item in items {
            completionObservers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.itemDidFinish() }
            })
            player.insert(item, after: nil)
        }
    }
}
