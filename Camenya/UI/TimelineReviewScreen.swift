import AVFoundation
import SwiftUI

struct TimelinePlaybackSource: Equatable, Sendable {
    let url: URL
    let selection: TakeRange?
    let sourceRange: TakeRange?

    init(url: URL, selection: TakeRange?, sourceRange: TakeRange? = nil) {
        self.url = url
        self.selection = selection
        self.sourceRange = sourceRange
    }

    static func make(snapshot: ExportSnapshot) -> [TimelinePlaybackSource] {
        snapshot.clips.map {
            TimelinePlaybackSource(
                url: $0.mediaURL,
                selection: $0.selection,
                sourceRange: $0.sourceRange
            )
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
                Group {
                    if playback.preparationFailed {
                        ContentUnavailableView {
                            Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("Camenya couldn't prepare the selected clips. Your Takes are unchanged.")
                        } actions: {
                            Button("Retry Preview", systemImage: "arrow.clockwise") {
                                playback.retryPreparation()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        PlayerLayerView(player: playback.player)
                            .background(.black)
                    }
                }
                .aspectRatio(format == .portrait ? 9 / 16 : 16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text("Plays every Take in the current Timeline order with hard cuts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !playback.preparationFailed {
                    Button(playback.isPlaying ? "Pause" : "Play Project", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                        playback.togglePlayback()
                    }
                    .buttonStyle(.borderedProminent)
                }
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
    @Published private(set) var preparationFailed = false
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

    func retryPreparation() {
        reloadQueue()
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
        preparationFailed = false
        preparationTask = Task { [weak self, sources] in
            guard let self else { return }
            do {
                var items: [AVPlayerItem] = []
                for source in sources {
                    if Task.isCancelled { return }
                    items.append(try await Self.makeItem(for: source))
                }
                guard !Task.isCancelled else { return }
                install(items: items)
            } catch {
                guard !Task.isCancelled else { return }
                preparationFailed = true
            }
        }
    }

    private static func makeItem(for source: TimelinePlaybackSource) async throws -> AVPlayerItem {
        guard let selection = source.selection,
              selection != source.sourceRange else {
            return AVPlayerItem(url: source.url)
        }
        let asset = AVURLAsset(url: source.url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TimelinePlaybackPreparationError.missingVideoTrack
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let sourceStart = CMTime(
            seconds: videoRange.start.seconds + selection.start.seconds,
            preferredTimescale: 600
        )
        let selectedRange = CMTimeRange(
            start: sourceStart,
            duration: CMTime(seconds: selection.duration, preferredTimescale: 600)
        )
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TimelinePlaybackPreparationError.cannotCreateComposition
        }
        try compositionVideoTrack.insertTimeRange(selectedRange, of: videoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = preferredTransform

        for audioTrack in try await asset.loadTracks(withMediaType: .audio) {
            let audioRange = try await audioTrack.load(.timeRange)
            let intersection = CMTimeRangeGetIntersection(selectedRange, otherRange: audioRange)
            guard intersection.isValid, intersection.duration > .zero else { continue }
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw TimelinePlaybackPreparationError.cannotCreateComposition
            }
            try compositionAudioTrack.insertTimeRange(
                intersection,
                of: audioTrack,
                at: CMTimeSubtract(intersection.start, selectedRange.start)
            )
        }

        guard let immutableComposition = composition.copy() as? AVComposition else {
            throw TimelinePlaybackPreparationError.cannotCreateComposition
        }
        return AVPlayerItem(asset: immutableComposition)
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

private enum TimelinePlaybackPreparationError: Error {
    case missingVideoTrack
    case cannotCreateComposition
}
