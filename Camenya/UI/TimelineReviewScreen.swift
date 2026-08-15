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
    init(snapshot: ExportSnapshot, initialSelectedClipID: TimelineClip.ID? = nil) {
        self.snapshot = snapshot
        sources = TimelinePlaybackSource.make(snapshot: snapshot)
        let clips = Self.makeFilmstripClips(snapshot: snapshot)
        let initialIndex = initialSelectedClipID.flatMap { requestedID in
            clips.firstIndex(where: { $0.id == requestedID })
        } ?? 0
        let initialClip = clips[safe: initialIndex]
        state = State(
            revision: snapshot.revision,
            duration: snapshot.duration,
            clips: clips,
            phase: clips.isEmpty ? .empty : .preparing,
            playhead: initialClip?.projectTimeRange.start ?? .zero,
            selectedClipID: initialClip?.id,
            filmstripScale: .standard
        )
        observePlayerTime()
        if !clips.isEmpty { prepareQueue(startingAt: initialIndex, localTime: 0) }
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
                    localTime: edge == .start ? 0 : max(0, selection.duration - 1.0 / 30.0)
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
        if state.phase == .playing { state.phase = .paused }
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
        localTime: TimeInterval
    ) {
        clearInstalledItems()
        installedItemIndices = [ObjectIdentifier(item): sourceIndex]
        player.insert(item, after: nil)
        player.seek(to: CMTime(seconds: localTime, preferredTimescale: 600))
        state.phase = .paused
    }

    private func clearInstalledItems() {
        completionObservers.forEach(NotificationCenter.default.removeObserver)
        completionObservers.removeAll()
        installedItemIndices.removeAll()
        player.removeAllItems()
    }

    private func itemDidFinish(_ item: AVPlayerItem?) {
        guard let item, let completedIndex = installedItemIndices[ObjectIdentifier(item)] else { return }
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

struct TimelineReviewScreen: View {
    @StateObject private var playback: TimelinePlaybackSession
    @ObservedObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCommittingEdit = false
    @State private var editErrorMessage: String?
    @State private var editRecoveryGeneration = 0
    @State private var sessionHistory = TimelineSessionHistory()
    let title: String
    let format: ProjectFormat

    init(
        snapshot: ExportSnapshot,
        title: String,
        format: ProjectFormat,
        model: AppModel,
        initialSelectedClipID: TimelineClip.ID? = nil
    ) {
        _playback = StateObject(wrappedValue: TimelinePlaybackSession(
            snapshot: snapshot,
            initialSelectedClipID: initialSelectedClipID
        ))
        _model = ObservedObject(wrappedValue: model)
        self.title = title
        self.format = format
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    viewer
                    if playback.state.phase == .failed { failureState }
                    else if playback.state.phase == .empty { emptyState }
                    else {
                        playbackStatus
                        if !pendingCaptionIssues.isEmpty { captionIssuesLink }
                        projectTimeSlider
                        TimelineFilmstrip(
                            playback: playback,
                            isCommitting: isCommittingEdit || model.isEditingTimeline,
                            onMove: { clipID, destinationIndex in
                                commit(.move(clipID: clipID, toIndex: destinationIndex))
                            }
                        )
                        playbackControls
                        if let selectedClip = playback.state.selectedClip {
                            TimelineTrimInspector(
                                clip: selectedClip,
                                clipOrdinal: playback.state.selectedClipOrdinal ?? 1,
                                clipCount: playback.state.clipCount,
                                projectTime: playback.state.playhead,
                                isCommitting: isCommittingEdit,
                                recoveryGeneration: editRecoveryGeneration,
                                onPreview: { selection, edge in
                                    playback.previewTrim(
                                        clipID: selectedClip.id,
                                        selection: selection,
                                        edge: edge
                                    )
                                },
                                onCommit: commit
                            )
                            .id(selectedClip.id)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        RemovedUnusedScreen(
                            model: model,
                            onTimelineEdit: commit,
                            onDeleteTake: deleteTakePermanently
                        )
                    } label: {
                        Label("Removed & Unused", systemImage: "archivebox")
                    }
                    .disabled(isCommittingEdit || model.isEditingTimeline)
                    .accessibilityHint("Manage recoverable removed Clips and Takes not used by the Storyline.")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isCommittingEdit || model.isEditingTimeline)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        applyHistory(.undo)
                    }
                    .disabled(!sessionHistory.canUndo || isCommittingEdit || model.isEditingTimeline)
                    .accessibilityHint(sessionHistory.canUndo
                        ? "Reverses the most recent edit from this editing session."
                        : "No edit is available to undo in this editing session.")

                    Spacer()

                    Button("Redo", systemImage: "arrow.uturn.forward") {
                        applyHistory(.redo)
                    }
                    .disabled(!sessionHistory.canRedo || isCommittingEdit || model.isEditingTimeline)
                    .accessibilityHint(sessionHistory.canRedo
                        ? "Reapplies the most recently undone edit."
                        : "No edit is available to redo in this editing session.")
                }
            }
        }
        .interactiveDismissDisabled(isCommittingEdit || model.isEditingTimeline)
        .onDisappear { playback.send(.pause) }
        .alert("Edit Not Saved", isPresented: Binding(
            get: { editErrorMessage != nil },
            set: { if !$0 { editErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { editErrorMessage = nil }
        } message: {
            Text(editErrorMessage ?? "The Storyline was not changed.")
        }
    }

    private var viewer: some View {
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
                }
            }
        }
        .aspectRatio(format == .portrait ? 9 / 16 : 16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Project Viewer")
        .accessibilityValue(viewerAccessibilityValue)
        .accessibilitySortPriority(6)
    }

    private var pendingCaptionIssues: [CaptionTimelineIssue] {
        model.project.captionTimelineIssues.filter { $0.reviewState == .needsReview }
    }

    private var captionIssuesLink: some View {
        NavigationLink {
            CaptionTimelineIssuesScreen(
                issues: pendingCaptionIssues,
                takes: model.project.takes,
                isCommitting: isCommittingEdit || model.isEditingTimeline,
                onApprove: { commit(.approveCaptionTimelineIssue(issueID: $0)) }
            )
        } label: {
            Label(
                "\(pendingCaptionIssues.count) Caption \(pendingCaptionIssues.count == 1 ? "Issue" : "Issues")",
                systemImage: "captions.bubble.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(isCommittingEdit || model.isEditingTimeline)
        .accessibilityHint("Review captions omitted from the Storyline after an edit.")
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
        let metrics = CaptionPresentationLayout.metrics(for: canvas)
        let maximumWidth = canvas.width * (1 - CaptionPresentationLayout.horizontalInsetFraction * 2)
        projectCaptionText(active)
            .font(.system(size: metrics.fontSize, weight: .bold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: max(1, maximumWidth - metrics.padding * 2))
            .padding(metrics.padding)
            .background(
                .black.opacity(0.76),
                in: RoundedRectangle(cornerRadius: metrics.cornerRadius)
            )
            .fixedSize(horizontal: false, vertical: true)
            .position(
                x: canvas.width / 2,
                y: canvas.height * CaptionPresentationLayout.centerYFraction(
                    for: playback.currentSnapshot.captionTimeline?.placement ?? .lower
                )
            )
            .accessibilityHidden(true)
    }

    private func projectCaptionText(_ active: ActiveProjectCaptionPresentation) -> Text {
        ProjectCaptionOverlayResolver.textRuns(for: active).reduce(Text("")) { result, run in
            result + Text(run.text)
                .foregroundColor(run.isHighlighted ? .yellow : .white)
                .fontWeight(run.isHighlighted ? .heavy : .bold)
        }
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

    private var playbackControls: some View {
        HStack(spacing: 8) {
            playbackButton(title: "Previous Clip", systemImage: "backward.end.fill", disabled: !playback.state.canSelectPreviousClip, intent: .selectPreviousClip)
            playbackButton(title: playback.state.isPlaying ? "Pause" : "Play", systemImage: playback.state.isPlaying ? "pause.fill" : "play.fill", disabled: playback.state.phase == .preparing, intent: .togglePlayback)
            playbackButton(title: "Next Clip", systemImage: "forward.end.fill", disabled: !playback.state.canSelectNextClip, intent: .selectNextClip)
            playbackButton(title: "Zoom Out", systemImage: "minus.magnifyingglass", intent: .zoomOut)
            playbackButton(title: "Zoom In", systemImage: "plus.magnifyingglass", intent: .zoomIn)
        }
        .frame(maxWidth: .infinity)
        .accessibilitySortPriority(3)
    }

    private var projectTimeSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Project Time")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { playback.state.playhead.seconds },
                    set: { playback.send(.previewSeek(ProjectTime(seconds: $0))) }
                ),
                in: 0...max(0.001, playback.state.duration.seconds),
                onEditingChanged: { editing in
                    if !editing { playback.send(.seek(playback.state.playhead)) }
                }
            )
            .accessibilityLabel("Project Time")
        }
        .accessibilitySortPriority(3.5)
    }

    private func playbackButton(
        title: String,
        systemImage: String,
        disabled: Bool = false,
        intent: TimelinePlaybackSession.Intent
    ) -> some View {
        Button { playback.send(intent) } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .accessibilityLabel(title)
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safeSeconds) / 60
        let remainingSeconds = Int(safeSeconds) % 60
        let tenths = Int((safeSeconds * 10).rounded(.down)) % 10
        return String(format: "%02d:%02d.%d", minutes, remainingSeconds, tenths)
    }

    private func commit(_ edit: TimelineEdit) {
        guard !isCommittingEdit else { return }
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
                case .move, .remove, .restore, .addFullTakeToStoryline:
                    animatesStructure = true
                case .trim, .resetTrim, .split, .deleteRemovedClipPermanently, .setMuted,
                     .nudgeTrim, .approveCaptionTimelineIssue:
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
                } else if case .remove = edit {
                    let ordinal = outcome.focus.flatMap { focus in
                        outcome.snapshot.clips.firstIndex(where: { $0.id == focus.clipID })
                    }.map { $0 + 1 }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: outcome.snapshot.clips.isEmpty
                            ? "Clip removed. Storyline empty. The Clip remains available in Removed and Unused."
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
                } else if case .approveCaptionTimelineIssue = edit {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: "Caption approved for the current Storyline. Preview and export now use the same caption timing."
                    )
                }
            } catch {
                playback.replaceSnapshot(
                    originalSnapshot,
                    selectedClipID: selectedClipID,
                    projectTime: projectTime
                )
                editRecoveryGeneration += 1
                editErrorMessage = "Camenya couldn't save this edit. Your Takes and previous Storyline are unchanged."
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
        let target = direction == .undo
            ? sessionHistory.undoTarget
            : sessionHistory.redoTarget
        guard let target else { return }
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
                    argument: direction == .undo ? "Undo complete." : "Redo complete."
                )
            } catch {
                playback.replaceSnapshot(
                    originalSnapshot,
                    selectedClipID: selectedClipID,
                    projectTime: projectTime
                )
                editRecoveryGeneration += 1
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
            redoFocusClipID: redoFocusClipID
        )
    }

    private func clipID(for edit: TimelineEdit) -> TimelineClip.ID? {
        switch edit {
        case let .trim(clipID, _),
             let .resetTrim(clipID),
             let .split(clipID, _),
             let .move(clipID, _),
             let .remove(clipID),
             let .restore(clipID),
             let .deleteRemovedClipPermanently(clipID),
             let .setMuted(clipID, _),
             let .nudgeTrim(clipID, _, _):
            clipID
        case .addFullTakeToStoryline, .approveCaptionTimelineIssue:
            nil
        }
    }

    private func deleteTakePermanently(_ takeID: UUID) async throws {
        try await model.deleteUnusedTakePermanently(takeID)
        sessionHistory.removeAll()
    }
}

private struct CaptionTimelineIssuesScreen: View {
    let issues: [CaptionTimelineIssue]
    let takes: [ProjectTake]
    let isCommitting: Bool
    let onApprove: (CaptionTimelineIssue.ID) -> Void

    var body: some View {
        Group {
            if issues.isEmpty {
                ContentUnavailableView {
                    Label("Captions Ready", systemImage: "checkmark.circle")
                } description: {
                    Text("No Storyline edits need caption review.")
                }
            } else {
                List(issues) { issue in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(cueText(for: issue))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(reasonText(for: issue), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(reviewDetail(for: issue))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Approve Caption for Storyline") {
                            onApprove(issue.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .disabled(isCommitting)
                        .accessibilityHint("Uses only the caption source time that remains in the current Storyline.")
                    }
                    .padding(.vertical, 6)
                }
                .safeAreaInset(edge: .bottom) {
                    if isCommitting {
                        ProgressView("Saving Caption Approval…")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.bar)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
        }
        .navigationTitle("Caption Issues")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func cueText(for issue: CaptionTimelineIssue) -> String {
        takes.first(where: { $0.id == issue.takeID })?
            .captions?.cues.first(where: { $0.id == issue.cueID })?.text
            ?? "Caption unavailable"
    }

    private func reasonText(for issue: CaptionTimelineIssue) -> String {
        if issue.fragments.isEmpty {
            return "The current Storyline contains this caption safely again."
        }
        return switch issue.reason {
        case .boundaryCut:
            "A trim cuts through this caption."
        case .discontinuousProjection:
            "This caption crosses Clips that are no longer next to each other."
        }
    }

    private func reviewDetail(for issue: CaptionTimelineIssue) -> String {
        guard !issue.fragments.isEmpty else {
            return "It stays out of preview and export until you approve its return after the earlier edit."
        }
        let duration = issue.fragments.reduce(0) { $0 + $1.sourceRange.duration }
        let durationText = String(format: "%.1f", duration)
        let fragmentText = issue.fragments.count == 1
            ? "\(durationText) seconds of source time remains."
            : "\(issue.fragments.count) separated parts remain, totaling \(durationText) seconds."
        return "\(fragmentText) The caption stays out of preview and export until you approve it. Camenya does not guess timing."
    }
}

private struct TimelineTrimInspector: View {
    let clip: TimelinePlaybackSession.FilmstripClip
    let clipOrdinal: Int
    let clipCount: Int
    let projectTime: ProjectTime
    let isCommitting: Bool
    let recoveryGeneration: Int
    let onPreview: (TakeRange, TimelineTrimEdge) -> Void
    let onCommit: (TimelineEdit) -> Void
    @State private var draft: TakeRange

    init(
        clip: TimelinePlaybackSession.FilmstripClip,
        clipOrdinal: Int,
        clipCount: Int,
        projectTime: ProjectTime,
        isCommitting: Bool,
        recoveryGeneration: Int,
        onPreview: @escaping (TakeRange, TimelineTrimEdge) -> Void,
        onCommit: @escaping (TimelineEdit) -> Void
    ) {
        self.clip = clip
        self.clipOrdinal = clipOrdinal
        self.clipCount = clipCount
        self.projectTime = projectTime
        self.isCommitting = isCommitting
        self.recoveryGeneration = recoveryGeneration
        self.onPreview = onPreview
        self.onCommit = onCommit
        _draft = State(initialValue: clip.selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Edit Clip")
                    .font(.headline)
                Spacer()
                Text("\(time(draft.start.seconds)) to \(time(draft.end.seconds))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            TimelineTrimRangeControl(
                availableRange: clip.availableRange,
                selection: $draft,
                onPreview: onPreview,
                onCommit: {
                    onCommit(.trim(clipID: clip.id, selection: draft))
                }
            )
            .frame(height: 56)
            .disabled(isCommitting)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { nudgeStartControls; nudgeEndControls }
                VStack(spacing: 8) { nudgeStartControls; nudgeEndControls }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { trimRecoveryControls }
                VStack(alignment: .leading, spacing: 8) { trimRecoveryControls }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { reorderControls }
                VStack(spacing: 8) { reorderControls }
            }

            Button(
                clip.isMuted ? "Unmute Source Audio" : "Mute Source Audio",
                systemImage: clip.isMuted ? "speaker.wave.2" : "speaker.slash"
            ) {
                onCommit(.setMuted(clipID: clip.id, isMuted: !clip.isMuted))
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .disabled(isCommitting)
            .accessibilityValue(clip.isMuted ? "Muted" : "On")
            .accessibilityHint(clip.isMuted
                ? "Includes this Clip's source audio in preview and export."
                : "Excludes this Clip's source audio from preview and export without changing the Take.")

            if clip.selection == clip.availableRange {
                Text("This Clip already uses its full Available Range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Split at Playhead", systemImage: "scissors") {
                onCommit(.split(clipID: clip.id, at: projectTime))
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .disabled(splitSourceTime == nil || isCommitting)
            .accessibilityHint(splitSourceTime == nil
                ? "Move the Playhead at least 1.0 second from each edge of this Clip."
                : "Creates two adjacent Clips without changing the immediate output.")

            if splitSourceTime == nil {
                Text("Move the Playhead at least 1.0s from each Clip edge to Split.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Remove Clip", systemImage: "archivebox") {
                onCommit(.remove(clipID: clip.id))
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .disabled(isCommitting)
            .accessibilityHint("Removes this Clip from the Storyline without deleting its Take media. You can restore it from Removed and Unused.")

            if isCommitting {
                ProgressView("Saving Edit…")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: clip.selection) { _, selection in
            draft = selection
        }
        .onChange(of: recoveryGeneration) { _, _ in
            draft = clip.selection
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit selected Clip")
        .accessibilitySortPriority(2.5)
    }

    private var nudgeStartControls: some View {
        HStack(spacing: 4) {
            Text("In")
                .font(.caption.weight(.semibold))
                .frame(minWidth: 28, alignment: .leading)
            nudgeButton(
                title: "Earlier",
                edge: .start,
                direction: .earlier
            )
            nudgeButton(
                title: "Later",
                edge: .start,
                direction: .later
            )
        }
    }

    @ViewBuilder
    private var trimRecoveryControls: some View {
        if let suggestion = clip.trimSuggestion,
           suggestion != clip.selection {
            Button("Use Silence Trim", systemImage: "waveform.badge.minus") {
                onCommit(.trim(clipID: clip.id, selection: suggestion))
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(isCommitting)
        }
        Button("Reset Trim", systemImage: "arrow.counterclockwise") {
            onCommit(.resetTrim(clipID: clip.id))
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .disabled(clip.selection == clip.availableRange || isCommitting)
        .accessibilityHint(clip.selection == clip.availableRange
            ? "This Clip already uses its full Available Range."
            : "Restores this Clip to its full Available Range.")
    }

    private var reorderControls: some View {
        Group {
            reorderButton(
                title: "Move Earlier",
                systemImage: "arrow.left",
                destinationIndex: clipOrdinal - 2
            )
            reorderButton(
                title: "Move Later",
                systemImage: "arrow.right",
                destinationIndex: clipOrdinal
            )
        }
    }

    private func reorderButton(
        title: String,
        systemImage: String,
        destinationIndex: Int
    ) -> some View {
        let destinationOrdinal = destinationIndex + 1
        let isAvailable = destinationIndex >= 0 && destinationIndex < clipCount
        return Button(title, systemImage: systemImage) {
            onCommit(.move(clipID: clip.id, toIndex: destinationIndex))
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .disabled(!isAvailable || isCommitting)
        .accessibilityValue(isAvailable ? "Result: position \(destinationOrdinal) of \(clipCount)" : "Unavailable")
        .accessibilityHint(isAvailable
            ? "Commits one Storyline edit."
            : "This Clip is already at that end of the Storyline.")
    }

    private var nudgeEndControls: some View {
        HStack(spacing: 4) {
            Text("Out")
                .font(.caption.weight(.semibold))
                .frame(minWidth: 28, alignment: .leading)
            nudgeButton(
                title: "Earlier",
                edge: .end,
                direction: .earlier
            )
            nudgeButton(
                title: "Later",
                edge: .end,
                direction: .later
            )
        }
    }

    private func nudgeButton(
        title: String,
        edge: TimelineTrimEdge,
        direction: TimelineNudgeDirection
    ) -> some View {
        let proposed = TimelineTrimRules.nudgedSelection(
            selection: clip.selection,
            availableRange: clip.availableRange,
            edge: edge,
            direction: direction
        )
        return Button {
            onCommit(.nudgeTrim(clipID: clip.id, edge: edge, direction: direction))
        } label: {
            Text(direction == .earlier ? "−0.1" : "+0.1")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(proposed == nil || isCommitting)
        .accessibilityLabel("Move trim \(edge == .start ? "start" : "end") \(title.lowercased()) by 0.1 seconds")
        .accessibilityValue(proposed.map { selection in
            let result = edge == .start ? selection.start.seconds : selection.end.seconds
            return "Result: \(time(result))"
        } ?? "Unavailable")
        .accessibilityHint(proposed == nil
            ? "The Clip Selection must stay within its Available Range and remain at least 1.0 second."
            : "Commits one Storyline edit.")
    }

    private func time(_ seconds: TimeInterval) -> String {
        seconds.formatted(.number.precision(.fractionLength(1))) + "s"
    }

    private var splitSourceTime: MediaTime? {
        TimelineSplitRules.sourceTime(
            selection: clip.selection,
            projectTimeRange: clip.projectTimeRange,
            at: projectTime
        )
    }
}

private struct RemovedUnusedScreen: View {
    private enum PendingDeletion: Identifiable {
        case removedClip(TimelineClip.ID)
        case take(UUID)

        var id: String {
            switch self {
            case let .removedClip(id): "clip-\(id.rawValue.uuidString)"
            case let .take(id): "take-\(id.uuidString)"
            }
        }
    }

    @ObservedObject var model: AppModel
    let onTimelineEdit: (TimelineEdit) -> Void
    let onDeleteTake: (UUID) async throws -> Void
    @State private var pendingDeletion: PendingDeletion?
    @State private var deleteErrorMessage: String?
    @State private var isDeletingTake = false

    var body: some View {
        Group {
            if model.project.removedClips.isEmpty && model.project.unusedTakes.isEmpty {
                ContentUnavailableView(
                    "Nothing Removed or Unused",
                    systemImage: "archivebox",
                    description: Text("Removed Clips stay recoverable here. Takes appear here when no active Clip uses them.")
                )
            } else {
                List {
                    if !model.project.removedClips.isEmpty {
                        Section("Removed Clips") {
                            ForEach(model.project.removedClips) { removed in
                                removedClipRow(removed)
                            }
                        }
                    }
                    if !model.project.unusedTakes.isEmpty {
                        Section {
                            ForEach(model.project.unusedTakes) { take in
                                unusedTakeRow(take)
                            }
                        } header: {
                            Text("Unused Takes")
                        } footer: {
                            Text("Adding a full Take creates a new Clip. Deleting a Take permanently removes its source media.")
                        }
                    }
                }
            }
        }
        .navigationTitle("Removed & Unused")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isEditingTimeline || isDeletingTake)
        .interactiveDismissDisabled(model.isEditingTimeline || isDeletingTake)
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            switch deletion {
            case let .removedClip(clipID):
                Button("Delete Removed Clip", role: .destructive) {
                    onTimelineEdit(.deleteRemovedClipPermanently(clipID: clipID))
                }
            case let .take(takeID):
                Button("Delete Take", role: .destructive) {
                    deleteTake(takeID)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletionMessage(for: deletion))
        }
        .alert("Take Not Deleted", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "The Take source media is unchanged.")
        }
    }

    private func removedClipRow(_ removed: RemovedTimelineClip) -> some View {
        let take = model.project.takes.first { $0.id == removed.clip.takeID }
        let takeNumber = model.project.takes.firstIndex { $0.id == removed.clip.takeID }.map { $0 + 1 }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(takeNumber.map { "Removed Clip from Take \($0)" } ?? "Removed Clip")
                    .font(.headline)
                if let createdAt = take?.createdAt {
                    Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Source \(time(removed.clip.selection.start.seconds))–\(time(removed.clip.selection.end.seconds)) · \(time(removed.clip.selection.duration))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Label(removed.clip.isMuted ? "Muted" : "Audio included", systemImage: removed.clip.isMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { removedClipActions(removed) }
                VStack(alignment: .leading, spacing: 8) { removedClipActions(removed) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func removedClipActions(_ removed: RemovedTimelineClip) -> some View {
        Button("Restore Clip", systemImage: "arrow.uturn.backward") {
            onTimelineEdit(.restore(clipID: removed.id))
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
        .accessibilityHint("Restores the exact saved Clip near its original Storyline position.")

        Button("Delete Removed Clip Permanently", systemImage: "trash", role: .destructive) {
            pendingDeletion = .removedClip(removed.id)
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .accessibilityHint("Deletes only the removed Clip metadata, not the Take media.")
    }

    private func unusedTakeRow(_ take: ProjectTake) -> some View {
        let takeNumber = model.project.takes.firstIndex(of: take).map { $0 + 1 }
        let dependentClips = model.project.removedClips.filter { $0.clip.takeID == take.id }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(takeNumber.map { "Take \($0)" } ?? "Unused Take")
                    .font(.headline)
                Text(take.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Full source · \(time(take.duration))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Add Full Take to Storyline", systemImage: "plus.rectangle.on.rectangle") {
                onTimelineEdit(.addFullTakeToStoryline(takeID: take.id))
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .accessibilityHint("Creates a new full-length Clip at the end of the Storyline.")

            if dependentClips.isEmpty {
                Button("Delete Take Permanently", systemImage: "trash", role: .destructive) {
                    pendingDeletion = .take(take.id)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint("Permanently deletes this unused Take source media.")
            } else {
                Text("Delete these removed Clips before deleting this Take:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(dependentClips) { removed in
                    Label(
                        "Removed Clip, source \(time(removed.clip.selection.start.seconds))–\(time(removed.clip.selection.end.seconds))",
                        systemImage: "link"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func deleteTake(_ takeID: UUID) {
        guard !isDeletingTake else { return }
        isDeletingTake = true
        Task {
            defer { isDeletingTake = false }
            do {
                try await onDeleteTake(takeID)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(notification: .announcement, argument: "Take deleted permanently.")
            } catch {
                deleteErrorMessage = "Camenya couldn't delete this Take. Its source media is unchanged."
            }
        }
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .removedClip: "Delete Removed Clip Permanently?"
        case .take: "Delete Take Permanently?"
        case nil: "Confirm Permanent Deletion"
        }
    }

    private func deletionMessage(for deletion: PendingDeletion) -> String {
        switch deletion {
        case .removedClip:
            "This deletes the saved Clip edit metadata. The original Take media remains available."
        case .take:
            "This permanently deletes the Take source media. This cannot be undone."
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safeSeconds) / 60
        let remainingSeconds = safeSeconds - TimeInterval(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainingSeconds)
    }
}

private struct TimelineTrimRangeControl: View {
    let availableRange: TakeRange
    @Binding var selection: TakeRange
    let onPreview: (TakeRange, TimelineTrimEdge) -> Void
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let startX = x(for: selection.start.seconds, width: width)
            let endX = x(for: selection.end.seconds, width: width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                    .frame(height: 10)
                Capsule()
                    .fill(.tint.opacity(0.45))
                    .frame(width: max(1, endX - startX), height: 10)
                    .offset(x: startX)
                handle(edge: .start, width: width)
                    .position(x: startX, y: proxy.size.height / 2)
                handle(edge: .end, width: width)
                    .position(x: endX, y: proxy.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(.named("trimRange"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clip Selection")
        .accessibilityValue("From \(formatted(selection.start.seconds)) to \(formatted(selection.end.seconds)) seconds")
    }

    private func handle(edge: TimelineTrimEdge, width: CGFloat) -> some View {
        Capsule()
            .fill(.tint)
            .frame(width: 8, height: 34)
            .frame(width: 44, height: 56)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimRange"))
                .onChanged { value in update(edge: edge, x: value.location.x, width: width) }
                .onEnded { _ in onCommit() }
            )
            .accessibilityLabel(edge == .start ? "Trim Start" : "Trim End")
    }

    private func update(edge: TimelineTrimEdge, x: CGFloat, width: CGFloat) {
        let proposed = seconds(for: x, width: width)
        switch edge {
        case .start:
            selection = TakeRange(
                startSeconds: min(max(availableRange.start.seconds, proposed), selection.end.seconds - 1),
                endSeconds: selection.end.seconds
            )
        case .end:
            selection = TakeRange(
                startSeconds: selection.start.seconds,
                endSeconds: max(min(availableRange.end.seconds, proposed), selection.start.seconds + 1)
            )
        }
        onPreview(selection, edge)
    }

    private func x(for seconds: TimeInterval, width: CGFloat) -> CGFloat {
        let fraction = (seconds - availableRange.start.seconds) / availableRange.duration
        return width * CGFloat(min(max(0, fraction), 1))
    }

    private func seconds(for x: CGFloat, width: CGFloat) -> TimeInterval {
        let fraction = Double(min(max(0, x / width), 1))
        return MediaTime(seconds: availableRange.start.seconds + fraction * availableRange.duration).seconds
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        seconds.formatted(.number.precision(.fractionLength(1)))
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

private struct TimelineFilmstrip: View {
    @ObservedObject var playback: TimelinePlaybackSession
    let isCommitting: Bool
    let onMove: (TimelineClip.ID, Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOriginOffset: CGFloat?
    @State private var previousMagnification = 1.0
    @State private var reorderDraft: TimelineReorderDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let geometry = TimelineFilmstripGeometry(
                    duration: playback.state.duration,
                    pointsPerSecond: playback.state.filmstripPointsPerSecond
                )
                filmstripSurface(geometry: geometry, viewportWidth: proxy.size.width)
            }
            .frame(minHeight: 52, idealHeight: 92)

            Text(reorderStatus)
                .font(.caption)
                .foregroundStyle(reorderDraft == nil ? .secondary : .primary)
        }
    }

    private func filmstripSurface(
        geometry: TimelineFilmstripGeometry,
        viewportWidth: CGFloat
    ) -> some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(Array(playback.state.clips.enumerated()), id: \.element.id) { index, clip in
                    reorderableClip(clip, sourceIndex: index, geometry: geometry)
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
        .gesture(scrubGesture(geometry: geometry))
        .simultaneousGesture(zoomGesture)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storyline Playhead")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.5 : -0.5
            playback.send(.seek(ProjectTime(seconds: playback.state.playhead.seconds + delta)))
        }
        .accessibilitySortPriority(2)
    }

    private func reorderableClip(
        _ clip: TimelinePlaybackSession.FilmstripClip,
        sourceIndex: Int,
        geometry: TimelineFilmstripGeometry
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
                geometry: geometry
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
        .accessibilityValue(clipAccessibilityValue(clip, selected: selected))
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
        geometry: TimelineFilmstripGeometry
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard !isCommitting, playback.state.clipCount > 1 else { return }
                switch value {
                case .first(true):
                    beginReorder(clip: clip, sourceIndex: sourceIndex)
                case let .second(true, drag?):
                    beginReorder(clip: clip, sourceIndex: sourceIndex)
                    updateReorder(
                        translation: drag.translation.width,
                        geometry: geometry
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
            translation: 0
        )
    }

    private func updateReorder(
        translation: CGFloat,
        geometry: TimelineFilmstripGeometry
    ) {
        guard var draft = reorderDraft,
              let destinationIndex = TimelineReorderRules.destinationIndex(
                moving: draft.sourceIndex,
                translation: translation,
                widths: playback.state.clips.map(geometry.width(for:))
              ) else { return }
        if destinationIndex != draft.destinationIndex {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        draft.destinationIndex = destinationIndex
        draft.translation = translation
        reorderDraft = draft
    }

    private func finishReorder() {
        guard let draft = reorderDraft else { return }
        reorderDraft = nil
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
        guard let draft = reorderDraft else {
            return "Long-press and drag a Clip to reorder."
        }
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
        selected: Bool
    ) -> String {
        let duration = clip.duration.formatted(.number.precision(.fractionLength(1)))
        let sourceDate = clip.sourceCreatedAt?.formatted(date: .abbreviated, time: .shortened)
        return [
            sourceDate.map { "Recorded \($0)" },
            "\(duration) seconds",
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
