import AVFoundation
import SwiftUI

private struct TimelinePlaybackSource: Equatable, Sendable {
    let url: URL
    let selection: TakeRange?
    let sourceRange: TakeRange?

    init(
        url: URL,
        selection: TakeRange?,
        sourceRange: TakeRange? = nil
    ) {
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

        init(
            id: TimelineClip.ID,
            projectTimeRange: ProjectTimeRange,
            thumbnailURL: URL?,
            sourceCreatedAt: Date?,
            availableRange: TakeRange = TakeRange(startSeconds: 0, endSeconds: 0),
            selection: TakeRange = TakeRange(startSeconds: 0, endSeconds: 0),
            trimSuggestion: TakeRange? = nil
        ) {
            self.id = id
            self.projectTimeRange = projectTimeRange
            self.thumbnailURL = thumbnailURL
            self.sourceCreatedAt = sourceCreatedAt
            self.availableRange = availableRange
            self.selection = selection
            self.trimSuggestion = trimSuggestion
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
            sourceRange: source.sourceRange
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
                self.player.removeAllItems()
                self.state.phase = .failed
            }
        }
    }

    private func install(items: [(Int, AVPlayerItem)], localTime: TimeInterval, playWhenReady: Bool) {
        completionObservers.forEach(NotificationCenter.default.removeObserver)
        completionObservers.removeAll()
        installedItemIndices.removeAll()
        player.removeAllItems()
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
        completionObservers.forEach(NotificationCenter.default.removeObserver)
        completionObservers.removeAll()
        installedItemIndices = [ObjectIdentifier(item): sourceIndex]
        player.removeAllItems()
        player.insert(item, after: nil)
        player.seek(to: CMTime(seconds: localTime, preferredTimescale: 600))
        state.phase = .paused
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
                trimSuggestion: clip.trimSuggestion
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
    @State private var isCommittingEdit = false
    @State private var editErrorMessage: String?
    @State private var editRecoveryGeneration = 0
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
                        projectTimeSlider
                        TimelineFilmstrip(playback: playback)
                            .frame(height: 92)
                        playbackControls
                        if let selectedClip = playback.state.selectedClip {
                            TimelineTrimInspector(
                                clip: selectedClip,
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isCommittingEdit || model.isEditingTimeline)
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
        ZStack {
            PlayerLayerView(player: playback.player)
                .background(Color(uiColor: .systemBackground))
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
        .aspectRatio(format == .portrait ? 9 / 16 : 16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Project Viewer")
        .accessibilityValue(phaseLabel)
        .accessibilitySortPriority(6)
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
        ContentUnavailableView(
            "Storyline Empty",
            systemImage: "film.stack",
            description: Text("Record a Take to add its first Clip.")
        )
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
        playback.send(.pause)
        isCommittingEdit = true
        Task {
            defer { isCommittingEdit = false }
            do {
                let outcome = try await model.performTimelineEdit(
                    edit,
                    expectedRevision: expectedRevision
                )
                playback.replaceSnapshot(
                    outcome.snapshot,
                    selectedClipID: selectedClipID,
                    projectTime: projectTime
                )
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
}

private struct TimelineTrimInspector: View {
    let clip: TimelinePlaybackSession.FilmstripClip
    let isCommitting: Bool
    let recoveryGeneration: Int
    let onPreview: (TakeRange, TimelineTrimEdge) -> Void
    let onCommit: (TimelineEdit) -> Void
    @State private var draft: TakeRange

    init(
        clip: TimelinePlaybackSession.FilmstripClip,
        isCommitting: Bool,
        recoveryGeneration: Int,
        onPreview: @escaping (TakeRange, TimelineTrimEdge) -> Void,
        onCommit: @escaping (TimelineEdit) -> Void
    ) {
        self.clip = clip
        self.isCommitting = isCommitting
        self.recoveryGeneration = recoveryGeneration
        self.onPreview = onPreview
        self.onCommit = onCommit
        _draft = State(initialValue: clip.selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trim Clip")
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

            HStack(spacing: 8) {
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
            .frame(maxWidth: .infinity, alignment: .leading)

            if clip.selection == clip.availableRange {
                Text("This Clip already uses its full Available Range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        .accessibilityLabel("Trim selected Clip")
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

private struct TimelineFilmstrip: View {
    @ObservedObject var playback: TimelinePlaybackSession
    @State private var dragOriginOffset: CGFloat?
    @State private var previousMagnification = 1.0

    var body: some View {
        GeometryReader { proxy in
            let geometry = TimelineFilmstripGeometry(
                duration: playback.state.duration,
                pointsPerSecond: playback.state.filmstripPointsPerSecond
            )
            ZStack {
                HStack(spacing: 0) {
                    ForEach(Array(playback.state.clips.enumerated()), id: \.element.id) { index, clip in
                        let width = geometry.width(for: clip)
                        clipView(clip, ordinal: index + 1)
                            .frame(width: width)
                            .contentShape(Rectangle().inset(by: -max(0, (44 - width) / 2)))
                            .onTapGesture { playback.send(.selectClip(clip.id)) }
                    }
                }
                .frame(width: geometry.contentWidth, alignment: .leading)
                .offset(x: proxy.size.width / 2 - geometry.offset(at: playback.state.playhead))

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
        selected: Bool
    ) -> String {
        let duration = clip.duration.formatted(.number.precision(.fractionLength(1)))
        let sourceDate = clip.sourceCreatedAt?.formatted(date: .abbreviated, time: .shortened)
        return [
            sourceDate.map { "Recorded \($0)" },
            "\(duration) seconds",
            selected ? "selected" : "not selected"
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
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
        guard let selection = source.selection,
              selection != source.sourceRange else {
            return AVPlayerItem(asset: asset)
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

}

private enum TimelinePlaybackPreparationError: Error {
    case missingVideoTrack
    case cannotCreateComposition
}
