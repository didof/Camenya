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
                sourceRange: sourceRange,
                availableRange: clip.availableRange,
                selection: clip.selection,
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
}
