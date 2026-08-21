import AVFoundation
import SwiftUI
import UIKit

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
        let thumbnailURL: URL?
        let sourceCreatedAt: Date?
        let availableRange: TakeRange
        let selection: TakeRange
        let trimSuggestion: TakeRange?
        let isMuted: Bool

        init(
            id: TimelineClip.ID,
            projectTimeRange: ProjectTimeRange,
            thumbnailURL: URL?,
            sourceCreatedAt: Date?,
            availableRange: TakeRange = TakeRange(startSeconds: 0, endSeconds: 0),
            selection: TakeRange = TakeRange(startSeconds: 0, endSeconds: 0),
            trimSuggestion: TakeRange? = nil,
            isMuted: Bool = false
        ) {
            self.id = id
            self.projectTimeRange = projectTimeRange
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
        case selectClipForEditing(TimelineClip.ID)
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
        case let .selectClipForEditing(id):
            guard state.clips.contains(where: { $0.id == id }) else { return }
            pause()
            state.selectedClipID = id
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
                            isCommitting: isCommittingEdit || model.isEditingTimeline,
                            preparationIssueCount: model.preparationIssueCount(for:),
                            onMove: { clipID, destinationIndex in
                                commit(.move(clipID: clipID, toIndex: destinationIndex))
                            }
                        )
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
        .navigationTitle(title)
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

                    Button("Move Earlier", systemImage: "arrow.left") {
                        moveSelectedClip(by: -1)
                    }
                    .disabled(!canMoveSelectedClip(by: -1))

                    Button("Move Later", systemImage: "arrow.right") {
                        moveSelectedClip(by: 1)
                    }
                    .disabled(!canMoveSelectedClip(by: 1))

                    Divider()

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
                            Menu("Spoken Language", systemImage: "character.bubble") {
                                Button("Project Default") {
                                    commitSpokenLanguage(SpokenLanguageUpdate(
                                        takeID: sourceClip.takeID,
                                        localeIdentifier: nil
                                    ))
                                }
                                Divider()
                                Button("English (US)") {
                                    commitSpokenLanguage(SpokenLanguageUpdate(takeID: sourceClip.takeID, localeIdentifier: "en-US"))
                                }
                                Button("Italian") {
                                    commitSpokenLanguage(SpokenLanguageUpdate(takeID: sourceClip.takeID, localeIdentifier: "it-IT"))
                                }
                                Button("German") {
                                    commitSpokenLanguage(SpokenLanguageUpdate(takeID: sourceClip.takeID, localeIdentifier: "de-DE"))
                                }
                                Button("French") {
                                    commitSpokenLanguage(SpokenLanguageUpdate(takeID: sourceClip.takeID, localeIdentifier: "fr-FR"))
                                }
                                Button("Spanish") {
                                    commitSpokenLanguage(SpokenLanguageUpdate(takeID: sourceClip.takeID, localeIdentifier: "es-ES"))
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
                Text("Split needs at least 1.0s on each side of the Playhead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilitySortPriority(2.5)
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
                isGeneratingWaveform: model.isAnalyzingTrim,
                onPreview: { selection, edge in
                    playback.previewTrim(
                        clipID: session.clipID,
                        selection: selection,
                        edge: edge
                    )
                }
            )
            .disabled(isCommittingEdit)
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
        if let take = selectedTake, model.trimEnvelope(for: take).isEmpty {
            model.cleanUpEdges(takeID: take.id)
        }
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
        let destination = ordinal - 1 + offset
        return destination >= 0 && destination < playback.state.clipCount
    }

    private func moveSelectedClip(by offset: Int) {
        guard let clipID = playback.state.selectedClipID,
              let ordinal = playback.state.selectedClipOrdinal else { return }
        commit(.move(clipID: clipID, toIndex: ordinal - 1 + offset))
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
            Text("Camenya couldn't prepare these Clips. Your Takes are unchanged.")
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
            Text("\(timecode(playback.state.playhead.seconds)) / \(timecode(playback.state.duration.seconds))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
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
                playback.replaceSnapshot(
                    originalSnapshot,
                    selectedClipID: selectedClipID,
                    projectTime: projectTime
                )
                editErrorMessage = "Camenya couldn't save this edit. Your Takes and previous Storyline are unchanged."
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
                    ? "Camenya couldn't undo that edit. The current Storyline is unchanged."
                    : "Camenya couldn't redo that edit. The current Storyline is unchanged."
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
    @Binding var session: TimelineTrimSession
    let envelope: [Float]
    let sourceDuration: TimeInterval
    let movieURL: URL?
    let fallbackThumbnailURL: URL?
    let isGeneratingWaveform: Bool
    let onPreview: (TakeRange, TimelineTrimEdge) -> Void

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
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    nudgeGroup(title: "In", edge: .start)
                    Spacer(minLength: 12)
                    nudgeGroup(title: "Out", edge: .end)
                }
                VStack(spacing: 8) {
                    nudgeGroup(title: "In", edge: .start)
                    nudgeGroup(title: "Out", edge: .end)
                }
            }

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

    private func nudgeGroup(title: String, edge: TimelineTrimEdge) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(minWidth: 28, alignment: .leading)
            nudgeButton(edge: edge, direction: .earlier)
            nudgeButton(edge: edge, direction: .later)
        }
    }

    private func nudgeButton(
        edge: TimelineTrimEdge,
        direction: TimelineNudgeDirection
    ) -> some View {
        let current = edge == .start
            ? session.candidateSelection.start.seconds
            : session.candidateSelection.end.seconds
        let delta = direction == .earlier
            ? -TimelineTrimRules.nudgeSeconds
            : TimelineTrimRules.nudgeSeconds
        var proposed = session
        proposed.update(edge: edge, to: current + delta)
        let isAvailable = proposed.candidateSelection != session.candidateSelection
        return Button {
            session.update(edge: edge, to: current + delta)
            onPreview(session.candidateSelection, edge)
        } label: {
            Text(direction == .earlier ? "−0.1" : "+0.1")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 44, minHeight: 44)
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

enum TimelineReorderRules {
    static func destinationIndex(
        moving sourceIndex: Int,
        translation: CGFloat,
        widths: [CGFloat]
    ) -> Int? {
        guard widths.indices.contains(sourceIndex),
              translation.isFinite,
              widths.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }

        var destinationIndex = sourceIndex
        var distance = widths[sourceIndex] / 2
        if translation > 0 {
            for index in widths.indices where index > sourceIndex {
                distance += widths[index] / 2
                guard translation >= distance else { break }
                destinationIndex = index
                distance += widths[index] / 2
            }
        } else if translation < 0 {
            for index in widths.indices.reversed() where index < sourceIndex {
                distance += widths[index] / 2
                guard -translation >= distance else { break }
                destinationIndex = index
                distance += widths[index] / 2
            }
        }
        return destinationIndex
    }
}

enum TimelineReorderAutoScroll {
    private static let edgeWidth: CGFloat = 52
    private static let projectSecondsPerSecond: TimeInterval = 3

    static func usesContinuousDriver(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func projectTimeDelta(
        locationX: CGFloat,
        viewportWidth: CGFloat,
        elapsed: TimeInterval = 0.05
    ) -> TimeInterval {
        guard locationX.isFinite,
              viewportWidth.isFinite,
              viewportWidth > edgeWidth * 2,
              elapsed.isFinite,
              elapsed > 0 else { return 0 }
        let delta = projectSecondsPerSecond * elapsed
        if locationX < edgeWidth { return -delta }
        if locationX > viewportWidth - edgeWidth { return delta }
        return 0
    }
}

@MainActor
private final class TimelineReorderAutoScrollDriver: ObservableObject {
    struct Tick: Equatable {
        let sequence: UInt64
        let elapsed: TimeInterval
    }

    @Published private(set) var tick = Tick(sequence: 0, elapsed: 0)
    private var displayLink: CADisplayLink?

    func setActive(_ isActive: Bool) {
        if isActive {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 20,
                maximum: 30,
                preferred: 30
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            stop()
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit {
        displayLink?.invalidate()
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let elapsed = max(1.0 / 120.0, min(1.0 / 15.0, link.targetTimestamp - link.timestamp))
        tick = Tick(sequence: tick.sequence &+ 1, elapsed: elapsed)
    }
}

private struct TimelineFilmstrip: View {
    @ObservedObject var playback: TimelinePlaybackSession
    let isCommitting: Bool
    let preparationIssueCount: (TimelinePlaybackSession.FilmstripClip) -> Int
    let onMove: (TimelineClip.ID, Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var autoScrollDriver = TimelineReorderAutoScrollDriver()
    @State private var dragOriginOffset: CGFloat?
    @State private var previousMagnification = 1.0
    @State private var reorderDraft: TimelineReorderDraft?
    @State private var reorderDragTranslation: CGFloat = 0
    @State private var reorderDragLocationX: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let geometry = TimelineFilmstripGeometry(
                    duration: playback.state.duration,
                    pointsPerSecond: playback.state.filmstripPointsPerSecond
                )
                filmstripSurface(geometry: geometry, viewportWidth: proxy.size.width)
                    .onChange(of: autoScrollDriver.tick) { _, tick in
                        continueReorderAutoScroll(
                            tick: tick,
                            geometry: geometry,
                            viewportWidth: proxy.size.width
                        )
                    }
            }
            .frame(minHeight: 52, idealHeight: 92)

            if reorderDraft != nil {
                Text(reorderStatus)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .onDisappear { autoScrollDriver.stop() }
    }

    private func filmstripSurface(
        geometry: TimelineFilmstripGeometry,
        viewportWidth: CGFloat
    ) -> some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(Array(playback.state.clips.enumerated()), id: \.element.id) { index, clip in
                    reorderableClip(
                        clip,
                        sourceIndex: index,
                        geometry: geometry,
                        viewportWidth: viewportWidth
                    )
                }
            }
            .frame(width: geometry.contentWidth, alignment: .leading)
            .offset(x: viewportWidth / 2 - geometry.offset(at: playback.state.playhead))

            Rectangle()
                .fill(.primary)
                .frame(width: 2)
                .overlay(alignment: .top) {
                    Circle().fill(.primary).frame(width: 10, height: 10).offset(y: -4)
                }
                .allowsHitTesting(false)
        }
        .clipped()
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .coordinateSpace(.named("timeline-filmstrip"))
        .gesture(scrubGesture(geometry: geometry))
        .simultaneousGesture(zoomGesture)
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

    private func reorderableClip(
        _ clip: TimelinePlaybackSession.FilmstripClip,
        sourceIndex: Int,
        geometry: TimelineFilmstripGeometry,
        viewportWidth: CGFloat
    ) -> some View {
        let width = geometry.width(for: clip)
        let isDragged = reorderDraft?.clipID == clip.id
        return clipView(clip, ordinal: sourceIndex + 1)
            .frame(width: width)
            .overlay(alignment: placementAlignment(for: sourceIndex)) {
                if isPlacementTarget(sourceIndex) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: 4)
                        .padding(.vertical, 4)
                }
            }
            .offset(x: isDragged ? reorderDraft?.translation ?? 0 : 0)
            .scaleEffect(isDragged && !reduceMotion ? 1.04 : 1)
            .shadow(color: isDragged ? .secondary.opacity(0.32) : .clear, radius: 8, y: 3)
            .zIndex(isDragged ? 1 : 0)
            .contentShape(Rectangle().inset(by: -max(0, (44 - width) / 2)))
            .onTapGesture { playback.send(.selectClip(clip.id)) }
            .highPriorityGesture(reorderGesture(
                clip: clip,
                sourceIndex: sourceIndex,
                geometry: geometry,
                viewportWidth: viewportWidth
            ))
    }

    private func clipView(_ clip: TimelinePlaybackSession.FilmstripClip, ordinal: Int) -> some View {
        let selected = playback.state.selectedClipID == clip.id
        return ZStack(alignment: .bottomLeading) {
            TakeThumbnailView(url: clip.thumbnailURL, placeholderSystemName: "film", cornerRadius: 0)
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
                guard reorderDraft == nil else { return }
                let origin = dragOriginOffset ?? geometry.offset(at: playback.state.playhead)
                if dragOriginOffset == nil { dragOriginOffset = origin }
                playback.send(.previewSeek(geometry.projectTime(at: origin - value.translation.width)))
            }
            .onEnded { _ in
                guard reorderDraft == nil else { return }
                dragOriginOffset = nil
                playback.send(.seek(playback.state.playhead))
            }
    }

    private func reorderGesture(
        clip: TimelinePlaybackSession.FilmstripClip,
        sourceIndex: Int,
        geometry: TimelineFilmstripGeometry,
        viewportWidth: CGFloat
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named("timeline-filmstrip")
            ))
            .onChanged { value in
                guard !isCommitting, playback.state.clipCount > 1 else { return }
                switch value {
                case .first(true):
                    beginReorder(clip: clip, sourceIndex: sourceIndex)
                case let .second(true, drag?):
                    beginReorder(clip: clip, sourceIndex: sourceIndex)
                    updateReorder(
                        translation: drag.translation.width,
                        dragLocationX: drag.location.x,
                        geometry: geometry,
                        viewportWidth: viewportWidth
                    )
                default:
                    break
                }
            }
            .onEnded { _ in finishReorder() }
    }

    private func beginReorder(
        clip: TimelinePlaybackSession.FilmstripClip,
        sourceIndex: Int
    ) {
        guard reorderDraft == nil else { return }
        dragOriginOffset = nil
        playback.send(.pause)
        playback.send(.selectClipForEditing(clip.id))
        reorderDraft = TimelineReorderDraft(
            clipID: clip.id,
            sourceIndex: sourceIndex,
            destinationIndex: sourceIndex,
            translation: 0,
            accumulatedScrollPoints: 0
        )
        reorderDragTranslation = 0
        reorderDragLocationX = nil
    }

    private func updateReorder(
        translation: CGFloat,
        dragLocationX: CGFloat,
        geometry: TimelineFilmstripGeometry,
        viewportWidth: CGFloat
    ) {
        guard reorderDraft != nil else { return }
        reorderDragTranslation = translation
        reorderDragLocationX = dragLocationX
        let requestedDelta = TimelineReorderAutoScroll.projectTimeDelta(
            locationX: dragLocationX,
            viewportWidth: viewportWidth
        )
        if TimelineReorderAutoScroll.usesContinuousDriver(reduceMotion: reduceMotion) {
            autoScrollDriver.setActive(requestedDelta != 0)
        } else {
            autoScrollDriver.stop()
            applyReorderAutoScroll(requestedDelta, geometry: geometry)
        }
        updateReorderDraft(translation: translation, geometry: geometry)
    }

    private func continueReorderAutoScroll(
        tick: TimelineReorderAutoScrollDriver.Tick,
        geometry: TimelineFilmstripGeometry,
        viewportWidth: CGFloat
    ) {
        guard reorderDraft != nil,
              let dragLocationX = reorderDragLocationX else {
            autoScrollDriver.stop()
            return
        }
        let requestedDelta = TimelineReorderAutoScroll.projectTimeDelta(
            locationX: dragLocationX,
            viewportWidth: viewportWidth,
            elapsed: tick.elapsed
        )
        guard requestedDelta != 0 else {
            autoScrollDriver.stop()
            return
        }
        applyReorderAutoScroll(requestedDelta, geometry: geometry)
        updateReorderDraft(translation: reorderDragTranslation, geometry: geometry)
    }

    private func applyReorderAutoScroll(
        _ requestedDelta: TimeInterval,
        geometry: TimelineFilmstripGeometry
    ) {
        guard requestedDelta != 0, var draft = reorderDraft else { return }
        let previousTime = playback.state.playhead.seconds
        playback.send(.previewSeek(ProjectTime(seconds: previousTime + requestedDelta)))
        let appliedDelta = playback.state.playhead.seconds - previousTime
        draft.accumulatedScrollPoints += CGFloat(appliedDelta) * geometry.pointsPerSecond
        reorderDraft = draft
    }

    private func updateReorderDraft(
        translation: CGFloat,
        geometry: TimelineFilmstripGeometry
    ) {
        guard var draft = reorderDraft else { return }
        let effectiveTranslation = translation + draft.accumulatedScrollPoints
        guard let destinationIndex = TimelineReorderRules.destinationIndex(
                moving: draft.sourceIndex,
                translation: effectiveTranslation,
                widths: playback.state.clips.map(geometry.width(for:))
        ) else { return }
        if destinationIndex != draft.destinationIndex {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        draft.destinationIndex = destinationIndex
        draft.translation = effectiveTranslation
        reorderDraft = draft
    }

    private func finishReorder() {
        guard let draft = reorderDraft else { return }
        autoScrollDriver.stop()
        reorderDraft = nil
        reorderDragLocationX = nil
        guard draft.destinationIndex != draft.sourceIndex else {
            UIAccessibility.post(
                notification: .announcement,
                argument: "Move cancelled. Clip remains at position \(draft.sourceIndex + 1)."
            )
            return
        }
        onMove(draft.clipID, draft.destinationIndex)
    }

    private func isPlacementTarget(_ index: Int) -> Bool {
        guard let draft = reorderDraft,
              draft.destinationIndex != draft.sourceIndex else { return false }
        return index == draft.destinationIndex
    }

    private func placementAlignment(for index: Int) -> Alignment {
        guard let draft = reorderDraft, index == draft.destinationIndex else { return .center }
        return draft.destinationIndex < draft.sourceIndex ? .leading : .trailing
    }

    private var reorderStatus: String {
        guard let draft = reorderDraft else { return "" }
        if draft.destinationIndex == draft.sourceIndex {
            return "Clip \(draft.sourceIndex + 1) lifted. Drag to move; release to cancel."
        }
        return "Move Clip \(draft.sourceIndex + 1) to position \(draft.destinationIndex + 1). Release to place."
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

private struct TimelineReorderDraft: Equatable {
    let clipID: TimelineClip.ID
    let sourceIndex: Int
    var destinationIndex: Int
    var translation: CGFloat
    var accumulatedScrollPoints: CGFloat
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
