import AVFoundation
import OSLog
import SwiftUI
import UIKit

private let timelineReviewLogger = Logger(
    subsystem: "org.camenya.app",
    category: "TimelineReview"
)

private struct TimelinePlaybackSource: Equatable, Sendable {
    let url: URL
    let selection: TakeRange?
    let sourceRange: TakeRange?
    let isMuted: Bool

    init(
        url: URL,
        selection: TakeRange?,
        sourceRange: TakeRange? = nil,
        isMuted: Bool = false
    ) {
        self.url = url
        self.selection = selection
        self.sourceRange = sourceRange
        self.isMuted = isMuted
    }

    static func make(snapshot: ExportSnapshot) -> [TimelinePlaybackSource] {
        snapshot.clips.map {
            TimelinePlaybackSource(
                url: $0.mediaURL,
                selection: $0.selection,
                sourceRange: $0.sourceRange,
                isMuted: $0.isMuted
            )
        }
    }
}

@MainActor
final class TimelinePlaybackSession: ObservableObject {
    enum Phase: Equatable {
        case empty
        case preparing
        case paused
        case playing
        case completed
        case failed
    }

    struct FilmstripClip: Equatable, Identifiable {
        let id: TimelineClip.ID
        let projectTimeRange: ProjectTimeRange
        let mediaURL: URL
        let thumbnailURL: URL?
        let sourceCreatedAt: Date?
        let availableRange: TakeRange
        let selection: TakeRange
        let trimSuggestion: TakeRange?
        let isMuted: Bool

        init(
            id: TimelineClip.ID,
            projectTimeRange: ProjectTimeRange,
            mediaURL: URL,
            thumbnailURL: URL?,
            sourceCreatedAt: Date?,
            availableRange: TakeRange = TakeRange(startSeconds: 0, endSeconds: 0),
            selection: TakeRange = TakeRange(startSeconds: 0, endSeconds: 0),
            trimSuggestion: TakeRange? = nil,
            isMuted: Bool = false
        ) {
            self.id = id
            self.projectTimeRange = projectTimeRange
            self.mediaURL = mediaURL
            self.thumbnailURL = thumbnailURL
            self.sourceCreatedAt = sourceCreatedAt
            self.availableRange = availableRange
            self.selection = selection
            self.trimSuggestion = trimSuggestion
            self.isMuted = isMuted
        }

        var duration: TimeInterval {
            projectTimeRange.end.seconds - projectTimeRange.start.seconds
        }
    }

    struct FilmstripScale: Equatable {
        static let minimumPointsPerSecond: CGFloat = 44
        static let maximumPointsPerSecond: CGFloat = 96
        static let standard = FilmstripScale(pointsPerSecond: 48)

        let pointsPerSecond: CGFloat

        init(pointsPerSecond: CGFloat) {
            self.pointsPerSecond = min(
                Self.maximumPointsPerSecond,
                max(Self.minimumPointsPerSecond, pointsPerSecond)
            )
        }
    }

    struct State: Equatable {
        let revision: StorylineRevision
        let duration: ProjectTime
        let clips: [FilmstripClip]
        var phase: Phase
        var playhead: ProjectTime
        var selectedClipID: TimelineClip.ID?
        var filmstripScale: FilmstripScale

        var selectedClipOrdinal: Int? {
            guard let selectedClipID,
                  let index = clips.firstIndex(where: { $0.id == selectedClipID }) else { return nil }
            return index + 1
        }

        var selectedClip: FilmstripClip? {
            guard let selectedClipID else { return nil }
            return clips.first(where: { $0.id == selectedClipID })
        }

        var clipCount: Int { clips.count }
        var isPlaying: Bool { phase == .playing }
        var filmstripPointsPerSecond: CGFloat { filmstripScale.pointsPerSecond }
        var canSelectPreviousClip: Bool { (selectedClipOrdinal ?? 1) > 1 }
        var canSelectNextClip: Bool { (selectedClipOrdinal ?? clipCount) < clipCount }
    }

    enum Intent {
        case togglePlayback
        case pause
        case previewSeek(ProjectTime)
        case seek(ProjectTime)
        case selectClip(TimelineClip.ID)
        case selectPreviousClip
        case selectNextClip
        case zoomIn
        case zoomOut
        case magnify(Double)
        case retryPreparation
        case playRange(TakeRange)
    }

    @Published private(set) var state: State
    let player = AVQueuePlayer()

    private var snapshot: ExportSnapshot
    private var sources: [TimelinePlaybackSource]
    private var completionObservers: [NSObjectProtocol] = []
    private var periodicTimeObserver: Any?
    private var preparationTask: Task<Void, Never>?
    private var installedItemIndices: [ObjectIdentifier: Int] = [:]
    private var preparationGeneration = 0
    private var activeTrimPreviewClipID: TimelineClip.ID?
    private var playbackStopProjectTime: TimeInterval?
    init(
        snapshot: ExportSnapshot,
        initialSelectedClipID: TimelineClip.ID? = nil,
        initialProjectTime: ProjectTime? = nil
    ) {
        self.snapshot = snapshot
        sources = TimelinePlaybackSource.make(snapshot: snapshot)
        let clips = Self.makeFilmstripClips(snapshot: snapshot)
        let requestedTime = initialProjectTime.map {
            ProjectTime(seconds: min(max(0, $0.seconds), snapshot.duration.seconds))
        }
        let initialIndex = requestedTime.flatMap { time in
            snapshot.position(at: time).flatMap { position in
                clips.firstIndex(where: { $0.id == position.clipID })
            }
        } ?? initialSelectedClipID.flatMap { requestedID in
            clips.firstIndex(where: { $0.id == requestedID })
        } ?? 0
        let initialClip = clips[safe: initialIndex]
        let playhead = requestedTime ?? initialClip?.projectTimeRange.start ?? .zero
        state = State(
            revision: snapshot.revision,
            duration: snapshot.duration,
            clips: clips,
            phase: clips.isEmpty ? .empty : .preparing,
            playhead: playhead,
            selectedClipID: initialClip?.id,
            filmstripScale: .standard
        )
        observePlayerTime()
        if !clips.isEmpty {
            let localTime = max(0, playhead.seconds - (initialClip?.projectTimeRange.start.seconds ?? 0))
            prepareQueue(startingAt: initialIndex, localTime: localTime)
        }
    }

    var currentSnapshot: ExportSnapshot { snapshot }

    func replaceSnapshot(
        _ snapshot: ExportSnapshot,
        selectedClipID: TimelineClip.ID?,
        projectTime: ProjectTime
    ) {
        preparationGeneration += 1
        preparationTask?.cancel()
        player.pause()
        clearInstalledItems()
        self.snapshot = snapshot
        sources = TimelinePlaybackSource.make(snapshot: snapshot)
        let clips = Self.makeFilmstripClips(snapshot: snapshot)
        let clampedTime = ProjectTime(seconds: min(
            max(0, projectTime.seconds),
            snapshot.duration.seconds
        ))
        let preservedSelection = selectedClipID.flatMap { id in
            clips.contains(where: { $0.id == id }) ? id : nil
        }
        let mappedSelection = snapshot.position(at: clampedTime)?.clipID
        state = State(
            revision: snapshot.revision,
            duration: snapshot.duration,
            clips: clips,
            phase: clips.isEmpty ? .empty : .preparing,
            playhead: clampedTime,
            selectedClipID: preservedSelection ?? mappedSelection ?? clips.first?.id,
            filmstripScale: state.filmstripScale
        )
        guard !clips.isEmpty, clampedTime.seconds < snapshot.duration.seconds else {
            state.phase = clips.isEmpty ? .empty : .completed
            return
        }
        let location = playbackLocation(at: clampedTime)
        prepareQueue(startingAt: location.index, localTime: location.localTime)
    }

    func previewTrim(
        clipID: TimelineClip.ID,
        selection: TakeRange,
        edge: TimelineTrimEdge
    ) {
        prepareTrimPreview(
            clipID: clipID,
            selection: selection,
            edge: edge,
            playWhenReady: false
        )
    }

    func playTrimPreview(clipID: TimelineClip.ID, selection: TakeRange) {
        prepareTrimPreview(
            clipID: clipID,
            selection: selection,
            edge: .start,
            playWhenReady: true
        )
    }

    private func prepareTrimPreview(
        clipID: TimelineClip.ID,
        selection: TakeRange,
        edge: TimelineTrimEdge,
        playWhenReady: Bool
    ) {
        guard let index = state.clips.firstIndex(where: { $0.id == clipID }),
              let source = sources[safe: index] else { return }
        preparationGeneration += 1
        let generation = preparationGeneration
        preparationTask?.cancel()
        player.pause()
        state.phase = .paused
        state.selectedClipID = clipID
        let clip = state.clips[index]
        let previewProjectSeconds = edge == .start
            ? clip.projectTimeRange.start.seconds
            : max(
                clip.projectTimeRange.start.seconds,
                clip.projectTimeRange.start.seconds + selection.duration - 0.001
            )
        state.playhead = ProjectTime(seconds: previewProjectSeconds)
        let previewSource = TimelinePlaybackSource(
            url: source.url,
            selection: selection,
            sourceRange: source.sourceRange,
            isMuted: source.isMuted
        )
        preparationTask = Task { [weak self] in
            do {
                let item = try await TimelinePlaybackItemBuilder.makeItem(for: previewSource)
                guard !Task.isCancelled, let self, generation == self.preparationGeneration else { return }
                self.installTrimPreview(
                    item,
                    sourceIndex: index,
                    localTime: edge == .start ? 0 : max(0, selection.duration - 1.0 / 30.0),
                    playWhenReady: playWhenReady
                )
            } catch {
                guard !Task.isCancelled, let self, generation == self.preparationGeneration else { return }
                self.state.phase = .failed
            }
        }
    }

    deinit {
        preparationTask?.cancel()
        completionObservers.forEach(NotificationCenter.default.removeObserver)
        if let periodicTimeObserver { player.removeTimeObserver(periodicTimeObserver) }
    }

    func send(_ intent: Intent) {
        switch intent {
        case .togglePlayback:
            togglePlayback()
        case .pause:
            pause()
        case let .previewSeek(projectTime):
            previewSeek(to: projectTime)
        case let .seek(projectTime):
            seek(to: projectTime)
        case let .selectClip(id):
            guard let index = state.clips.firstIndex(where: { $0.id == id }) else { return }
            seekToClip(at: index)
        case .selectPreviousClip:
            guard let ordinal = state.selectedClipOrdinal, ordinal > 1 else { return }
            seekToClip(at: ordinal - 2)
        case .selectNextClip:
            guard let ordinal = state.selectedClipOrdinal, ordinal < state.clipCount else { return }
            seekToClip(at: ordinal)
        case .zoomIn:
            setZoom(state.filmstripPointsPerSecond * 1.25)
        case .zoomOut:
            setZoom(state.filmstripPointsPerSecond / 1.25)
        case let .magnify(scale):
            guard scale.isFinite, scale > 0 else { return }
            setZoom(state.filmstripPointsPerSecond * CGFloat(scale))
        case .retryPreparation:
            let location = playbackLocation(at: state.playhead)
            prepareQueue(startingAt: location.index, localTime: location.localTime)
        case let .playRange(range):
            play(range: range)
        }
    }

    private func togglePlayback() {
        guard !state.clips.isEmpty else { return }
        if state.isPlaying {
            pause()
            return
        }
        if state.phase == .completed {
            state.playhead = .zero
            state.selectedClipID = state.clips.first?.id
            prepareQueue(startingAt: 0, localTime: 0, playWhenReady: true)
            return
        }
        guard player.currentItem != nil, state.phase != .preparing, state.phase != .failed else { return }
        player.play()
        state.phase = .playing
    }

    private func pause() {
        player.pause()
        playbackStopProjectTime = nil
        if state.phase == .playing { state.phase = .paused }
    }

    private func play(range: TakeRange) {
        guard range.duration > 0,
              range.start.seconds >= 0,
              range.end.seconds <= state.duration.seconds else { return }
        playbackStopProjectTime = range.end.seconds
        let start = ProjectTime(seconds: range.start.seconds)
        state.playhead = start
        let location = playbackLocation(at: start)
        state.selectedClipID = state.clips[safe: location.index]?.id
        prepareQueue(startingAt: location.index, localTime: location.localTime, playWhenReady: true)
    }

    private func seek(to requestedTime: ProjectTime) {
        previewSeek(to: requestedTime)
        let clamped = state.playhead.seconds
        let location = playbackLocation(at: state.playhead)
        guard clamped < state.duration.seconds else { return }
        prepareQueue(startingAt: location.index, localTime: location.localTime)
    }

    private func previewSeek(to requestedTime: ProjectTime) {
        guard !state.clips.isEmpty else { return }
        let seconds = requestedTime.seconds
        guard seconds.isFinite else { return }
        pause()
        let clamped = min(max(0, seconds), state.duration.seconds)
        state.playhead = ProjectTime(seconds: clamped)
        let location = playbackLocation(at: state.playhead)
        state.selectedClipID = state.clips[safe: location.index]?.id
        guard clamped < state.duration.seconds else {
            preparationGeneration += 1
            preparationTask?.cancel()
            player.pause()
            state.phase = .completed
            return
        }
        if state.phase == .completed { state.phase = .paused }
        guard let item = player.currentItem,
              installedItemIndices[ObjectIdentifier(item)] == location.index else {
            prepareQueue(startingAt: location.index, localTime: location.localTime)
            return
        }
        player.seek(
            to: CMTime(seconds: location.localTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func seekToClip(at index: Int) {
        guard let clip = state.clips[safe: index] else { return }
        seek(to: clip.projectTimeRange.start)
    }

    private func setZoom(_ zoom: CGFloat) {
        state.filmstripScale = FilmstripScale(pointsPerSecond: zoom)
    }

    private func playbackLocation(at projectTime: ProjectTime) -> (index: Int, localTime: TimeInterval) {
        guard !state.clips.isEmpty else { return (0, 0) }
        if projectTime.seconds >= state.duration.seconds {
            let lastIndex = state.clips.count - 1
            return (lastIndex, state.clips[lastIndex].duration)
        }
        if let position = snapshot.position(at: projectTime),
           let index = state.clips.firstIndex(where: { $0.id == position.clipID }) {
            return (index, projectTime.seconds - state.clips[index].projectTimeRange.start.seconds)
        }
        return (0, 0)
    }

    private func prepareQueue(startingAt index: Int, localTime: TimeInterval, playWhenReady: Bool = false) {
        guard sources.indices.contains(index) else { return }
        preparationGeneration += 1
        let generation = preparationGeneration
        preparationTask?.cancel()
        player.pause()
        state.phase = .preparing
        preparationTask = Task { [weak self, sources] in
            do {
                var prepared: [(Int, AVPlayerItem)] = []
                for sourceIndex in index..<sources.count {
                    if Task.isCancelled { return }
                    prepared.append((sourceIndex, try await TimelinePlaybackItemBuilder.makeItem(for: sources[sourceIndex])))
                }
                guard !Task.isCancelled, let self, generation == self.preparationGeneration else { return }
                self.install(items: prepared, localTime: localTime, playWhenReady: playWhenReady)
            } catch {
                guard !Task.isCancelled, let self, generation == self.preparationGeneration else { return }
                self.clearInstalledItems()
                self.state.phase = .failed
            }
        }
    }

    private func install(items: [(Int, AVPlayerItem)], localTime: TimeInterval, playWhenReady: Bool) {
        clearInstalledItems()
        for (index, item) in items {
            installedItemIndices[ObjectIdentifier(item)] = index
            completionObservers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in self?.itemDidFinish(notification.object as? AVPlayerItem) }
            })
            player.insert(item, after: nil)
        }
        player.seek(to: CMTime(seconds: localTime, preferredTimescale: 600))
        state.phase = playWhenReady ? .playing : .paused
        if playWhenReady { player.play() }
    }

    private func installTrimPreview(
        _ item: AVPlayerItem,
        sourceIndex: Int,
        localTime: TimeInterval,
        playWhenReady: Bool
    ) {
        clearInstalledItems()
        installedItemIndices = [ObjectIdentifier(item): sourceIndex]
        activeTrimPreviewClipID = state.clips[safe: sourceIndex]?.id
        completionObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.itemDidFinish(notification.object as? AVPlayerItem) }
        })
        player.insert(item, after: nil)
        player.seek(to: CMTime(seconds: localTime, preferredTimescale: 600))
        state.phase = playWhenReady ? .playing : .paused
        if playWhenReady { player.play() }
    }

    private func clearInstalledItems() {
        completionObservers.forEach(NotificationCenter.default.removeObserver)
        completionObservers.removeAll()
        installedItemIndices.removeAll()
        activeTrimPreviewClipID = nil
        player.removeAllItems()
    }

    private func itemDidFinish(_ item: AVPlayerItem?) {
        guard let item, let completedIndex = installedItemIndices[ObjectIdentifier(item)] else { return }
        if let activeTrimPreviewClipID {
            player.pause()
            state.selectedClipID = activeTrimPreviewClipID
            state.phase = .completed
            return
        }
        let nextIndex = completedIndex + 1
        guard nextIndex < state.clips.count else {
            player.pause()
            state.playhead = state.duration
            state.selectedClipID = state.clips.last?.id
            state.phase = .completed
            return
        }
        state.playhead = state.clips[nextIndex].projectTimeRange.start
        state.selectedClipID = state.clips[nextIndex].id
    }

    private func observePlayerTime() {
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.playerTimeChanged(time) }
        }
    }

    private func playerTimeChanged(_ time: CMTime) {
        guard state.phase == .playing,
              let item = player.currentItem,
              let index = installedItemIndices[ObjectIdentifier(item)],
              let clip = state.clips[safe: index],
              time.seconds.isFinite else { return }
        let seconds = min(state.duration.seconds, clip.projectTimeRange.start.seconds + max(0, time.seconds))
        state.playhead = ProjectTime(seconds: seconds)
        state.selectedClipID = clip.id
        if let stop = playbackStopProjectTime, seconds >= stop {
            player.pause()
            playbackStopProjectTime = nil
            state.playhead = ProjectTime(seconds: stop)
            state.phase = .paused
        }
    }

    private static func makeFilmstripClips(snapshot: ExportSnapshot) -> [FilmstripClip] {
        snapshot.clips.map { clip in
            FilmstripClip(
                id: clip.id,
                projectTimeRange: clip.projectTimeRange,
                mediaURL: clip.mediaURL,
                thumbnailURL: clip.thumbnailURL,
                sourceCreatedAt: clip.sourceCreatedAt,
                availableRange: clip.availableRange,
                selection: clip.selection,
                trimSuggestion: clip.trimSuggestion,
                isMuted: clip.isMuted
            )
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct TimelinePlaybackContext: Equatable, Sendable {
    var selectedClipID: TimelineClip.ID?
    var projectTime: ProjectTime

    static let beginning = TimelinePlaybackContext(selectedClipID: nil, projectTime: .zero)
}

enum TimelineReviewPresentation: Equatable, Sendable {
    case standalone
    case embedded
}

enum TimelineEditCompletion: Equatable, Sendable {
    case remainInEditor
    case finishTrim
}

struct TimelineEditRequest: Equatable, Sendable {
    let edit: TimelineEdit
    let completion: TimelineEditCompletion

    var retryRequest: TimelineEditRequest { self }
}

struct TimelineReviewScreen: View {
    @StateObject private var playback: TimelinePlaybackSession
    @ObservedObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCommittingEdit = false
    @State private var editErrorMessage: String?
    @State private var failedEditRequest: TimelineEditRequest?
    @State private var sessionHistory = TimelineSessionHistory()
    @State private var trimSession: TimelineTrimSession?
    @State private var trimEntryContext: TimelinePlaybackContext?
    @State private var isCheckingStoryline = false
    @State private var storylineCheckFailed = false
    @State private var failedSpokenLanguageUpdate: SpokenLanguageUpdate?
    let snapshot: ExportSnapshot
    let title: String
    let format: ProjectFormat
    let presentation: TimelineReviewPresentation
    let onDone: (TimelinePlaybackContext) -> Void

    private struct SpokenLanguageUpdate {
        let takeID: UUID
        let localeIdentifier: String?
    }

    init(
        snapshot: ExportSnapshot,
        title: String,
        format: ProjectFormat,
        model: AppModel,
        initialSelectedClipID: TimelineClip.ID? = nil,
        initialProjectTime: ProjectTime? = nil,
        presentation: TimelineReviewPresentation = .standalone,
        onDone: @escaping (TimelinePlaybackContext) -> Void = { _ in }
    ) {
        _playback = StateObject(wrappedValue: TimelinePlaybackSession(
            snapshot: snapshot,
            initialSelectedClipID: initialSelectedClipID,
            initialProjectTime: initialProjectTime
        ))
        _model = ObservedObject(wrappedValue: model)
        self.snapshot = snapshot
        self.title = title
        self.format = format
        self.presentation = presentation
        self.onDone = onDone
    }

    var body: some View {
        Group {
            if presentation == .standalone {
                NavigationStack { editorSurface }
            } else {
                editorSurface
            }
        }
        .interactiveDismissDisabled(isCommittingEdit || model.isEditingTimeline)
        .onChange(of: snapshot) { _, updatedSnapshot in
            playback.replaceSnapshot(
                updatedSnapshot,
                selectedClipID: playback.state.selectedClipID,
                projectTime: playback.state.playhead
            )
        }
        .onDisappear { playback.send(.pause) }
    }

    private var editorSurface: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 14) {
                    viewer(maximumHeight: min(geometry.size.height * 0.42, 300))
                    if let editErrorMessage {
                        editFailureRow(editErrorMessage)
                    }
                    if playback.state.phase == .failed {
                        failureState
                    } else if playback.state.phase == .empty {
                        emptyState
                    } else if let trimSession {
                        trimSurface(trimSession)
                    } else {
                        playbackStatus
                        TimelineFilmstrip(
                            playback: playback,
                            format: format,
                            isCommitting: isCommittingEdit || model.isEditingTimeline,
                            preparationIssueCount: model.preparationIssueCount(for:)
                        )
                        clipOrderControls
                        contextualToolRow
                        if model.needsStorylineCheck {
                            HStack(spacing: 10) {
                                Button("Skip") { finishEditing() }
                                    .buttonStyle(.bordered)
                                    .frame(minHeight: 48)
                                    .accessibilityHint("Leaves the complete video check unfinished.")
                                Button(action: confirmStorylineCheck) {
                                    Label("Continue", systemImage: "checkmark.circle")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                                .accessibilityLabel("Mark Video Checked and Continue")
                                .accessibilityHint(
                                    "Confirms that you reviewed the complete Storyline before captions."
                                )
                            }
                            .disabled(isCheckingStoryline || isCommittingEdit || model.isEditingTimeline)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(presentation == .standalone ? title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
    }

    private func editFailureRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failedEditRequest {
                Button("Retry") {
                    commit(failedEditRequest.retryRequest)
                }
                .font(.footnote.weight(.semibold))
                .disabled(isCommittingEdit)
            } else if storylineCheckFailed {
                Button("Retry", action: confirmStorylineCheck)
                    .font(.footnote.weight(.semibold))
                    .disabled(isCheckingStoryline)
            } else if let failedSpokenLanguageUpdate {
                Button("Retry") {
                    commitSpokenLanguage(failedSpokenLanguageUpdate)
                }
                .font(.footnote.weight(.semibold))
            }
            Button {
                editErrorMessage = nil
                failedEditRequest = nil
                storylineCheckFailed = false
                failedSpokenLanguageUpdate = nil
            } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss edit error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if trimSession != nil {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancelTrim)
                    .disabled(isCommittingEdit)
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: doneAction)
                .fontWeight(.semibold)
                .disabled(isCommittingEdit || model.isEditingTimeline)
        }

        if trimSession == nil {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    applyHistory(.undo)
                }
                .disabled(!sessionHistory.canUndo || isCommittingEdit || model.isEditingTimeline)
                .accessibilityHint(sessionHistory.canUndo
                    ? "Undoes \(sessionHistory.undoOperationName ?? "the most recent edit")."
                    : "No edit is available to undo in this editing session.")

                Spacer()

                Button("Redo", systemImage: "arrow.uturn.forward") {
                    applyHistory(.redo)
                }
                .disabled(!sessionHistory.canRedo || isCommittingEdit || model.isEditingTimeline)
                .accessibilityHint(sessionHistory.canRedo
                    ? "Redoes \(sessionHistory.redoOperationName ?? "the most recently undone edit")."
                    : "No edit is available to redo in this editing session.")
            }
        }
    }

    private func viewer(maximumHeight: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack {
                PlayerLayerView(player: playback.player)
                    .background(Color(uiColor: .systemBackground))
                if let activeCaption {
                    projectCaptionOverlay(activeCaption, canvas: geometry.size)
                }
                if playback.state.phase == .preparing {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Text("Preparing Preview…")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.regularMaterial, in: Capsule())
                        }
                } else if playback.state.phase != .failed,
                          playback.state.phase != .empty {
                    Button(action: toggleViewerPlayback) {
                        Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2.weight(.semibold))
                            .frame(width: 56, height: 56)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel(playback.state.isPlaying ? "Pause" : "Play")
                }
            }
        }
        .aspectRatio(format == .portrait ? 9 / 16 : 16 / 9, contentMode: .fit)
        .frame(maxHeight: max(180, maximumHeight))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project Viewer")
        .accessibilityValue(viewerAccessibilityValue)
        .accessibilitySortPriority(6)
    }

    private var contextualToolRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button(action: startTrim) {
                    Label("Trim", systemImage: "timeline.selection")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(selectedProjectClip == nil || isCommittingEdit)

                Button(action: splitAtPlayhead) {
                    Label("Split", systemImage: "scissors")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(splitSourceTime == nil || isCommittingEdit)
                .accessibilityHint(splitSourceTime == nil
                    ? "Move the Playhead at least one second from each Clip edge."
                    : "Creates two adjacent Clips at the Playhead.")

                Menu {
                    if joinChoices.count == 1, let choice = joinChoices.first {
                        Button("Join Clip", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                            join(choice)
                        }
                    } else if joinChoices.count > 1 {
                        if let choice = joinChoices.first(where: { $0.direction == .previous }) {
                            Button("Join Previous Clip", systemImage: "rectangle.leadinghalf.inset.filled") {
                                join(choice)
                            }
                        }
                        if let choice = joinChoices.first(where: { $0.direction == .next }) {
                            Button("Join Next Clip", systemImage: "rectangle.trailinghalf.inset.filled") {
                                join(choice)
                            }
                        }
                    } else {
                        Button("Join Clip", systemImage: "rectangle.portrait.on.rectangle.portrait") {}
                            .disabled(true)
                        Text("Join needs adjacent matching split Clips.")
                    }

                    if let selectedClip = playback.state.selectedClip {
                        Button(
                            selectedClip.isMuted ? "Include Source Audio" : "Mute Source Audio",
                            systemImage: selectedClip.isMuted ? "speaker.wave.2" : "speaker.slash"
                        ) {
                            commit(.setMuted(
                                clipID: selectedClip.id,
                                isMuted: !selectedClip.isMuted
                            ))
                        }
                        if let sourceClip = selectedProjectClip {
                            Menu(spokenLanguageMenuTitle, systemImage: "character.bubble") {
                                Text("Applies to every Clip from this Take.")
                                if let projectLanguageIdentifier {
                                    Text("Project default: \(languageName(projectLanguageIdentifier)).")
                                } else {
                                    Text("Choose the Project default when creating captions.")
                                }
                                Button {
                                    commitSpokenLanguage(SpokenLanguageUpdate(
                                        takeID: sourceClip.takeID,
                                        localeIdentifier: nil
                                    ))
                                } label: {
                                    if selectedTake?.spokenLanguageIdentifier == nil {
                                        Label("Project Default", systemImage: "checkmark")
                                    } else {
                                        Text("Project Default")
                                    }
                                }
                                Divider()
                                ForEach(spokenLanguageIdentifiers, id: \.self) { identifier in
                                    Button {
                                        commitSpokenLanguage(SpokenLanguageUpdate(
                                            takeID: sourceClip.takeID,
                                            localeIdentifier: identifier
                                        ))
                                    } label: {
                                        if selectedTake?.spokenLanguageIdentifier == identifier {
                                            Label(languageName(identifier), systemImage: "checkmark")
                                        } else {
                                            Text(languageName(identifier))
                                        }
                                    }
                                }
                            }
                        }
                        if selectedClip.selection != selectedClip.availableRange {
                            Button("Reset Trim", systemImage: "arrow.counterclockwise") {
                                commit(.resetTrim(clipID: selectedClip.id))
                            }
                        }
                        Divider()
                        Button("Remove from Storyline", systemImage: "archivebox") {
                            commit(.remove(clipID: selectedClip.id))
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(selectedProjectClip == nil || isCommittingEdit)
            }

            if splitSourceTime == nil, playback.state.selectedClip != nil {
                Text("Tap or drag the Storyline under the blue Playhead. Split needs at least 1.0s on each side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilitySortPriority(2.5)
    }

    @ViewBuilder
    private var clipOrderControls: some View {
        if playback.state.clipCount > 1 {
            HStack(spacing: 8) {
                Button {
                    moveSelectedClip(by: -1)
                } label: {
                    Label("Move Left", systemImage: "arrow.left")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!canMoveSelectedClip(by: -1) || isCommittingEdit)
                .accessibilityHint("Moves the selected Clip one position earlier.")

                Button {
                    moveSelectedClip(by: 1)
                } label: {
                    Label("Move Right", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!canMoveSelectedClip(by: 1) || isCommittingEdit)
                .accessibilityHint("Moves the selected Clip one position later.")
            }
            .accessibilitySortPriority(2.7)
        }
    }

    private func trimSurface(_ session: TimelineTrimSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trim Clip")
                    .font(.headline)
                Spacer()
                Text(
                    "\(timecode(session.candidateSelection.start.seconds)) – "
                        + timecode(session.candidateSelection.end.seconds)
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            TimelineTrimWorkspace(
                session: Binding(
                    get: { trimSession ?? session },
                    set: { trimSession = $0 }
                ),
                envelope: selectedTake.map(model.trimEnvelope(for:)) ?? [],
                sourceDuration: selectedTake?.duration ?? session.availableRange.end.seconds,
                movieURL: selectedSnapshotClip?.mediaURL,
                fallbackThumbnailURL: selectedSnapshotClip?.thumbnailURL,
                isGeneratingWaveform: selectedTake.map {
                    model.isPreparingTrimWaveform(for: $0.id)
                } ?? false,
                waveformErrorMessage: selectedTake.flatMap {
                    model.trimWaveformError(for: $0.id)
                },
                onRetryWaveform: {
                    guard let takeID = selectedTake?.id else { return }
                    Task { await model.prepareTrimWaveform(takeID: takeID) }
                },
                onPreview: { selection, edge in
                    playback.previewTrim(
                        clipID: session.clipID,
                        selection: selection,
                        edge: edge
                    )
                }
            )
            .disabled(isCommittingEdit)
            .task(id: selectedTake?.id) {
                guard let takeID = selectedTake?.id else { return }
                await model.prepareTrimWaveform(takeID: takeID)
            }
        }
        .padding(.top, 2)
    }

    private var selectedProjectClip: TimelineClip? {
        guard let selectedClipID = playback.state.selectedClipID else { return nil }
        return model.project.primaryStoryline.clips.first { $0.id == selectedClipID }
    }

    private var selectedTake: ProjectTake? {
        guard let selectedClipID = playback.state.selectedClipID,
              let takeID = playback.currentSnapshot.clips.first(where: {
                  $0.id == selectedClipID
              })?.takeID else { return nil }
        return model.project.takes.first { $0.id == takeID }
    }

    private var spokenLanguageMenuTitle: String {
        if let override = selectedTake?.spokenLanguageIdentifier {
            return "Language: \(languageName(override)) · Take Override"
        }
        guard let projectLanguageIdentifier else {
            return "Language: Project Default"
        }
        return "Language: \(languageName(projectLanguageIdentifier)) · Project Default"
    }

    private var projectLanguageIdentifier: String? {
        model.captionConfiguration?.localeIdentifier
    }

    private var spokenLanguageIdentifiers: [String] {
        ProjectPresentationPolicy.captionLanguageIdentifiers(including: [
            model.captionConfiguration?.localeIdentifier ?? "",
            selectedTake?.spokenLanguageIdentifier ?? ""
        ])
    }

    private func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private var selectedSnapshotClip: ExportSnapshot.Clip? {
        guard let selectedClipID = playback.state.selectedClipID else { return nil }
        return playback.currentSnapshot.clips.first { $0.id == selectedClipID }
    }

    private var splitSourceTime: MediaTime? {
        guard let clip = playback.state.selectedClip else { return nil }
        return TimelineSplitRules.sourceTime(
            selection: clip.selection,
            projectTimeRange: clip.projectTimeRange,
            at: playback.state.playhead
        )
    }

    private var joinChoices: [TimelineJoinChoice] {
        guard let selectedClipID = playback.state.selectedClipID else { return [] }
        return TimelineJoinRules.choices(
            for: selectedClipID,
            in: model.project.primaryStoryline.clips
        )
    }

    private func startTrim() {
        guard let clip = playback.state.selectedClip else { return }
        playback.send(.pause)
        trimEntryContext = currentPlaybackContext
        trimSession = TimelineTrimSession(
            clipID: clip.id,
            availableRange: clip.availableRange,
            selection: clip.selection
        )
    }

    private func cancelTrim() {
        guard let trimSession else { return }
        let context = trimEntryContext ?? TimelinePlaybackContext(
            selectedClipID: trimSession.clipID,
            projectTime: playback.state.playhead
        )
        playback.replaceSnapshot(
            playback.currentSnapshot,
            selectedClipID: context.selectedClipID,
            projectTime: context.projectTime
        )
        self.trimSession = nil
        trimEntryContext = nil
    }

    private func doneAction() {
        guard let trimSession else {
            finishEditing()
            return
        }
        guard let edit = trimSession.commitEdit else {
            cancelTrim()
            return
        }
        commit(TimelineEditRequest(edit: edit, completion: .finishTrim))
    }

    private func finishEditing() {
        playback.send(.pause)
        onDone(currentPlaybackContext)
        if presentation == .standalone { dismiss() }
    }

    private func confirmStorylineCheck() {
        playback.send(.pause)
        isCheckingStoryline = true
        if model.markStorylineChecked() {
            editErrorMessage = nil
            storylineCheckFailed = false
            isCheckingStoryline = false
            UIAccessibility.post(notification: .announcement, argument: "Video checked")
            finishEditing()
        } else {
            isCheckingStoryline = false
            storylineCheckFailed = true
            editErrorMessage = "The video check couldn't be saved."
        }
    }

    private func commitSpokenLanguage(_ update: SpokenLanguageUpdate) {
        if model.setSpokenLanguage(
            for: update.takeID,
            localeIdentifier: update.localeIdentifier
        ) {
            editErrorMessage = nil
            failedSpokenLanguageUpdate = nil
        } else {
            editErrorMessage = "The spoken language couldn't be saved."
            failedSpokenLanguageUpdate = update
        }
    }

    private var currentPlaybackContext: TimelinePlaybackContext {
        TimelinePlaybackContext(
            selectedClipID: playback.state.selectedClipID,
            projectTime: playback.state.playhead
        )
    }

    private func toggleViewerPlayback() {
        if playback.state.isPlaying {
            playback.send(.pause)
            return
        }
        if let trimSession {
            playback.playTrimPreview(
                clipID: trimSession.clipID,
                selection: trimSession.candidateSelection
            )
        } else {
            playback.send(.togglePlayback)
        }
    }

    private func splitAtPlayhead() {
        guard let clipID = playback.state.selectedClipID, splitSourceTime != nil else { return }
        commit(.split(clipID: clipID, at: playback.state.playhead))
    }

    private func join(_ choice: TimelineJoinChoice) {
        commit(.join(leadingClipID: choice.leadingClipID))
    }

    private func canMoveSelectedClip(by offset: Int) -> Bool {
        guard let ordinal = playback.state.selectedClipOrdinal else { return false }
        return TimelineStepMoveRules.destinationIndex(
            currentIndex: ordinal - 1,
            offset: offset,
            clipCount: playback.state.clipCount
        ) != nil
    }

    private func moveSelectedClip(by offset: Int) {
        guard let clipID = playback.state.selectedClipID,
              let ordinal = playback.state.selectedClipOrdinal,
              let destination = TimelineStepMoveRules.destinationIndex(
                currentIndex: ordinal - 1,
                offset: offset,
                clipCount: playback.state.clipCount
              ) else { return }
        commit(.move(clipID: clipID, toIndex: destination))
    }

    private var activeCaption: ActiveProjectCaptionPresentation? {
        guard let timeline = playback.currentSnapshot.captionTimeline else { return nil }
        return ProjectCaptionOverlayResolver.active(
            in: timeline,
            at: playback.state.playhead.seconds
        )
    }

    private var viewerAccessibilityValue: String {
        guard let activeCaption else { return phaseLabel }
        return "\(phaseLabel). Caption: \(activeCaption.cue.text)"
    }

    @ViewBuilder
    private func projectCaptionOverlay(
        _ active: ActiveProjectCaptionPresentation,
        canvas: CGSize
    ) -> some View {
        CaptionLayerPreview(
            cue: active.cue,
            configuration: ProjectCaptionConfiguration(
                localeIdentifier: "und",
                placement: playback.currentSnapshot.captionTimeline?.placement ?? .lower,
                style: playback.currentSnapshot.captionTimeline?.style ?? .clean,
                customization: playback.currentSnapshot.captionTimeline?.customization
                    ?? CaptionStyleCustomization()
            ),
            activeTime: playback.state.playhead.seconds
        )
            .accessibilityHidden(true)
    }

    private var failureState: some View {
        ContentUnavailableView {
            Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text("These Clips couldn't be prepared. Your Takes are unchanged.")
        } actions: {
            Button("Retry Preview", systemImage: "arrow.clockwise") {
                playback.send(.retryPreparation)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Storyline Empty", systemImage: "film.stack")
        } description: {
            Text("Record a Take to add a Clip automatically, or restore removed and unused media. Export requires at least one playable Clip.")
        }
    }

    private var playbackStatus: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let ordinal = playback.state.selectedClipOrdinal {
                    Text("Clip \(ordinal) of \(playback.state.clipCount)")
                        .font(.headline)
                }
                Text(playback.state.phase == .completed ? "Playback complete" : phaseLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilitySortPriority(4)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Playhead")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(timecode(playback.state.playhead.seconds)) / \(timecode(playback.state.duration.seconds))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
                .accessibilityLabel("Project Time")
                .accessibilityValue("\(timecode(playback.state.playhead.seconds)) of \(timecode(playback.state.duration.seconds))")
                .accessibilitySortPriority(5)
        }
    }

    private var phaseLabel: String {
        switch playback.state.phase {
        case .preparing: "Preparing"
        case .playing: "Playing"
        case .paused: "Paused"
        case .completed: "Complete"
        case .failed: "Unavailable"
        case .empty: "Empty"
        }
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safeSeconds) / 60
        let remainingSeconds = Int(safeSeconds) % 60
        let tenths = Int((safeSeconds * 10).rounded(.down)) % 10
        return String(format: "%02d:%02d.%d", minutes, remainingSeconds, tenths)
    }

    private func commit(_ edit: TimelineEdit) {
        commit(TimelineEditRequest(edit: edit, completion: .remainInEditor))
    }

    private func commit(_ request: TimelineEditRequest) {
        guard !isCommittingEdit else { return }
        editErrorMessage = nil
        failedEditRequest = nil
        let edit = request.edit
        let selectedClipID = playback.state.selectedClipID
        let projectTime = playback.state.playhead
        let expectedRevision = playback.state.revision
        let originalSnapshot = playback.currentSnapshot
        let beforeState = TimelineSessionState(project: model.project)
        playback.send(.pause)
        isCommittingEdit = true
        Task {
            defer { isCommittingEdit = false }
            do {
                let outcome = try await model.performTimelineEdit(
                    edit,
                    expectedRevision: expectedRevision
                )
                recordSessionEdit(edit, before: beforeState, outcome: outcome)
                let animatesStructure: Bool
                switch edit {
                case .move, .remove, .restore, .addFullTakeToStoryline, .join:
                    animatesStructure = true
                case .trim, .resetTrim, .split, .deleteRemovedClipPermanently, .setMuted,
                     .nudgeTrim:
                    animatesStructure = false
                }
                if animatesStructure, !reduceMotion {
                    withAnimation(.easeOut(duration: 0.2)) {
                        replacePlaybackSnapshot(
                            outcome,
                            selectedClipID: selectedClipID,
                            projectTime: projectTime
                        )
                    }
                } else {
                    replacePlaybackSnapshot(
                        outcome,
                        selectedClipID: selectedClipID,
                        projectTime: projectTime
                    )
                }
                if case .split = edit, let focus = outcome.focus {
                    let ordinal = outcome.snapshot.clips.firstIndex(where: { $0.id == focus.clipID })
                        .map { $0 + 1 }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ordinal.map {
                            "Split complete. Clip \($0) of \(outcome.snapshot.clips.count) selected."
                        } ?? "Split complete. Right Clip selected."
                    )
                } else if case .move = edit, let focus = outcome.focus {
                    let ordinal = outcome.snapshot.clips.firstIndex(where: { $0.id == focus.clipID })
                        .map { $0 + 1 }
                    UISelectionFeedbackGenerator().selectionChanged()
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ordinal.map {
                            "Move complete. Clip \($0) of \(outcome.snapshot.clips.count) selected."
                        } ?? "Move complete."
                    )
                } else if case .join = edit, let focus = outcome.focus {
                    let ordinal = outcome.snapshot.clips.firstIndex(where: { $0.id == focus.clipID })
                        .map { $0 + 1 }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ordinal.map {
                            "Join complete. Clip \($0) of \(outcome.snapshot.clips.count) selected."
                        } ?? "Join complete. Joined Clip selected."
                    )
                } else if case .remove = edit {
                    let ordinal = outcome.focus.flatMap { focus in
                        outcome.snapshot.clips.firstIndex(where: { $0.id == focus.clipID })
                    }.map { $0 + 1 }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: outcome.snapshot.clips.isEmpty
                            ? "Clip removed. Storyline empty. The Clip remains available in Project Media under Removed Clips."
                            : ordinal.map {
                                "Clip removed. Clip \($0) of \(outcome.snapshot.clips.count) selected."
                            } ?? "Clip removed. Another Clip is selected."
                    )
                } else if case .restore = edit, let focus = outcome.focus {
                    let ordinal = outcome.snapshot.clips.firstIndex(where: { $0.id == focus.clipID })
                        .map { $0 + 1 }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ordinal.map {
                            "Clip restored at position \($0) of \(outcome.snapshot.clips.count)."
                        } ?? "Clip restored."
                    )
                } else if case .addFullTakeToStoryline = edit, let focus = outcome.focus {
                    let ordinal = outcome.snapshot.clips.firstIndex(where: { $0.id == focus.clipID })
                        .map { $0 + 1 }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ordinal.map {
                            "Full Take added as Clip \($0) of \(outcome.snapshot.clips.count)."
                        } ?? "Full Take added to the Storyline."
                    )
                } else if case .deleteRemovedClipPermanently = edit {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: "Removed Clip metadata deleted permanently. The Take media remains available."
                    )
                } else if case let .setMuted(clipID, isMuted) = edit {
                    let ordinal = outcome.snapshot.clips.firstIndex(where: { $0.id == clipID })
                        .map { $0 + 1 }
                    UISelectionFeedbackGenerator().selectionChanged()
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: ordinal.map {
                            isMuted
                                ? "Source audio muted for Clip \($0) of \(outcome.snapshot.clips.count)."
                                : "Source audio on for Clip \($0) of \(outcome.snapshot.clips.count)."
                        } ?? (isMuted ? "Source audio muted." : "Source audio on.")
                    )
                }
                editErrorMessage = nil
                failedEditRequest = nil
                if request.completion == .finishTrim {
                    trimSession = nil
                    trimEntryContext = nil
                }
            } catch {
                timelineReviewLogger.error(
                    "\(edit.operationName, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                playback.replaceSnapshot(
                    originalSnapshot,
                    selectedClipID: selectedClipID,
                    projectTime: projectTime
                )
                editErrorMessage = "This edit couldn't be saved. Your Takes and previous Storyline are unchanged."
                failedEditRequest = request
            }
        }
    }

    private func replacePlaybackSnapshot(
        _ outcome: TimelineEditOutcome,
        selectedClipID: TimelineClip.ID?,
        projectTime: ProjectTime
    ) {
        playback.replaceSnapshot(
            outcome.snapshot,
            selectedClipID: outcome.focus?.clipID ?? selectedClipID,
            projectTime: outcome.focus?.projectTime ?? projectTime
        )
    }

    private enum HistoryDirection {
        case undo
        case redo
    }

    private func applyHistory(_ direction: HistoryDirection) {
        guard !isCommittingEdit else { return }
        editErrorMessage = nil
        failedEditRequest = nil
        let target = direction == .undo
            ? sessionHistory.undoTarget
            : sessionHistory.redoTarget
        guard let target else { return }
        let operationName = direction == .undo
            ? sessionHistory.undoOperationName
            : sessionHistory.redoOperationName
        let originalSnapshot = playback.currentSnapshot
        let selectedClipID = playback.state.selectedClipID
        let projectTime = playback.state.playhead
        let expectedRevision = playback.state.revision
        playback.send(.pause)
        isCommittingEdit = true
        Task {
            defer { isCommittingEdit = false }
            do {
                let outcome = try await model.restoreTimelineSessionState(
                    target.state,
                    expectedRevision: expectedRevision,
                    focusClipID: target.focusClipID
                )
                if reduceMotion {
                    replacePlaybackSnapshot(
                        outcome,
                        selectedClipID: selectedClipID,
                        projectTime: projectTime
                    )
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        replacePlaybackSnapshot(
                            outcome,
                            selectedClipID: selectedClipID,
                            projectTime: projectTime
                        )
                    }
                }
                switch direction {
                case .undo: sessionHistory.didUndo()
                case .redo: sessionHistory.didRedo()
                }
                UISelectionFeedbackGenerator().selectionChanged()
                UIAccessibility.post(
                    notification: .announcement,
                    argument: direction == .undo
                        ? "Undid \(operationName ?? "Storyline Edit")."
                        : "Redid \(operationName ?? "Storyline Edit")."
                )
                editErrorMessage = nil
            } catch {
                playback.replaceSnapshot(
                    originalSnapshot,
                    selectedClipID: selectedClipID,
                    projectTime: projectTime
                )
                editErrorMessage = direction == .undo
                    ? "That edit couldn't be undone. The current Storyline is unchanged."
                    : "That edit couldn't be redone. The current Storyline is unchanged."
            }
        }
    }

    private func recordSessionEdit(
        _ edit: TimelineEdit,
        before: TimelineSessionState,
        outcome: TimelineEditOutcome
    ) {
        if case .deleteRemovedClipPermanently = edit {
            sessionHistory.removeAll()
            return
        }
        let after = TimelineSessionState(project: outcome.project)
        let targetClipID = clipID(for: edit)
        let undoFocusClipID = targetClipID.flatMap { id in
            before.clips.contains(where: { $0.id == id }) ? id : nil
        }
        let redoFocusClipID = outcome.focus?.clipID ?? targetClipID.flatMap { id in
            after.clips.contains(where: { $0.id == id }) ? id : nil
        }
        sessionHistory.record(
            before: before,
            after: after,
            undoFocusClipID: undoFocusClipID,
            redoFocusClipID: redoFocusClipID,
            operationName: edit.operationName
        )
    }

    private func clipID(for edit: TimelineEdit) -> TimelineClip.ID? {
        switch edit {
        case let .trim(clipID, _),
             let .resetTrim(clipID),
             let .split(clipID, _),
             let .join(clipID),
             let .move(clipID, _),
             let .remove(clipID),
             let .restore(clipID),
             let .deleteRemovedClipPermanently(clipID),
             let .setMuted(clipID, _),
             let .nudgeTrim(clipID, _, _):
            clipID
        case .addFullTakeToStoryline:
            nil
        }
    }

}

private struct TimelineTrimWorkspace: View {
    private enum NudgeStep: String, CaseIterable, Identifiable {
        case fine
        case coarse

        var id: Self { self }
        var seconds: TimeInterval { self == .fine ? 0.01 : 0.1 }
        var label: String { self == .fine ? "0.01 s" : "0.1 s" }
    }

    @Binding var session: TimelineTrimSession
    let envelope: [Float]
    let sourceDuration: TimeInterval
    let movieURL: URL?
    let fallbackThumbnailURL: URL?
    let isGeneratingWaveform: Bool
    let waveformErrorMessage: String?
    let onRetryWaveform: () -> Void
    let onPreview: (TakeRange, TimelineTrimEdge) -> Void
    @State private var nudgeStep: NudgeStep = .fine

    var body: some View {
        VStack(spacing: 10) {
            TimelineTrimImageStrip(
                session: $session,
                movieURL: movieURL,
                fallbackThumbnailURL: fallbackThumbnailURL,
                onPreview: onPreview
            )
            .frame(height: 96)

            TimelineTrimWaveform(
                session: $session,
                envelope: envelope,
                sourceDuration: sourceDuration
            )
            .frame(height: 52)

            if envelope.isEmpty, isGeneratingWaveform {
                Label("Building waveform", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            } else if envelope.isEmpty, let waveformErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.waveform")
                        .foregroundStyle(.orange)
                    Text(waveformErrorMessage)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry", action: onRetryWaveform)
                        .font(.caption.weight(.semibold))
                }
                .frame(minHeight: 44)
            }

            HStack(spacing: 12) {
                Text("Adjustment")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Adjustment step", selection: $nudgeStep) {
                    ForEach(NudgeStep.allCases) { step in
                        Text(step.label).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
            }

            nudgeRow(title: "Start", edge: .start)
            nudgeRow(title: "End", edge: .end)

            Button("Reset Trim", systemImage: "arrow.counterclockwise") {
                session.update(edge: .start, to: session.availableRange.start.seconds)
                session.update(edge: .end, to: session.availableRange.end.seconds)
                onPreview(session.candidateSelection, .start)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .disabled(session.candidateSelection == session.availableRange)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trim selected Clip")
    }

    private func nudgeRow(title: String, edge: TimelineTrimEdge) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(preciseTimecode(edge == .start
                    ? session.candidateSelection.start.seconds
                    : session.candidateSelection.end.seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            nudgeButton(edge: edge, direction: .earlier)
            nudgeButton(edge: edge, direction: .later)
        }
    }

    private func nudgeButton(
        edge: TimelineTrimEdge,
        direction: TimelineNudgeDirection
    ) -> some View {
        var proposed = session
        proposed.nudge(edge: edge, direction: direction, seconds: nudgeStep.seconds)
        let isAvailable = proposed.candidateSelection != session.candidateSelection
        return Button {
            session.nudge(edge: edge, direction: direction, seconds: nudgeStep.seconds)
            onPreview(session.candidateSelection, edge)
        } label: {
            Image(systemName: direction == .earlier ? "chevron.left" : "chevron.right")
                .font(.callout.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!isAvailable)
        .accessibilityLabel(
            "Move trim \(edge == .start ? "start" : "end") "
                + (direction == .earlier ? "earlier" : "later")
        )
        .accessibilityValue(isAvailable
            ? RecordingDurationFormatter.editingClock(
                edge == .start
                    ? proposed.candidateSelection.start.seconds
                    : proposed.candidateSelection.end.seconds
            )
            : "Unavailable")
        .accessibilityHint("Moves by \(nudgeStep.label).")
    }

    private func preciseTimecode(_ seconds: TimeInterval) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let totalHundredths = Int((safeSeconds * 100).rounded())
        let wholeSeconds = totalHundredths / 100
        return String(
            format: "%02d:%02d.%02d",
            wholeSeconds / 60,
            wholeSeconds % 60,
            totalHundredths % 100
        )
    }
}

private struct TimelineTrimImageStrip: View {
    private struct Request: Hashable {
        let movieURL: URL
        let availableRange: TakeRange
    }

    @Binding var session: TimelineTrimSession
    let movieURL: URL?
    let fallbackThumbnailURL: URL?
    let onPreview: (TakeRange, TimelineTrimEdge) -> Void
    @State private var frames: [UIImage?] = []

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let startX = x(for: session.candidateSelection.start.seconds, width: width)
            let endX = x(for: session.candidateSelection.end.seconds, width: width)
            ZStack(alignment: .leading) {
                frameSurface
                Color.black.opacity(0.54)
                    .frame(width: max(0, startX))
                Color.black.opacity(0.54)
                    .frame(width: max(0, width - endX))
                    .offset(x: endX)
                trimHandle(edge: .start, x: startX, width: width)
                trimHandle(edge: .end, x: endX, width: width)
            }
            .coordinateSpace(.named("storyline-trim-images"))
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(uiColor: .separator), lineWidth: 1)
            }
        }
        .task(id: request) {
            guard let request else {
                frames = []
                return
            }
            let data = await TimelineTrimFrameLoader().frameData(
                movieURL: request.movieURL,
                availableRange: request.availableRange,
                count: 6
            )
            guard !Task.isCancelled else { return }
            frames = data.map { data in
                data.flatMap { UIImage(data: $0) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Available Clip frames and candidate range")
    }

    @ViewBuilder
    private var frameSurface: some View {
        if frames.isEmpty {
            TakeThumbnailView(
                url: fallbackThumbnailURL,
                placeholderSystemName: "film",
                cornerRadius: 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 1) {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, image in
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        ZStack {
                            Color(uiColor: .tertiarySystemFill)
                            Image(systemName: "film")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private var request: Request? {
        movieURL.map { Request(movieURL: $0, availableRange: session.availableRange) }
    }

    private func trimHandle(
        edge: TimelineTrimEdge,
        x: CGFloat,
        width: CGFloat
    ) -> some View {
        let hitCenter = min(max(22, x), max(22, width - 22))
        let value = edge == .start
            ? session.candidateSelection.start.seconds
            : session.candidateSelection.end.seconds
        return ZStack {
            Color.clear
            Capsule()
                .fill(.tint)
                .frame(width: 8, height: 72)
                .offset(x: x - hitCenter)
        }
        .frame(width: 44, height: 96)
        .contentShape(Rectangle())
        .position(x: hitCenter, y: 48)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("storyline-trim-images"))
                .onChanged { value in
                    update(edge: edge, x: value.location.x, width: width)
                }
        )
        .accessibilityLabel(edge == .start ? "Trim Start" : "Trim End")
        .accessibilityValue(RecordingDurationFormatter.editingClock(value))
        .accessibilityAdjustableAction { direction in
            let delta: TimeInterval
            switch direction {
            case .increment: delta = TimelineTrimRules.nudgeSeconds
            case .decrement: delta = -TimelineTrimRules.nudgeSeconds
            @unknown default: return
            }
            session.update(edge: edge, to: value + delta)
            onPreview(session.candidateSelection, edge)
        }
    }

    private func update(edge: TimelineTrimEdge, x: CGFloat, width: CGFloat) {
        let fraction = Double(min(max(0, x / max(width, 1)), 1))
        let seconds = session.availableRange.start.seconds
            + fraction * session.availableRange.duration
        session.update(edge: edge, to: seconds)
        onPreview(session.candidateSelection, edge)
    }

    private func x(for sourceSeconds: TimeInterval, width: CGFloat) -> CGFloat {
        let fraction = (sourceSeconds - session.availableRange.start.seconds)
            / max(session.availableRange.duration, 0.001)
        return width * CGFloat(min(max(0, fraction), 1))
    }
}

private struct TimelineTrimWaveform: View {
    @Binding var session: TimelineTrimSession
    let envelope: [Float]
    let sourceDuration: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let startX = x(for: session.candidateSelection.start.seconds, width: width)
            let endX = x(for: session.candidateSelection.end.seconds, width: width)
            ZStack(alignment: .leading) {
                waveformCanvas
                Color(uiColor: .systemGray).opacity(0.38)
                    .frame(width: max(0, startX))
                Color(uiColor: .systemGray).opacity(0.38)
                    .frame(width: max(0, width - endX))
                    .offset(x: endX)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(uiColor: .separator), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Informative audio waveform for the candidate Clip range")
    }

    private var waveformCanvas: some View {
        Canvas { context, size in
            guard !envelope.isEmpty else {
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(baseline, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                return
            }
            let duration = max(
                max(sourceDuration, session.availableRange.end.seconds),
                0.001
            )
            for (index, level) in envelope.enumerated() {
                let sourceTime = duration * (Double(index) + 0.5) / Double(envelope.count)
                guard sourceTime >= session.availableRange.start.seconds,
                      sourceTime <= session.availableRange.end.seconds else { continue }
                let x = x(for: sourceTime, width: size.width)
                let height = max(2, size.height * CGFloat(level))
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: (size.height - height) / 2))
                bar.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
                context.stroke(
                    bar,
                    with: .color(Color.accentColor.opacity(0.82)),
                    lineWidth: 1.5
                )
            }
        }
    }

    private func x(for sourceSeconds: TimeInterval, width: CGFloat) -> CGFloat {
        let fraction = (sourceSeconds - session.availableRange.start.seconds)
            / max(session.availableRange.duration, 0.001)
        return width * CGFloat(min(max(0, fraction), 1))
    }
}

enum TimelineStepMoveRules {
    static func destinationIndex(
        currentIndex: Int,
        offset: Int,
        clipCount: Int
    ) -> Int? {
        guard clipCount > 1,
              currentIndex >= 0,
              currentIndex < clipCount,
              offset == -1 || offset == 1 else { return nil }
        let destination = currentIndex + offset
        return destination >= 0 && destination < clipCount ? destination : nil
    }
}

struct TimelineFilmstripViewportLayout: Equatable {
    let viewportWidth: CGFloat

    var playheadX: CGFloat {
        max(0, viewportWidth) / 2
    }

    func contentLeadingEdge(projectOffset: CGFloat) -> CGFloat {
        playheadX - projectOffset
    }

    func contentCenterX(contentWidth: CGFloat, projectOffset: CGFloat) -> CGFloat {
        contentLeadingEdge(projectOffset: projectOffset) + max(0, contentWidth) / 2
    }
}

enum TimelineFilmstripTapRules {
    static func projectTime(
        inside range: ProjectTimeRange,
        locationX: CGFloat,
        width: CGFloat
    ) -> ProjectTime? {
        guard width.isFinite, width > 0,
              locationX.isFinite,
              range.start.seconds.isFinite,
              range.end.seconds.isFinite,
              range.end.seconds > range.start.seconds else { return nil }
        let fraction = Double(min(max(0, locationX / width), 1))
        return ProjectTime(seconds: range.start.seconds
            + (range.end.seconds - range.start.seconds) * fraction)
    }
}

struct TimelineFilmstrip: View {
    @ObservedObject var playback: TimelinePlaybackSession
    let format: ProjectFormat
    let isCommitting: Bool
    let preparationIssueCount: (TimelinePlaybackSession.FilmstripClip) -> Int
    @State private var dragOriginOffset: CGFloat?
    @State private var previousMagnification = 1.0

    var body: some View {
        GeometryReader { proxy in
            let geometry = TimelineFilmstripGeometry(
                duration: playback.state.duration,
                pointsPerSecond: playback.state.filmstripPointsPerSecond
            )
            let viewport = TimelineFilmstripViewportLayout(viewportWidth: proxy.size.width)
            filmstripSurface(
                geometry: geometry,
                viewport: viewport,
                viewportHeight: proxy.size.height
            )
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minHeight: 52, idealHeight: 92)
    }

    private func filmstripSurface(
        geometry: TimelineFilmstripGeometry,
        viewport: TimelineFilmstripViewportLayout,
        viewportHeight: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(Array(playback.state.clips.enumerated()), id: \.element.id) { index, clip in
                    clipSurface(clip, ordinal: index + 1, geometry: geometry)
                }
            }
            .frame(
                width: geometry.contentWidth,
                height: viewportHeight,
                alignment: .leading
            )
            .position(
                x: viewport.contentCenterX(
                    contentWidth: geometry.contentWidth,
                    projectOffset: geometry.offset(at: playback.state.playhead)
                ),
                y: viewportHeight / 2
            )

            playhead
                .frame(height: viewportHeight)
                .position(x: viewport.playheadX, y: viewportHeight / 2)
                .zIndex(10)
        }
        .frame(
            width: viewport.viewportWidth,
            height: viewportHeight,
            alignment: .topLeading
        )
        .clipped()
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .coordinateSpace(.named("timeline-filmstrip"))
        .gesture(scrubGesture(geometry: geometry))
        .simultaneousGesture(zoomGesture)
        .allowsHitTesting(!isCommitting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storyline Playhead")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.5 : -0.5
            playback.send(.seek(ProjectTime(seconds: playback.state.playhead.seconds + delta)))
        }
        .accessibilityAction(named: "Zoom In Timeline") {
            playback.send(.zoomIn)
        }
        .accessibilityAction(named: "Zoom Out Timeline") {
            playback.send(.zoomOut)
        }
        .accessibilitySortPriority(2)
    }

    private var playhead: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 3)
            .overlay(alignment: .top) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .offset(y: -3)
            }
            .shadow(color: .black.opacity(0.72), radius: 1.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func clipSurface(
        _ clip: TimelinePlaybackSession.FilmstripClip,
        ordinal: Int,
        geometry: TimelineFilmstripGeometry
    ) -> some View {
        let width = geometry.width(for: clip)
        return clipView(clip, ordinal: ordinal)
            .frame(width: width)
            .contentShape(Rectangle().inset(by: -max(0, (44 - width) / 2)))
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    guard let projectTime = TimelineFilmstripTapRules.projectTime(
                        inside: clip.projectTimeRange,
                        locationX: value.location.x,
                        width: width
                    ) else { return }
                    playback.send(.seek(projectTime))
                }
            )
    }

    private func clipView(_ clip: TimelinePlaybackSession.FilmstripClip, ordinal: Int) -> some View {
        let selected = playback.state.selectedClipID == clip.id
        return ZStack(alignment: .bottomLeading) {
            TimelineFilmstripFrames(clip: clip, format: format)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipped()
            Text("\(ordinal)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.primary)
                .padding(5)
                .background(.regularMaterial, in: Capsule())
                .padding(4)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if clip.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                    .padding(5)
                    .background(.regularMaterial, in: Circle())
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(selected ? Color.accentColor : Color(uiColor: .separator), lineWidth: selected ? 3 : 1)
        }
        .accessibilityLabel("Clip \(ordinal) of \(playback.state.clipCount)")
        .accessibilityValue(clipAccessibilityValue(
            clip,
            selected: selected,
            preparationIssueCount: preparationIssueCount(clip)
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Select Clip") { playback.send(.selectClip(clip.id)) }
    }

    private func scrubGesture(geometry: TimelineFilmstripGeometry) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = dragOriginOffset ?? geometry.offset(at: playback.state.playhead)
                if dragOriginOffset == nil { dragOriginOffset = origin }
                playback.send(.previewSeek(geometry.projectTime(at: origin - value.translation.width)))
            }
            .onEnded { _ in
                dragOriginOffset = nil
                playback.send(.seek(playback.state.playhead))
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let ratio = value.magnification / previousMagnification
                previousMagnification = value.magnification
                playback.send(.magnify(ratio))
            }
            .onEnded { _ in previousMagnification = 1 }
    }

    private var accessibilityValue: String {
        guard let ordinal = playback.state.selectedClipOrdinal else { return "Empty" }
        let seconds = playback.state.playhead.seconds.formatted(.number.precision(.fractionLength(1)))
        return "Clip \(ordinal) of \(playback.state.clipCount), \(seconds) seconds"
    }

    private func clipAccessibilityValue(
        _ clip: TimelinePlaybackSession.FilmstripClip,
        selected: Bool,
        preparationIssueCount: Int
    ) -> String {
        let duration = clip.duration.formatted(.number.precision(.fractionLength(1)))
        let sourceDate = clip.sourceCreatedAt?.formatted(date: .abbreviated, time: .shortened)
        return [
            sourceDate.map { "Recorded \($0)" },
            "\(duration) seconds",
            preparationIssueCount == 0
                ? "preparation ready"
                : "\(preparationIssueCount) preparation \(preparationIssueCount == 1 ? "item" : "items") need review",
            clip.isMuted ? "source audio muted" : "source audio on",
            selected ? "selected" : "not selected"
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct TimelineFilmstripFrames: View {
    private struct Request: Hashable {
        let movieURL: URL
        let selection: TakeRange
        let sampleCount: Int
    }

    let clip: TimelinePlaybackSession.FilmstripClip
    let format: ProjectFormat
    @State private var frames: [UIImage?] = []
    @State private var fallbackImage: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let metrics = TimelineFilmstripFrameSampling.metrics(
                width: geometry.size.width,
                height: geometry.size.height,
                frameAspectRatio: frameAspectRatio
            )
            HStack(spacing: 1) {
                ForEach(0..<metrics.tileCount, id: \.self) { tileIndex in
                    if let image = image(forTile: tileIndex, metrics: metrics) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: metrics.tileWidth, height: geometry.size.height)
                            .clipped()
                    } else {
                        ZStack {
                            Color(uiColor: .tertiarySystemFill)
                            Image(systemName: "film")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: metrics.tileWidth, height: geometry.size.height)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .clipped()
            .task(id: Request(
                movieURL: clip.mediaURL,
                selection: clip.selection,
                sampleCount: metrics.sampleCount
            )) {
                fallbackImage = await TakeThumbnailLoader().image(at: clip.thumbnailURL)
                let data = await TimelineTrimFrameLoader().frameData(
                    movieURL: clip.mediaURL,
                    availableRange: clip.selection,
                    count: metrics.sampleCount
                )
                guard !Task.isCancelled else { return }
                frames = await Task.detached(priority: .utility) {
                    data.map { $0.flatMap { UIImage(data: $0) } }
                }.value
            }
        }
    }

    private var frameAspectRatio: CGFloat {
        format == .portrait ? 9.0 / 16.0 : 16.0 / 9.0
    }

    private func image(
        forTile tileIndex: Int,
        metrics: TimelineFilmstripFrameSampling.Metrics
    ) -> UIImage? {
        let sampleIndex = metrics.sampleIndex(forTile: tileIndex)
        guard frames.indices.contains(sampleIndex) else { return fallbackImage }
        return frames[sampleIndex] ?? fallbackImage
    }
}

private struct TimelineFilmstripGeometry {
    let duration: ProjectTime
    let pointsPerSecond: CGFloat

    var contentWidth: CGFloat {
        max(1, CGFloat(max(0, duration.seconds)) * pointsPerSecond)
    }

    func width(for clip: TimelinePlaybackSession.FilmstripClip) -> CGFloat {
        max(1, CGFloat(clip.duration) * pointsPerSecond)
    }

    func offset(at projectTime: ProjectTime) -> CGFloat {
        CGFloat(min(max(0, projectTime.seconds), duration.seconds)) * pointsPerSecond
    }

    func projectTime(at offset: CGFloat) -> ProjectTime {
        let clampedOffset = min(max(0, offset), contentWidth)
        return ProjectTime(seconds: Double(clampedOffset / pointsPerSecond))
    }
}

@MainActor
private enum TimelinePlaybackItemBuilder {
    static func makeItem(for source: TimelinePlaybackSource) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: source.url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TimelinePlaybackPreparationError.missingVideoTrack
        }
        guard source.isMuted || source.selection != source.sourceRange else {
            return AVPlayerItem(asset: asset)
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let selectedRange: CMTimeRange
        if let selection = source.selection {
            let sourceStart = CMTime(
                seconds: videoRange.start.seconds + selection.start.seconds,
                preferredTimescale: 600
            )
            selectedRange = CMTimeRange(
                start: sourceStart,
                duration: CMTime(seconds: selection.duration, preferredTimescale: 600)
            )
        } else {
            selectedRange = videoRange
        }
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TimelinePlaybackPreparationError.cannotCreateComposition
        }
        try compositionVideoTrack.insertTimeRange(selectedRange, of: videoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = preferredTransform

        if !source.isMuted {
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
        }

        guard let immutableComposition = composition.copy() as? AVComposition else {
            throw TimelinePlaybackPreparationError.cannotCreateComposition
        }
        return AVPlayerItem(asset: immutableComposition)
    }

}

private enum TimelinePlaybackPreparationError: Error {
    case missingVideoTrack
    case cannotCreateComposition
}
