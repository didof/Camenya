import AVFoundation
import SwiftUI

struct TakeReviewScreen: View {
    @StateObject private var playback: TakePlaybackController
    @Environment(\.dismiss) private var dismiss
    let title: String
    let format: ProjectFormat

    init(url: URL, title: String, format: ProjectFormat) {
        _playback = StateObject(wrappedValue: TakePlaybackController(url: url))
        self.title = title
        self.format = format
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                PlayerLayerView(player: playback.player)
                    .aspectRatio(format == .portrait ? 9 / 16 : 16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Slider(
                    value: Binding(get: { playback.currentTime }, set: playback.seek),
                    in: 0...max(playback.duration, 0.01)
                )
                .accessibilityLabel("Playback position")

                HStack {
                    Text(RecordingDurationFormatter.clock(playback.currentTime))
                    Spacer()
                    Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                        playback.togglePlayback()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Text(RecordingDurationFormatter.clock(playback.duration))
                }
                .font(.subheadline.monospacedDigit())
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
final class TakePlaybackController: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var mode: TakePreviewMode

    let player: AVPlayer
    private let originalDuration: TimeInterval
    private var selection: TakeRange?
    private var mediaStart: TimeInterval = 0
    private var preparationTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var completionObserver: NSObjectProtocol?

    init(
        url: URL,
        originalDuration: TimeInterval = 0,
        selection: TakeRange? = nil,
        mode: TakePreviewMode = .original
    ) {
        self.originalDuration = max(0, originalDuration)
        self.selection = selection
        self.mode = mode
        duration = max(0, originalDuration)
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds - self.mediaStart : 0)
                let loadedDuration = self.player.currentItem?.duration.seconds ?? 0
                if self.originalDuration == 0 {
                    self.duration = loadedDuration.isFinite ? max(0, loadedDuration) : 0
                    self.configurePlaybackBoundary()
                }
                self.isPlaying = self.player.rate != 0
            }
        }
        completionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.playbackDidFinish() }
        }
        configurePlaybackBoundary()
        seek(to: activeStart)
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
                let range = try await track?.load(.timeRange)
                guard !Task.isCancelled, let start = range?.start.seconds, start.isFinite else { return }
                mediaStart = start
                configurePlaybackBoundary()
                seek(to: activeStart)
            } catch {
                // A normal AVPlayer error remains visible through the player UI.
            }
        }
    }

    deinit {
        preparationTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let completionObserver { NotificationCenter.default.removeObserver(completionObserver) }
    }

    func togglePlayback() {
        if player.rate == 0 {
            let target = (currentTime < activeStart || currentTime >= activeEnd) ? activeStart : currentTime
            seek(to: target, playWhenReady: true)
        } else {
            player.pause()
        }
        isPlaying = player.rate != 0
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        seek(to: seconds, playWhenReady: false)
    }

    private func seek(to seconds: TimeInterval, playWhenReady: Bool) {
        let clamped = min(max(seconds, activeStart), max(activeStart, activeEnd))
        player.seek(
            to: CMTime(seconds: mediaStart + clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard finished, playWhenReady else { return }
            Task { @MainActor in
                self?.player.play()
                self?.isPlaying = self?.player.rate != 0
            }
        }
        currentTime = clamped
    }

    var activeStart: TimeInterval {
        guard mode == .trimmed, let selection else { return 0 }
        return selection.start.seconds
    }

    var activeEnd: TimeInterval {
        guard mode == .trimmed, let selection else { return duration }
        return selection.end.seconds
    }

    func setPreviewMode(_ mode: TakePreviewMode) {
        guard mode != self.mode else { return }
        pause()
        self.mode = mode
        configurePlaybackBoundary()
        seek(to: activeStart)
    }

    func updateSelection(_ range: TakeRange) {
        selection = range
        if mode == .trimmed {
            configurePlaybackBoundary()
            seek(to: activeStart)
        }
    }

    private func playbackDidFinish() {
        player.pause()
        seek(to: activeStart)
        isPlaying = false
    }

    private func configurePlaybackBoundary() {
        guard let item = player.currentItem else { return }
        item.forwardPlaybackEndTime = mode == .trimmed && activeEnd > activeStart
            ? CMTime(seconds: mediaStart + activeEnd, preferredTimescale: 600)
            : .invalid
    }
}

enum TakePreviewMode: String, CaseIterable, Identifiable {
    case original = "Original"
    case trimmed = "Trimmed"

    var id: Self { self }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let onVideoRectChanged: ((CGRect) -> Void)?

    init(
        player: AVPlayer,
        onVideoRectChanged: ((CGRect) -> Void)? = nil
    ) {
        self.player = player
        self.onVideoRectChanged = onVideoRectChanged
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.onVideoRectChanged = onVideoRectChanged
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.onVideoRectChanged = onVideoRectChanged
        uiView.requestVideoRectReport()
    }
}

final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var onVideoRectChanged: ((CGRect) -> Void)?
    private var reportedVideoRect: CGRect = .null

    override func layoutSubviews() {
        super.layoutSubviews()
        reportVideoRectIfNeeded()
    }

    func reportVideoRectIfNeeded() {
        let rect = playerLayer.videoRect
        guard rect != reportedVideoRect else { return }
        reportedVideoRect = rect
        onVideoRectChanged?(rect)
    }

    func requestVideoRectReport() {
        reportedVideoRect = .null
        setNeedsLayout()
    }
}
