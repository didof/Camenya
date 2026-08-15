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
    case nudgeTrim(
        clipID: TimelineClip.ID,
        edge: TimelineTrimEdge,
        direction: TimelineNudgeDirection
    )
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
        guard project.primaryStoryline.revision == expectedRevision else {
            throw TimelineEditorError.staleRevision(
                expected: expectedRevision,
                actual: project.primaryStoryline.revision
            )
        }

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
        return TimelineEditOutcome(
            project: committed,
            snapshot: try makeSnapshot(project: committed)
        )
    }

    private nonisolated static func resolveSnapshot(
        project: ProjectManifest,
        projectStore: ProjectStore
    ) throws -> ExportSnapshot {
        var cursor: TimeInterval = 0
        let clips = try project.primaryStoryline.clips.map { clip in
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
            let approvedCaptions: TakeCaptionTrack?
            if let captions = take.captions,
               captions.reviewState == .approved,
               captions.localeIdentifier == project.captionConfiguration?.localeIdentifier,
               captions.sourceRange == clip.selection {
                approvedCaptions = captions
            } else {
                approvedCaptions = nil
            }
            return ExportSnapshot.Clip(
                id: clip.id,
                takeID: take.id,
                mediaURL: projectStore.takeMovieURL(projectID: project.id, takeID: take.id),
                thumbnailURL: projectStore.takeThumbnailURL(projectID: project.id, takeID: take.id),
                sourceCreatedAt: take.createdAt,
                sourceRange: sourceRange,
                availableRange: clip.availableRange,
                selection: clip.selection,
                trimSuggestion: trimSuggestion,
                projectTimeRange: ProjectTimeRange(
                    start: ProjectTime(seconds: start),
                    end: ProjectTime(seconds: cursor)
                ),
                approvedCaptions: approvedCaptions
            )
        }
        return ExportSnapshot(
            projectID: project.id,
            revision: project.primaryStoryline.revision,
            format: project.format,
            captionConfiguration: project.captionConfiguration,
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
}

private extension TimelineClip {
    func replacingSelection(with selection: TakeRange) -> TimelineClip {
        TimelineClip(
            id: id,
            takeID: takeID,
            availableRange: availableRange,
            selection: selection
        )
    }
}
