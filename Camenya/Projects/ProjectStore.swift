import Foundation

struct ProjectStore: Sendable {
    private static let persistenceLock = NSLock()

    let projectsRoot: URL

    init(projectsRoot: URL? = nil) {
        if let projectsRoot {
            self.projectsRoot = projectsRoot
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.projectsRoot = support.appendingPathComponent("Projects", isDirectory: true)
        }
    }

    func createProject(createdAt: Date = Date()) throws -> ProjectManifest {
        try prepareRoot()
        let project = ProjectManifest(
            createdAt: createdAt,
            modifiedAt: createdAt,
            name: Self.defaultName(for: createdAt)
        )
        try FileManager.default.createDirectory(at: projectDirectory(id: project.id), withIntermediateDirectories: true)
        try saveNew(project)
        return project
    }

    func load(id: UUID) throws -> ProjectManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var project = try decoder.decode(ProjectManifest.self, from: Data(contentsOf: manifestURL(id: id)))
        if project.schemaVersion < ProjectManifest.currentSchemaVersion {
            let expectedRevision = project.primaryStoryline.revision
            project.captionTimelineIssues = CaptionTimelineProjection.reconciledIssues(in: project)
            project.schemaVersion = ProjectManifest.currentSchemaVersion
            try save(project, expectedRevision: expectedRevision)
        }
        return project
    }

    func projects() throws -> [ProjectManifest] {
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { UUID(uuidString: $0.lastPathComponent) }
        .compactMap { try? load(id: $0) }
        .sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.createdAt > $1.createdAt }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    @discardableResult
    func renameProject(id: UUID, name: String, modifiedAt: Date = Date()) throws -> ProjectManifest {
        var project = try load(id: id)
        let expectedRevision = project.primaryStoryline.revision
        project.name = name
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func updateNote(projectID: UUID, text: String, modifiedAt: Date = Date()) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        project.note = text
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func setCaptionConfiguration(
        projectID: UUID,
        configuration: ProjectCaptionConfiguration,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        if project.captionConfiguration?.localeIdentifier != configuration.localeIdentifier {
            for index in project.takes.indices {
                guard var captions = project.takes[index].captions,
                      captions.localeIdentifier != configuration.localeIdentifier else { continue }
                captions.reviewState = .stale
                project.takes[index].captions = captions
            }
        }
        project.captionConfiguration = configuration
        project.captionTimelineIssues = CaptionTimelineProjection.reconciledIssues(in: project)
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func recordCaptionDraft(
        projectID: UUID,
        takeID: UUID,
        draft: TakeCaptionTrack,
        expectedStorylineRevision: StorylineRevision? = nil,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        if let expectedStorylineRevision,
           expectedStorylineRevision != expectedRevision {
            throw ProjectStoreError.staleRevision(
                expected: expectedStorylineRevision,
                actual: expectedRevision
            )
        }
        guard let index = project.takes.firstIndex(where: { $0.id == takeID }) else {
            throw ProjectStoreError.takeNotFound(takeID)
        }
        guard project.captionConfiguration?.localeIdentifier == draft.localeIdentifier else {
            throw ProjectStoreError.captionLocaleMismatch
        }
        guard captionDraftIsValid(
            draft,
            takeDuration: project.takes[index].duration
        ) else {
            throw ProjectStoreError.invalidCaptionRange(takeID)
        }
        var persistedDraft = draft
        persistedDraft.reviewState = .needsReview
        project.takes[index].captions = persistedDraft
        project.captionTimelineIssues = CaptionTimelineProjection.reconciledIssues(in: project)
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func approveCaptions(
        projectID: UUID,
        takeID: UUID,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        guard let index = project.takes.firstIndex(where: { $0.id == takeID }) else {
            throw ProjectStoreError.takeNotFound(takeID)
        }
        guard var captions = project.takes[index].captions else {
            throw ProjectStoreError.captionsNotFound(takeID)
        }
        guard let effectiveRange = project.takes[index].concreteEffectiveRange else {
            throw ProjectStoreError.invalidTakeRange(takeID)
        }
        guard captions.reviewState != .stale,
              captions.localeIdentifier == project.captionConfiguration?.localeIdentifier,
              captions.sourceRange == effectiveRange else {
            throw ProjectStoreError.staleCaptions(takeID)
        }
        captions.reviewState = .approved
        project.takes[index].captions = captions
        project.captionTimelineIssues = CaptionTimelineProjection.reconciledIssues(in: project)
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func addTake(
        projectID: UUID,
        takeID: UUID,
        movieAt sourceURL: URL,
        orientation: TakeOrientation,
        duration: TimeInterval,
        createdAt: Date,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        let format = ProjectFormat(orientation: orientation)
        if let existing = project.format, existing != format {
            throw ProjectStoreError.formatMismatch(expected: existing, received: format)
        }
        if project.takes.contains(where: { $0.id == takeID }) {
            return project
        }

        let directory = takeDirectory(projectID: projectID, takeID: takeID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationURL = takeMovieURL(projectID: projectID, takeID: takeID)
        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw ProjectStoreError.mediaNotFound(sourceURL)
            }
            let stagedURL = directory.appendingPathComponent("take.pending.mov")
            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
            }
        }

        project.format = project.format ?? format
        project.takes.append(ProjectTake(id: takeID, createdAt: createdAt, duration: duration))
        let sourceRange = TakeRange(startSeconds: 0, endSeconds: duration)
        project.primaryStoryline.clips.append(TimelineClip(
            takeID: takeID,
            availableRange: sourceRange,
            selection: sourceRange
        ))
        project.primaryStoryline.revision = try project.primaryStoryline.revision.incremented()
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func moveTake(
        projectID: UUID,
        takeID: UUID,
        toIndex: Int,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        guard let sourceIndex = project.takes.firstIndex(where: { $0.id == takeID }) else {
            throw ProjectStoreError.takeNotFound(takeID)
        }
        guard project.takes.indices.contains(toIndex) else {
            throw ProjectStoreError.invalidTimelineIndex(toIndex)
        }
        let take = project.takes.remove(at: sourceIndex)
        project.takes.insert(take, at: toIndex)
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func moveTake(
        projectID: UUID,
        takeID: UUID,
        before targetID: UUID,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        let project = try load(id: projectID)
        guard let sourceIndex = project.takes.firstIndex(where: { $0.id == takeID }) else {
            throw ProjectStoreError.takeNotFound(takeID)
        }
        guard let targetIndex = project.takes.firstIndex(where: { $0.id == targetID }) else {
            throw ProjectStoreError.takeNotFound(targetID)
        }
        let adjustedIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        return try moveTake(
            projectID: projectID,
            takeID: takeID,
            toIndex: adjustedIndex,
            modifiedAt: modifiedAt
        )
    }

    @discardableResult
    func moveTakes(
        projectID: UUID,
        fromOffsets sourceOffsets: IndexSet,
        toOffset destination: Int,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        guard destination >= 0, destination <= project.takes.count else {
            throw ProjectStoreError.invalidTimelineIndex(destination)
        }
        guard sourceOffsets.allSatisfy(project.takes.indices.contains) else {
            throw ProjectStoreError.invalidTimelineIndex(sourceOffsets.first ?? -1)
        }
        guard !sourceOffsets.isEmpty else { return project }

        let movedTakes = sourceOffsets.map { project.takes[$0] }
        for index in sourceOffsets.reversed() { project.takes.remove(at: index) }
        let removedBeforeDestination = sourceOffsets.filter { $0 < destination }.count
        project.takes.insert(contentsOf: movedTakes, at: destination - removedBeforeDestination)
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func deleteTake(
        projectID: UUID,
        takeID: UUID,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        guard let index = project.takes.firstIndex(where: { $0.id == takeID }) else {
            throw ProjectStoreError.takeNotFound(takeID)
        }
        guard !project.primaryStoryline.clips.contains(where: { $0.takeID == takeID }),
              !project.removedClips.contains(where: { $0.clip.takeID == takeID }) else {
            throw ProjectStoreError.takeReferencedByStoryline(takeID)
        }
        let sourceDirectory = takeDirectory(projectID: projectID, takeID: takeID)
        let stagedDirectory = projectDirectory(id: projectID)
            .appendingPathComponent("Deleting", isDirectory: true)
            .appendingPathComponent(takeID.uuidString, isDirectory: true)
        let hasMedia = FileManager.default.fileExists(atPath: sourceDirectory.path)
        if hasMedia {
            try FileManager.default.createDirectory(at: stagedDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stagedDirectory.path) {
                try FileManager.default.removeItem(at: stagedDirectory)
            }
            try FileManager.default.moveItem(at: sourceDirectory, to: stagedDirectory)
        }

        project.takes.remove(at: index)
        project.captionTimelineIssues.removeAll { $0.takeID == takeID }
        project.modifiedAt = modifiedAt
        do {
            try save(project, expectedRevision: expectedRevision)
        } catch {
            if hasMedia {
                try? FileManager.default.moveItem(at: stagedDirectory, to: sourceDirectory)
            }
            throw error
        }
        if hasMedia { try? FileManager.default.removeItem(at: stagedDirectory) }
        return project
    }

    func deleteProject(id: UUID) throws {
        try prepareRoot()
        let sourceDirectory = projectDirectory(id: id)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
            throw ProjectStoreError.projectNotFound(id)
        }
        try FileManager.default.createDirectory(at: deletingProjectsRoot, withIntermediateDirectories: true)
        let stagedDirectory = deletingProjectsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: stagedDirectory.path) {
            try FileManager.default.removeItem(at: stagedDirectory)
        }
        try FileManager.default.moveItem(at: sourceDirectory, to: stagedDirectory)
        try? FileManager.default.removeItem(at: stagedDirectory)
    }

    func finishPendingDeletions() throws {
        if FileManager.default.fileExists(atPath: deletingProjectsRoot.path) {
            for url in try FileManager.default.contentsOfDirectory(at: deletingProjectsRoot, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: url)
            }
        }
        for project in try projects() {
            let stagedTakes = projectDirectory(id: project.id).appendingPathComponent("Deleting", isDirectory: true)
            guard FileManager.default.fileExists(atPath: stagedTakes.path) else { continue }
            for url in try FileManager.default.contentsOfDirectory(at: stagedTakes, includingPropertiesForKeys: nil) {
                guard let takeID = UUID(uuidString: url.lastPathComponent) else {
                    try FileManager.default.removeItem(at: url)
                    continue
                }
                let isStillReferenced = project.takes.contains { $0.id == takeID }
                let destination = takeDirectory(projectID: project.id, takeID: takeID)
                if isStillReferenced, !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(at: url, to: destination)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
            }
            try FileManager.default.removeItem(at: stagedTakes)
        }
    }

    func migrateLegacyRecordingsIfNeeded() throws {
        let legacyRoot = projectsRoot.deletingLastPathComponent()
            .appendingPathComponent("Recordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyRoot.path) else { return }
        let legacyDirectories = try FileManager.default.contentsOfDirectory(
            at: legacyRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        guard !legacyDirectories.isEmpty else {
            try FileManager.default.removeItem(at: legacyRoot)
            return
        }

        let recovered = try projects().first(where: { $0.name == "Recovered" && $0.takes.isEmpty })
            ?? createRecoveredProject()
        let destinationRoot = projectDirectory(id: recovered.id).appendingPathComponent("Takes", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        for source in legacyDirectories {
            let destination = destinationRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        if (try FileManager.default.contentsOfDirectory(atPath: legacyRoot.path)).isEmpty {
            try FileManager.default.removeItem(at: legacyRoot)
        }
    }

    func projectDirectory(id: UUID) -> URL {
        projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func takeMovieURL(projectID: UUID, takeID: UUID) -> URL {
        takeDirectory(projectID: projectID, takeID: takeID).appendingPathComponent("take.mov")
    }

    func takeThumbnailURL(projectID: UUID, takeID: UUID) -> URL {
        takeDirectory(projectID: projectID, takeID: takeID).appendingPathComponent("thumbnail.jpg")
    }

    func takeTrimEnvelopeURL(projectID: UUID, takeID: UUID) -> URL {
        takeDirectory(projectID: projectID, takeID: takeID).appendingPathComponent("trim-envelope.json")
    }

    func pendingExportURL(projectID: UUID) -> URL {
        projectDirectory(id: projectID)
            .appendingPathComponent("PendingExport", isDirectory: true)
            .appendingPathComponent("project.mov")
    }

    @discardableResult
    func setThumbnail(
        projectID: UUID,
        takeID: UUID,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        guard let index = project.takes.firstIndex(where: { $0.id == takeID }) else {
            throw ProjectStoreError.takeNotFound(takeID)
        }
        project.takes[index].thumbnailFileName = "thumbnail.jpg"
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func setTrimDecision(
        projectID: UUID,
        takeID: UUID,
        decision: TrimReviewDecision,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        guard let index = project.takes.firstIndex(where: { $0.id == takeID }) else {
            throw ProjectStoreError.takeNotFound(takeID)
        }
        if case let .useSelection(range) = decision,
           !range.isValid(inside: project.takes[index].duration, minimumDuration: 1) {
            throw ProjectStoreError.invalidTakeRange(takeID)
        }
        project.takes[index].trimDecision = decision
        let selection: TakeRange
        switch decision {
        case .keepOriginal:
            selection = TakeRange(startSeconds: 0, endSeconds: project.takes[index].duration)
        case let .useSelection(range):
            selection = range
        }
        let matchingClips = project.primaryStoryline.clips.indices.filter {
            project.primaryStoryline.clips[$0].takeID == takeID
        }
        guard matchingClips.count == 1, let clipIndex = matchingClips.first else {
            throw ProjectStoreError.invalidPrimaryStoryline
        }
        let clip = project.primaryStoryline.clips[clipIndex]
        project.primaryStoryline.clips[clipIndex] = TimelineClip(
            id: clip.id,
            takeID: clip.takeID,
            availableRange: clip.availableRange,
            selection: selection,
            isMuted: clip.isMuted
        )
        project.primaryStoryline.revision = try project.primaryStoryline.revision.incremented()
        if var captions = project.takes[index].captions {
            let effectiveRange: TakeRange
            switch decision {
            case .keepOriginal:
                effectiveRange = TakeRange(
                    startSeconds: 0,
                    endSeconds: project.takes[index].duration
                )
            case let .useSelection(range):
                effectiveRange = range
            }
            if captions.sourceRange != effectiveRange {
                captions.reviewState = .stale
                project.takes[index].captions = captions
            }
        }
        project.captionTimelineIssues = CaptionTimelineProjection.reconciledIssues(in: project)
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    @discardableResult
    func recordTrimAnalysis(
        projectID: UUID,
        takeID: UUID,
        result: TrimAnalysisResult,
        envelope: [Float]? = nil,
        expectedStorylineRevision: StorylineRevision? = nil,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        if let expectedStorylineRevision,
           expectedStorylineRevision != expectedRevision {
            throw ProjectStoreError.staleRevision(
                expected: expectedStorylineRevision,
                actual: expectedRevision
            )
        }
        guard let index = project.takes.firstIndex(where: { $0.id == takeID }) else {
            throw ProjectStoreError.takeNotFound(takeID)
        }
        guard project.takes[index].trimDecision == nil else { return project }
        if case let .suggestion(suggestion) = result,
           !suggestion.range.isValid(inside: project.takes[index].duration, minimumDuration: 1) {
            throw ProjectStoreError.invalidTakeRange(takeID)
        }
        var persistedResult = result
        var stagedEnvelopeURL: URL?
        if let envelope {
            let staged = takeTrimEnvelopeURL(projectID: projectID, takeID: takeID)
                .deletingLastPathComponent()
                .appendingPathComponent("trim-envelope-\(UUID().uuidString).pending.json")
            try JSONEncoder().encode(envelope).write(
                to: staged,
                options: .atomic
            )
            stagedEnvelopeURL = staged
            if case let .suggestion(suggestion) = result {
                persistedResult = .suggestion(TrimSuggestion(
                    range: suggestion.range,
                    algorithmVersion: suggestion.algorithmVersion,
                    envelopeFileName: "trim-envelope.json"
                ))
            }
        }
        project.takes[index].trimAnalysis = persistedResult
        project.modifiedAt = modifiedAt
        do {
            try save(project, expectedRevision: expectedRevision)
        } catch {
            if let stagedEnvelopeURL {
                try? FileManager.default.removeItem(at: stagedEnvelopeURL)
            }
            throw error
        }
        if let stagedEnvelopeURL {
            let destination = takeTrimEnvelopeURL(projectID: projectID, takeID: takeID)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: stagedEnvelopeURL)
            } else {
                try FileManager.default.moveItem(at: stagedEnvelopeURL, to: destination)
            }
        }
        let keepsEnvelope: Bool
        switch persistedResult {
        case .suggestion, .noSuggestion: keepsEnvelope = envelope != nil
        case .failed: keepsEnvelope = false
        }
        if !keepsEnvelope {
            try? FileManager.default.removeItem(at: takeTrimEnvelopeURL(projectID: projectID, takeID: takeID))
        }
        return project
    }

    func trimEnvelope(projectID: UUID, takeID: UUID) throws -> [Float] {
        try JSONDecoder().decode(
            [Float].self,
            from: Data(contentsOf: takeTrimEnvelopeURL(projectID: projectID, takeID: takeID))
        )
    }

    @discardableResult
    func resetTrim(
        projectID: UUID,
        takeID: UUID,
        modifiedAt: Date = Date()
    ) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        guard let index = project.takes.firstIndex(where: { $0.id == takeID }) else {
            throw ProjectStoreError.takeNotFound(takeID)
        }
        project.takes[index].trimAnalysis = nil
        project.takes[index].trimDecision = nil
        let matchingClips = project.primaryStoryline.clips.indices.filter {
            project.primaryStoryline.clips[$0].takeID == takeID
        }
        guard matchingClips.count == 1, let clipIndex = matchingClips.first else {
            throw ProjectStoreError.invalidPrimaryStoryline
        }
        let clip = project.primaryStoryline.clips[clipIndex]
        project.primaryStoryline.clips[clipIndex] = TimelineClip(
            id: clip.id,
            takeID: clip.takeID,
            availableRange: clip.availableRange,
            selection: TakeRange(startSeconds: 0, endSeconds: project.takes[index].duration),
            isMuted: clip.isMuted
        )
        project.primaryStoryline.revision = try project.primaryStoryline.revision.incremented()
        if var captions = project.takes[index].captions {
            let originalRange = TakeRange(
                startSeconds: 0,
                endSeconds: project.takes[index].duration
            )
            if captions.sourceRange != originalRange {
                captions.reviewState = .stale
                project.takes[index].captions = captions
            }
        }
        project.captionTimelineIssues = CaptionTimelineProjection.reconciledIssues(in: project)
        project.modifiedAt = modifiedAt
        try save(project, expectedRevision: expectedRevision)
        try? FileManager.default.removeItem(at: takeTrimEnvelopeURL(projectID: projectID, takeID: takeID))
        return project
    }

    func removePendingExport(projectID: UUID) throws {
        let directory = pendingExportURL(projectID: projectID).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func recordPhotosSaveCompleted(projectID: UUID) throws {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        project.recoveryState = .photosSaveCompleted
        try save(project, expectedRevision: expectedRevision)
    }

    @discardableResult
    func setPendingExportState(projectID: UUID, pending: Bool) throws -> ProjectManifest {
        var project = try load(id: projectID)
        let expectedRevision = project.primaryStoryline.revision
        project.recoveryState = pending ? .pendingExport : .clean
        try save(project, expectedRevision: expectedRevision)
        return project
    }

    func pendingExportNeedsPhotoSave(projectID: UUID) -> Bool {
        let export = pendingExportURL(projectID: projectID)
        let marker = export.deletingLastPathComponent().appendingPathComponent("saved-to-photos")
        return FileManager.default.fileExists(atPath: export.path)
            && (try? load(id: projectID).recoveryState) != .photosSaveCompleted
            && !FileManager.default.fileExists(atPath: marker.path)
    }

    func finishCompletedExports() {
        guard let projects = try? projects() else { return }
        for project in projects {
            let export = pendingExportURL(projectID: project.id)
            let directory = export.deletingLastPathComponent()
            let marker = directory.appendingPathComponent("saved-to-photos")
            if project.recoveryState == .photosSaveCompleted || FileManager.default.fileExists(atPath: marker.path) {
                try? FileManager.default.removeItem(at: directory)
                _ = try? setPendingExportState(projectID: project.id, pending: false)
            }
        }
    }

    func storageBytes(projectID: UUID) -> Int64 {
        storageBytes(in: projectDirectory(id: projectID))
    }

    func storageBytes(projectID: UUID, takeID: UUID) -> Int64 {
        storageBytes(in: takeDirectory(projectID: projectID, takeID: takeID))
    }

    private func storageBytes(in directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    func takeManifestStore(projectID: UUID) -> TakeManifestStore {
        TakeManifestStore(recordingsRoot: projectDirectory(id: projectID).appendingPathComponent("Takes", isDirectory: true))
    }

    func unfinishedTakes(projectID: UUID) -> [TakeManifest] {
        takeManifestStore(projectID: projectID).unfinishedTakes()
    }

    func cleanCompletedTakeArtifacts(projectID: UUID, takeID: UUID) throws {
        let directory = takeDirectory(projectID: projectID, takeID: takeID)
        let preservedNames = Set(["take.mov", "thumbnail.jpg", "trim-envelope.json"])
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if !preservedNames.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func persist(
        _ project: ProjectManifest,
        expectedRevision: StorylineRevision
    ) throws {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        let current = try decodeManifest(id: project.id)
        guard current.manifestRevision == project.manifestRevision else {
            throw ProjectStoreError.staleManifest(
                expected: project.manifestRevision,
                actual: current.manifestRevision
            )
        }
        guard current.primaryStoryline.revision == expectedRevision else {
            throw ProjectStoreError.staleRevision(
                expected: expectedRevision,
                actual: current.primaryStoryline.revision
            )
        }
        guard current.manifestRevision < UInt64.max else {
            throw ProjectStoreError.manifestRevisionExhausted
        }
        var committed = project
        committed.manifestRevision = current.manifestRevision + 1
        try write(committed)
    }

    private func saveNew(_ project: ProjectManifest) throws {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        guard !FileManager.default.fileExists(atPath: manifestURL(id: project.id).path) else {
            throw ProjectStoreError.projectAlreadyExists(project.id)
        }
        try write(project)
    }

    private func save(
        _ project: ProjectManifest,
        expectedRevision: StorylineRevision
    ) throws {
        try persist(project, expectedRevision: expectedRevision)
    }

    private func decodeManifest(id: UUID) throws -> ProjectManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            ProjectManifest.self,
            from: Data(contentsOf: manifestURL(id: id))
        )
    }

    private func write(_ project: ProjectManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: manifestURL(id: project.id), options: .atomic)
    }

    private func manifestURL(id: UUID) -> URL {
        projectDirectory(id: id).appendingPathComponent("project.json")
    }

    private func takeDirectory(projectID: UUID, takeID: UUID) -> URL {
        projectDirectory(id: projectID)
            .appendingPathComponent("Takes", isDirectory: true)
            .appendingPathComponent(takeID.uuidString, isDirectory: true)
    }

    private var deletingProjectsRoot: URL {
        projectsRoot.appendingPathComponent(".Deleting", isDirectory: true)
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = projectsRoot
        try root.setResourceValues(values)
    }

    private func createRecoveredProject() throws -> ProjectManifest {
        let now = Date()
        let project = ProjectManifest(createdAt: now, modifiedAt: now, name: "Recovered")
        try prepareRoot()
        try FileManager.default.createDirectory(at: projectDirectory(id: project.id), withIntermediateDirectories: true)
        try saveNew(project)
        return project
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func captionDraftIsValid(
        _ draft: TakeCaptionTrack,
        takeDuration: TimeInterval
    ) -> Bool {
        guard draft.sourceRange.isValid(inside: takeDuration, minimumDuration: 0.001) else {
            return false
        }
        var previousEnd = draft.sourceRange.start.seconds
        for cue in draft.cues {
            guard cue.range.duration > 0,
                  cue.range.start.seconds >= previousEnd,
                  cue.range.start.seconds >= draft.sourceRange.start.seconds,
                  cue.range.end.seconds <= draft.sourceRange.end.seconds,
                  cue.recognizedRange.duration > 0,
                  cue.recognizedRange.start.seconds >= draft.sourceRange.start.seconds,
                  cue.recognizedRange.end.seconds <= draft.sourceRange.end.seconds,
                  cue.timedSpans.allSatisfy({ span in
                      span.range.duration > 0
                          && span.range.start.seconds >= cue.recognizedRange.start.seconds
                          && span.range.end.seconds <= cue.recognizedRange.end.seconds
                  }) else {
                return false
            }
            previousEnd = cue.range.end.seconds
        }
        return true
    }
}

enum ProjectStoreError: Error, Equatable {
    case projectNotFound(UUID)
    case formatMismatch(expected: ProjectFormat, received: ProjectFormat)
    case takeNotFound(UUID)
    case invalidTimelineIndex(Int)
    case invalidTakeRange(UUID)
    case invalidCaptionRange(UUID)
    case captionLocaleMismatch
    case captionsNotFound(UUID)
    case staleCaptions(UUID)
    case mediaNotFound(URL)
    case invalidPrimaryStoryline
    case takeReferencedByStoryline(UUID)
    case staleRevision(expected: StorylineRevision, actual: StorylineRevision)
    case projectAlreadyExists(UUID)
    case staleManifest(expected: UInt64, actual: UInt64)
    case manifestRevisionExhausted
}
