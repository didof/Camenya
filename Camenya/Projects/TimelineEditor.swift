import Foundation

struct FinalizedTake: Equatable, Sendable {
    let id: UUID
    let movieURL: URL
    let orientation: TakeOrientation
    let duration: TimeInterval
    let createdAt: Date
}

struct TakeCompletion: Equatable, Sendable {
    let project: ProjectManifest
    let take: ProjectTake
    let clip: TimelineClip
    let snapshot: ExportSnapshot
}

enum TimelineEdit: Equatable, Sendable {
    case trim(clipID: TimelineClip.ID, selection: TakeRange)
    case resetTrim(clipID: TimelineClip.ID)
    case split(clipID: TimelineClip.ID, at: ProjectTime)
    case join(leadingClipID: TimelineClip.ID)
    case move(clipID: TimelineClip.ID, toIndex: Int)
    case remove(clipID: TimelineClip.ID)
    case restore(clipID: TimelineClip.ID)
    case deleteRemovedClipPermanently(clipID: TimelineClip.ID)
    case addFullTakeToStoryline(takeID: UUID)
    case setMuted(clipID: TimelineClip.ID, isMuted: Bool)
    case nudgeTrim(
        clipID: TimelineClip.ID,
        edge: TimelineTrimEdge,
        direction: TimelineNudgeDirection
    )
}

extension TimelineEdit {
    var operationName: String {
        switch self {
        case .trim: "Trim"
        case .resetTrim: "Reset Trim"
        case .split: "Split"
        case .join: "Join"
        case .move: "Move Clip"
        case .remove: "Remove Clip"
        case .restore: "Restore Clip"
        case .deleteRemovedClipPermanently: "Delete Removed Clip"
        case .addFullTakeToStoryline: "Add Take"
        case let .setMuted(_, isMuted): isMuted ? "Mute Source Audio" : "Include Source Audio"
        case .nudgeTrim: "Adjust Trim"
        }
    }
}

enum TimelineTrimEdge: Equatable, Sendable {
    case start
    case end
}

enum TimelineNudgeDirection: Equatable, Sendable {
    case earlier
    case later
}

enum TimelineTrimRules {
    static let minimumDuration: TimeInterval = 1
    static let nudgeSeconds: TimeInterval = 0.1

    static func isValid(_ selection: TakeRange, inside availableRange: TakeRange) -> Bool {
        selection.isValid(
            inside: availableRange.end.seconds,
            minimumDuration: minimumDuration
        )
            && selection.start.seconds >= availableRange.start.seconds
            && selection.end.seconds <= availableRange.end.seconds
    }

    static func nudgedSelection(
        selection: TakeRange,
        availableRange: TakeRange,
        edge: TimelineTrimEdge,
        direction: TimelineNudgeDirection
    ) -> TakeRange? {
        let delta = direction == .later ? nudgeSeconds : -nudgeSeconds
        let proposed: TakeRange
        switch edge {
        case .start:
            proposed = TakeRange(
                startSeconds: selection.start.seconds + delta,
                endSeconds: selection.end.seconds
            )
        case .end:
            proposed = TakeRange(
                startSeconds: selection.start.seconds,
                endSeconds: selection.end.seconds + delta
            )
        }
        return isValid(proposed, inside: availableRange) ? proposed : nil
    }
}

enum TimelineSplitRules {
    static func sourceTime(
        selection: TakeRange,
        projectTimeRange: ProjectTimeRange,
        at projectTime: ProjectTime
    ) -> MediaTime? {
        let projectSeconds = projectTime.seconds
        let projectStart = projectTimeRange.start.seconds
        let projectEnd = projectTimeRange.end.seconds
        guard projectSeconds.isFinite,
              projectSeconds > projectStart,
              projectSeconds < projectEnd else {
            return nil
        }
        let sourceTime = MediaTime(
            seconds: selection.start.seconds + projectSeconds - projectStart
        )
        guard sourceTime.seconds - selection.start.seconds >= TimelineTrimRules.minimumDuration,
              selection.end.seconds - sourceTime.seconds >= TimelineTrimRules.minimumDuration else {
            return nil
        }
        return sourceTime
    }
}

enum TimelineJoinDirection: Equatable, Sendable {
    case previous
    case next
}

struct TimelineJoinChoice: Equatable, Sendable {
    let direction: TimelineJoinDirection
    let leadingClipID: TimelineClip.ID
}

enum TimelineJoinRules {
    static func joinedClip(
        leading: TimelineClip,
        trailing: TimelineClip
    ) -> TimelineClip? {
        guard let sharedBoundaryID = leading.trailingSplitBoundaryID,
              sharedBoundaryID == trailing.leadingSplitBoundaryID,
              leading.takeID == trailing.takeID,
              leading.availableRange.end == trailing.availableRange.start,
              leading.selection.end == trailing.selection.start,
              leading.isMuted == trailing.isMuted else {
            return nil
        }
        return TimelineClip(
            takeID: leading.takeID,
            availableRange: TakeRange(
                start: leading.availableRange.start,
                end: trailing.availableRange.end
            ),
            selection: TakeRange(
                start: leading.selection.start,
                end: trailing.selection.end
            ),
            isMuted: leading.isMuted,
            leadingSplitBoundaryID: leading.leadingSplitBoundaryID,
            trailingSplitBoundaryID: trailing.trailingSplitBoundaryID
        )
    }

    static func choices(
        for selectedClipID: TimelineClip.ID,
        in clips: [TimelineClip]
    ) -> [TimelineJoinChoice] {
        guard let index = clips.firstIndex(where: { $0.id == selectedClipID }) else {
            return []
        }
        var choices: [TimelineJoinChoice] = []
        if index > clips.startIndex,
           joinedClip(leading: clips[index - 1], trailing: clips[index]) != nil {
            choices.append(TimelineJoinChoice(
                direction: .previous,
                leadingClipID: clips[index - 1].id
            ))
        }
        if index + 1 < clips.endIndex,
           joinedClip(leading: clips[index], trailing: clips[index + 1]) != nil {
            choices.append(TimelineJoinChoice(
                direction: .next,
                leadingClipID: clips[index].id
            ))
        }
        return choices
    }
}

struct TimelineTrimSession: Equatable, Sendable {
    let clipID: TimelineClip.ID
    let availableRange: TakeRange
    let originalSelection: TakeRange
    private(set) var candidateSelection: TakeRange

    init(
        clipID: TimelineClip.ID,
        availableRange: TakeRange,
        selection: TakeRange
    ) {
        self.clipID = clipID
        self.availableRange = availableRange
        self.originalSelection = selection
        self.candidateSelection = selection
    }

    mutating func update(edge: TimelineTrimEdge, to sourceSeconds: TimeInterval) {
        guard sourceSeconds.isFinite else { return }
        switch edge {
        case .start:
            candidateSelection = TakeRange(
                startSeconds: min(
                    max(availableRange.start.seconds, sourceSeconds),
                    candidateSelection.end.seconds - TimelineTrimRules.minimumDuration
                ),
                endSeconds: candidateSelection.end.seconds
            )
        case .end:
            candidateSelection = TakeRange(
                startSeconds: candidateSelection.start.seconds,
                endSeconds: max(
                    min(availableRange.end.seconds, sourceSeconds),
                    candidateSelection.start.seconds + TimelineTrimRules.minimumDuration
                )
            )
        }
    }

    mutating func nudge(
        edge: TimelineTrimEdge,
        direction: TimelineNudgeDirection,
        seconds: TimeInterval
    ) {
        guard seconds.isFinite, seconds > 0 else { return }
        let current = edge == .start
            ? candidateSelection.start.seconds
            : candidateSelection.end.seconds
        update(
            edge: edge,
            to: current + (direction == .earlier ? -seconds : seconds)
        )
    }

    var commitEdit: TimelineEdit? {
        guard candidateSelection != originalSelection else { return nil }
        return .trim(clipID: clipID, selection: candidateSelection)
    }

    var cancelledSelection: TakeRange { originalSelection }
}

enum TimelineRemovalRules {
    static func placement(removingAt index: Int, from clips: [TimelineClip]) -> TimelinePlacementContext {
        TimelinePlacementContext(
            previousClipID: index > clips.startIndex ? clips[index - 1].id : nil,
            nextClipID: index + 1 < clips.endIndex ? clips[index + 1].id : nil,
            originalIndex: index
        )
    }

    static func restorationIndex(
        placement: TimelinePlacementContext,
        activeClips: [TimelineClip]
    ) -> Int {
        let previousIndex = placement.previousClipID.flatMap { id in
            activeClips.firstIndex { $0.id == id }
        }
        let nextIndex = placement.nextClipID.flatMap { id in
            activeClips.firstIndex { $0.id == id }
        }

        if let previousIndex, let nextIndex, previousIndex + 1 == nextIndex {
            return nextIndex
        }

        let candidates = [previousIndex.map { $0 + 1 }, nextIndex].compactMap { $0 }
        if let nearest = candidates.min(by: {
            let leftDistance = abs($0 - placement.originalIndex)
            let rightDistance = abs($1 - placement.originalIndex)
            return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
        }) {
            return min(max(nearest, 0), activeClips.count)
        }
        return min(max(placement.originalIndex, 0), activeClips.count)
    }
}

struct TimelineEditActivity: Equatable, Sendable {
    private(set) var isActive = false

    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    mutating func finish() {
        isActive = false
    }
}

struct TimelineEditOutcome: Equatable, Sendable {
    let project: ProjectManifest
    let snapshot: ExportSnapshot
    let focus: TimelineEditFocus?

    init(
        project: ProjectManifest,
        snapshot: ExportSnapshot,
        focus: TimelineEditFocus? = nil
    ) {
        self.project = project
        self.snapshot = snapshot
        self.focus = focus
    }
}

struct TimelineEditFocus: Equatable, Sendable {
    let clipID: TimelineClip.ID
    let projectTime: ProjectTime
}

struct TimelineSessionState: Equatable, Sendable {
    let clips: [TimelineClip]
    let removedClips: [RemovedTimelineClip]

    init(
        clips: [TimelineClip],
        removedClips: [RemovedTimelineClip]
    ) {
        self.clips = clips
        self.removedClips = removedClips
    }

    init(project: ProjectManifest) {
        clips = project.primaryStoryline.clips
        removedClips = project.removedClips
    }
}

struct TimelineSessionHistoryTarget: Equatable, Sendable {
    let state: TimelineSessionState
    let focusClipID: TimelineClip.ID?
}

struct TimelineSessionHistory: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let before: TimelineSessionState
        let after: TimelineSessionState
        let undoFocusClipID: TimelineClip.ID?
        let redoFocusClipID: TimelineClip.ID?
        let operationName: String
    }

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var undoOperationName: String? { undoEntries.last?.operationName }
    var redoOperationName: String? { redoEntries.last?.operationName }

    var undoTarget: TimelineSessionHistoryTarget? {
        undoEntries.last.map {
            TimelineSessionHistoryTarget(state: $0.before, focusClipID: $0.undoFocusClipID)
        }
    }

    var redoTarget: TimelineSessionHistoryTarget? {
        redoEntries.last.map {
            TimelineSessionHistoryTarget(state: $0.after, focusClipID: $0.redoFocusClipID)
        }
    }

    mutating func record(
        before: TimelineSessionState,
        after: TimelineSessionState,
        undoFocusClipID: TimelineClip.ID?,
        redoFocusClipID: TimelineClip.ID?,
        operationName: String = "Storyline Edit"
    ) {
        guard before != after else { return }
        undoEntries.append(Entry(
            before: before,
            after: after,
            undoFocusClipID: undoFocusClipID,
            redoFocusClipID: redoFocusClipID,
            operationName: operationName
        ))
        redoEntries.removeAll()
    }

    mutating func didUndo() {
        guard let entry = undoEntries.popLast() else { return }
        redoEntries.append(entry)
    }

    mutating func didRedo() {
        guard let entry = redoEntries.popLast() else { return }
        undoEntries.append(entry)
    }

    mutating func removeAll() {
        undoEntries.removeAll()
        redoEntries.removeAll()
    }
}

enum TimelineEditorError: Error, Equatable {
    case projectNotFound(UUID)
    case mediaNotFound(URL)
    case formatMismatch(expected: ProjectFormat, received: ProjectFormat)
    case invalidSourceRange(UUID)
    case conflictingTake(UUID)
    case staleRevision(expected: StorylineRevision, actual: StorylineRevision)
    case missingTake(UUID)
    case invalidClip(TimelineClip.ID)
    case corruptPrimaryStoryline
    case revisionExhausted
    case editingUnavailable
    case pictureLocked
}

actor TimelineEditor {
    let projectID: UUID
    let projectStore: ProjectStore

    init(projectID: UUID, projectStore: ProjectStore) {
        self.projectID = projectID
        self.projectStore = projectStore
    }

    func completeFinalizedTake(
        _ finalizedTake: FinalizedTake,
        expectedRevision: StorylineRevision,
        completedAt: Date = Date()
    ) throws -> TakeCompletion {
        var project = try projectStore.load(id: projectID)
        if let existingTake = project.takes.first(where: { $0.id == finalizedTake.id }) {
            guard existingTake.createdAt == finalizedTake.createdAt,
                  existingTake.duration == finalizedTake.duration,
                  project.format == ProjectFormat(orientation: finalizedTake.orientation) else {
                throw TimelineEditorError.conflictingTake(finalizedTake.id)
            }
            let matchingClips = project.primaryStoryline.clips.filter {
                $0.takeID == finalizedTake.id
            }
            guard matchingClips.count == 1, let existingClip = matchingClips.first else {
                throw TimelineEditorError.corruptPrimaryStoryline
            }
            let snapshot = try makeSnapshot(project: project)
            try projectStore.cleanCompletedTakeArtifacts(
                projectID: projectID,
                takeID: finalizedTake.id
            )
            return TakeCompletion(
                project: project,
                take: existingTake,
                clip: existingClip,
                snapshot: snapshot
            )
        }
        guard project.pictureLock == nil else { throw TimelineEditorError.pictureLocked }
        guard project.primaryStoryline.revision == expectedRevision else {
            throw TimelineEditorError.staleRevision(
                expected: expectedRevision,
                actual: project.primaryStoryline.revision
            )
        }
        guard finalizedTake.duration.isFinite, finalizedTake.duration > 0 else {
            throw TimelineEditorError.invalidSourceRange(finalizedTake.id)
        }
        guard FileManager.default.fileExists(atPath: finalizedTake.movieURL.path) else {
            throw TimelineEditorError.mediaNotFound(finalizedTake.movieURL)
        }

        let format = ProjectFormat(orientation: finalizedTake.orientation)
        if let existing = project.format, existing != format {
            throw TimelineEditorError.formatMismatch(expected: existing, received: format)
        }

        let destinationURL = projectStore.takeMovieURL(projectID: projectID, takeID: finalizedTake.id)
        let directory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if finalizedTake.movieURL.standardizedFileURL != destinationURL.standardizedFileURL {
            let stagedURL = directory.appendingPathComponent("take.pending.mov")
            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.copyItem(at: finalizedTake.movieURL, to: stagedURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
            }
        }

        let take = ProjectTake(
            id: finalizedTake.id,
            createdAt: finalizedTake.createdAt,
            duration: finalizedTake.duration
        )
        let sourceRange = TakeRange(startSeconds: 0, endSeconds: finalizedTake.duration)
        let clip = TimelineClip(
            takeID: finalizedTake.id,
            availableRange: sourceRange,
            selection: sourceRange
        )
        project.format = project.format ?? format
        project.takes.append(take)
        project.primaryStoryline.clips.append(clip)
        project.primaryStoryline.revision = try project.primaryStoryline.revision.incremented()
        project.modifiedAt = completedAt
        do {
            try projectStore.persist(project, expectedRevision: expectedRevision)
        } catch ProjectStoreError.staleManifest {
            return try completeFinalizedTake(
                finalizedTake,
                expectedRevision: expectedRevision,
                completedAt: completedAt
            )
        } catch let ProjectStoreError.staleRevision(expected, actual) {
            throw TimelineEditorError.staleRevision(expected: expected, actual: actual)
        }
        try projectStore.cleanCompletedTakeArtifacts(
            projectID: projectID,
            takeID: finalizedTake.id
        )

        return TakeCompletion(
            project: project,
            take: take,
            clip: clip,
            snapshot: try makeSnapshot(project: project)
        )
    }

    func snapshot() throws -> ExportSnapshot {
        try Self.resolveSnapshot(
            project: projectStore.load(id: projectID),
            projectStore: projectStore
        )
    }

    func perform(
        _ edit: TimelineEdit,
        expectedRevision: StorylineRevision,
        modifiedAt: Date = Date()
    ) throws -> TimelineEditOutcome {
        var project = try projectStore.load(id: projectID)
        guard project.pictureLock == nil else { throw TimelineEditorError.pictureLocked }
        guard project.primaryStoryline.revision == expectedRevision else {
            throw TimelineEditorError.staleRevision(
                expected: expectedRevision,
                actual: project.primaryStoryline.revision
            )
        }
        var focusedClipID: TimelineClip.ID?
        var focusedProjectTime: ProjectTime?

        switch edit {
        case let .trim(clipID, selection):
            let clipIndex = try clipIndex(for: clipID, in: project)
            let clip = project.primaryStoryline.clips[clipIndex]
            guard Self.selectionIsValid(selection, for: clip) else {
                throw TimelineEditorError.invalidClip(clipID)
            }
            project.primaryStoryline.clips[clipIndex] = clip.replacingSelection(with: selection)
        case let .resetTrim(clipID):
            let clipIndex = try clipIndex(for: clipID, in: project)
            let clip = project.primaryStoryline.clips[clipIndex]
            project.primaryStoryline.clips[clipIndex] = clip.replacingSelection(with: clip.availableRange)
        case let .split(clipID, projectTime):
            let clipIndex = try clipIndex(for: clipID, in: project)
            let clip = project.primaryStoryline.clips[clipIndex]
            let snapshot = try makeSnapshot(project: project)
            guard let snapshotClip = snapshot.clips.first(where: { $0.id == clipID }),
                  let sourceTime = TimelineSplitRules.sourceTime(
                    selection: snapshotClip.selection,
                    projectTimeRange: snapshotClip.projectTimeRange,
                    at: projectTime
                  ) else {
                throw TimelineEditorError.invalidClip(clipID)
            }
            let boundaryID = TimelineClip.SplitBoundaryID()
            let left = TimelineClip(
                takeID: clip.takeID,
                availableRange: TakeRange(
                    start: clip.availableRange.start,
                    end: sourceTime
                ),
                selection: TakeRange(
                    start: clip.selection.start,
                    end: sourceTime
                ),
                isMuted: clip.isMuted,
                leadingSplitBoundaryID: clip.leadingSplitBoundaryID,
                trailingSplitBoundaryID: boundaryID
            )
            let right = TimelineClip(
                takeID: clip.takeID,
                availableRange: TakeRange(
                    start: sourceTime,
                    end: clip.availableRange.end
                ),
                selection: TakeRange(
                    start: sourceTime,
                    end: clip.selection.end
                ),
                isMuted: clip.isMuted,
                leadingSplitBoundaryID: boundaryID,
                trailingSplitBoundaryID: clip.trailingSplitBoundaryID
            )
            project.primaryStoryline.clips.replaceSubrange(
                clipIndex...clipIndex,
                with: [left, right]
            )
            focusedClipID = right.id
        case let .join(leadingClipID):
            let leadingIndex = try clipIndex(for: leadingClipID, in: project)
            let trailingIndex = leadingIndex + 1
            guard project.primaryStoryline.clips.indices.contains(trailingIndex) else {
                throw TimelineEditorError.invalidClip(leadingClipID)
            }
            let leading = project.primaryStoryline.clips[leadingIndex]
            let trailing = project.primaryStoryline.clips[trailingIndex]
            guard let joined = TimelineJoinRules.joinedClip(
                leading: leading,
                trailing: trailing
            ) else {
                throw TimelineEditorError.invalidClip(leadingClipID)
            }
            let snapshot = try makeSnapshot(project: project)
            let boundaryProjectTime = snapshot.clips[leadingIndex].projectTimeRange.end
            project.primaryStoryline.clips.replaceSubrange(
                leadingIndex...trailingIndex,
                with: [joined]
            )
            focusedClipID = joined.id
            focusedProjectTime = boundaryProjectTime
        case let .move(clipID, destinationIndex):
            let sourceIndex = try clipIndex(for: clipID, in: project)
            guard project.primaryStoryline.clips.indices.contains(destinationIndex),
                  destinationIndex != sourceIndex else {
                throw TimelineEditorError.invalidClip(clipID)
            }
            let clip = project.primaryStoryline.clips.remove(at: sourceIndex)
            project.primaryStoryline.clips.insert(clip, at: destinationIndex)
            focusedClipID = clip.id
        case let .remove(clipID):
            let clipIndex = try clipIndex(for: clipID, in: project)
            let placement = TimelineRemovalRules.placement(
                removingAt: clipIndex,
                from: project.primaryStoryline.clips
            )
            let clip = project.primaryStoryline.clips.remove(at: clipIndex)
            project.removedClips.append(RemovedTimelineClip(clip: clip, placement: placement))
            if !project.primaryStoryline.clips.isEmpty {
                focusedClipID = project.primaryStoryline.clips[
                    min(clipIndex, project.primaryStoryline.clips.count - 1)
                ].id
            }
        case let .restore(clipID):
            guard let removedIndex = project.removedClips.firstIndex(where: { $0.id == clipID }) else {
                throw TimelineEditorError.invalidClip(clipID)
            }
            let removed = project.removedClips.remove(at: removedIndex)
            let destination = TimelineRemovalRules.restorationIndex(
                placement: removed.placement,
                activeClips: project.primaryStoryline.clips
            )
            project.primaryStoryline.clips.insert(removed.clip, at: destination)
            focusedClipID = removed.clip.id
        case let .deleteRemovedClipPermanently(clipID):
            guard let removedIndex = project.removedClips.firstIndex(where: { $0.id == clipID }) else {
                throw TimelineEditorError.invalidClip(clipID)
            }
            project.removedClips.remove(at: removedIndex)
        case let .addFullTakeToStoryline(takeID):
            guard !project.primaryStoryline.clips.contains(where: { $0.takeID == takeID }),
                  let take = project.takes.first(where: { $0.id == takeID }),
                  take.duration.isFinite,
                  take.duration > 0 else {
                throw TimelineEditorError.missingTake(takeID)
            }
            let fullRange = TakeRange(startSeconds: 0, endSeconds: take.duration)
            let clip = TimelineClip(
                takeID: take.id,
                availableRange: fullRange,
                selection: fullRange
            )
            project.primaryStoryline.clips.append(clip)
            focusedClipID = clip.id
        case let .setMuted(clipID, isMuted):
            let clipIndex = try clipIndex(for: clipID, in: project)
            let clip = project.primaryStoryline.clips[clipIndex]
            guard clip.isMuted != isMuted else {
                throw TimelineEditorError.invalidClip(clipID)
            }
            project.primaryStoryline.clips[clipIndex] = clip.replacingMutedState(with: isMuted)
        case let .nudgeTrim(clipID, edge, direction):
            let clipIndex = try clipIndex(for: clipID, in: project)
            let clip = project.primaryStoryline.clips[clipIndex]
            guard let selection = TimelineTrimRules.nudgedSelection(
                selection: clip.selection,
                availableRange: clip.availableRange,
                edge: edge,
                direction: direction
            ) else {
                throw TimelineEditorError.invalidClip(clipID)
            }
            project.primaryStoryline.clips[clipIndex] = clip.replacingSelection(with: selection)
        }

        project.primaryStoryline.revision = try project.primaryStoryline.revision.incremented()
        project.modifiedAt = modifiedAt
        do {
            try projectStore.persist(project, expectedRevision: expectedRevision)
        } catch let ProjectStoreError.staleRevision(expected, actual) {
            throw TimelineEditorError.staleRevision(expected: expected, actual: actual)
        }
        let committed = try projectStore.load(id: projectID)
        let committedSnapshot = try makeSnapshot(project: committed)
        let focus = focusedClipID.flatMap { clipID in
            committedSnapshot.clips.first(where: { $0.id == clipID }).map {
                TimelineEditFocus(
                    clipID: clipID,
                    projectTime: focusedProjectTime ?? $0.projectTimeRange.start
                )
            }
        }
        return TimelineEditOutcome(
            project: committed,
            snapshot: committedSnapshot,
            focus: focus
        )
    }

    func restoreSessionState(
        _ state: TimelineSessionState,
        expectedRevision: StorylineRevision,
        focusClipID: TimelineClip.ID?,
        modifiedAt: Date = Date()
    ) throws -> TimelineEditOutcome {
        var project = try projectStore.load(id: projectID)
        guard project.pictureLock == nil else { throw TimelineEditorError.pictureLocked }
        guard project.primaryStoryline.revision == expectedRevision else {
            throw TimelineEditorError.staleRevision(
                expected: expectedRevision,
                actual: project.primaryStoryline.revision
            )
        }
        guard Self.sessionStateIsValid(state, in: project) else {
            throw TimelineEditorError.corruptPrimaryStoryline
        }

        project.primaryStoryline.clips = state.clips
        project.removedClips = state.removedClips
        project.primaryStoryline.revision = try project.primaryStoryline.revision.incremented()
        project.modifiedAt = modifiedAt
        do {
            try projectStore.persist(project, expectedRevision: expectedRevision)
        } catch let ProjectStoreError.staleRevision(expected, actual) {
            throw TimelineEditorError.staleRevision(expected: expected, actual: actual)
        }

        let committed = try projectStore.load(id: projectID)
        let committedSnapshot = try makeSnapshot(project: committed)
        let focus = focusClipID.flatMap { clipID in
            committedSnapshot.clips.first(where: { $0.id == clipID }).map {
                TimelineEditFocus(clipID: clipID, projectTime: $0.projectTimeRange.start)
            }
        }
        return TimelineEditOutcome(
            project: committed,
            snapshot: committedSnapshot,
            focus: focus
        )
    }

    private nonisolated static func resolveSnapshot(
        project: ProjectManifest,
        projectStore: ProjectStore
    ) throws -> ExportSnapshot {
        var cursor: TimeInterval = 0
        let sourceClips = project.pictureLock?.clips ?? project.primaryStoryline.clips
        let clips = try sourceClips.map { clip in
            guard let take = project.takes.first(where: { $0.id == clip.takeID }) else {
                throw TimelineEditorError.missingTake(clip.takeID)
            }
            let sourceRange = TakeRange(startSeconds: 0, endSeconds: take.duration)
            guard clip.availableRange.isValid(inside: take.duration, minimumDuration: 0.001),
                  clip.selection.start.seconds >= clip.availableRange.start.seconds,
                  clip.selection.end.seconds <= clip.availableRange.end.seconds,
                  clip.selection.duration > 0 else {
                throw TimelineEditorError.invalidClip(clip.id)
            }
            let start = cursor
            cursor += clip.selection.duration
            let trimSuggestion: TakeRange?
            if case let .suggestion(suggestion) = take.trimAnalysis {
                let adapted = TakeRange(
                    startSeconds: max(
                        clip.availableRange.start.seconds,
                        suggestion.range.start.seconds
                    ),
                    endSeconds: min(
                        clip.availableRange.end.seconds,
                        suggestion.range.end.seconds
                    )
                )
                trimSuggestion = adapted.isValid(inside: take.duration, minimumDuration: 1)
                    ? adapted
                    : nil
            } else {
                trimSuggestion = nil
            }
            return ExportSnapshot.Clip(
                id: clip.id,
                takeID: take.id,
                mediaURL: projectStore.takeMovieURL(projectID: project.id, takeID: take.id),
                thumbnailURL: take.thumbnailFileName == nil
                    ? nil
                    : projectStore.takeThumbnailURL(projectID: project.id, takeID: take.id),
                sourceCreatedAt: take.createdAt,
                sourceRange: sourceRange,
                availableRange: clip.availableRange,
                selection: clip.selection,
                trimSuggestion: trimSuggestion,
                isMuted: clip.isMuted,
                projectTimeRange: ProjectTimeRange(
                    start: ProjectTime(seconds: start),
                    end: ProjectTime(seconds: cursor)
                )
            )
        }
        let captionTimeline: ProjectCaptionExportTimeline?
        if project.hasPhotosConfirmedPictureLock,
           let pictureLock = project.pictureLock,
           let track = project.projectCaptionTrack,
           track.pictureLockID == pictureLock.id,
           track.reviewState == .approved,
           track.isGenerationComplete,
           let configuration = project.captionConfiguration {
            captionTimeline = ProjectCaptionExportTimeline(
                placement: configuration.placement,
                style: configuration.style,
                customization: configuration.customization,
                duration: cursor,
                cues: track.cues.compactMap { cue in
                    guard cue.isEnabled,
                          !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    let trustedTiming = cue.hasTrustworthyWordTiming
                    return ProjectCaptionExportCue(
                        range: cue.range,
                        text: cue.text,
                        timedSpans: trustedTiming ? cue.timedSpans : []
                    )
                }
            )
        } else {
            captionTimeline = nil
        }
        let finishingTimeline = project.hasPhotosConfirmedPictureLock
            ? project.pictureLock.map { pictureLock in
            ProjectFinishingTimeline(
                pictureLockID: pictureLock.id,
                duration: cursor,
                textOverlays: project.projectTextOverlays,
                captions: captionTimeline
            )
        } : nil
        return ExportSnapshot(
            projectID: project.id,
            revision: project.pictureLock?.storylineRevision ?? project.primaryStoryline.revision,
            format: project.format,
            captionConfiguration: project.captionConfiguration,
            captionTimeline: captionTimeline,
            finishingTimeline: finishingTimeline,
            clips: clips,
            duration: ProjectTime(seconds: cursor)
        )
    }

    private func makeSnapshot(project: ProjectManifest) throws -> ExportSnapshot {
        try Self.resolveSnapshot(project: project, projectStore: projectStore)
    }

    private func clipIndex(
        for clipID: TimelineClip.ID,
        in project: ProjectManifest
    ) throws -> Int {
        guard let index = project.primaryStoryline.clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditorError.invalidClip(clipID)
        }
        return index
    }

    private nonisolated static func selectionIsValid(
        _ selection: TakeRange,
        for clip: TimelineClip
    ) -> Bool {
        TimelineTrimRules.isValid(selection, inside: clip.availableRange)
    }

    private nonisolated static func sessionStateIsValid(
        _ state: TimelineSessionState,
        in project: ProjectManifest
    ) -> Bool {
        let allClips = state.clips + state.removedClips.map(\.clip)
        guard Set(allClips.map(\.id)).count == allClips.count,
              state.removedClips.allSatisfy({ $0.placement.originalIndex >= 0 }) else {
            return false
        }
        let takesByID = Dictionary(uniqueKeysWithValues: project.takes.map { ($0.id, $0) })
        return allClips.allSatisfy { clip in
            guard let take = takesByID[clip.takeID] else { return false }
            return clip.availableRange.isValid(inside: take.duration, minimumDuration: 0.001)
                && selectionIsValid(clip.selection, for: clip)
        }
    }
}

private extension TimelineClip {
    func replacingSelection(with selection: TakeRange) -> TimelineClip {
        TimelineClip(
            id: id,
            takeID: takeID,
            availableRange: availableRange,
            selection: selection,
            isMuted: isMuted,
            leadingSplitBoundaryID: leadingSplitBoundaryID,
            trailingSplitBoundaryID: trailingSplitBoundaryID
        )
    }

    func replacingMutedState(with isMuted: Bool) -> TimelineClip {
        TimelineClip(
            id: id,
            takeID: takeID,
            availableRange: availableRange,
            selection: selection,
            isMuted: isMuted,
            leadingSplitBoundaryID: leadingSplitBoundaryID,
            trailingSplitBoundaryID: trailingSplitBoundaryID
        )
    }
}
