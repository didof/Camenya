import XCTest
@testable import Camenya

final class ProjectStoreTests: XCTestCase {
    func testUnmarkedWorkingExportIsNeverRecoverableAcrossStoreRelaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let staged = store.pendingExportWorkingURL(projectID: project.id)
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("partial export".utf8).write(to: staged)

        let relaunchedStore = ProjectStore(projectsRoot: root)

        XCTAssertNil(relaunchedStore.recoverableStagedExport(projectID: project.id))
        XCTAssertFalse(relaunchedStore.pendingExportNeedsHandoff(projectID: project.id))
    }

    func testLegacyPhotosSaveRecoveryStateDecodesAsGenericExportHandoff() throws {
        let state = try JSONDecoder().decode(
            ProjectRecoveryState.self,
            from: Data("\"photosSaveCompleted\"".utf8)
        )

        XCTAssertEqual(state, .exportHandoffCompleted)
    }

    func testFailedPendingExportCommitRestoresThePreviousFinishedMovie() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let pending = store.pendingExportURL(projectID: project.id)
        try FileManager.default.createDirectory(
            at: pending.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("previous export".utf8).write(to: pending)
        let missingStagedFile = store.pendingExportWorkingURL(projectID: project.id)

        XCTAssertThrowsError(try store.commitPendingExport(
            projectID: project.id,
            stagedURL: missingStagedFile
        ))

        XCTAssertEqual(try Data(contentsOf: pending), Data("previous export".utf8))
    }

    func testPendingExportIsReusableOnlyForTheExactVariantAndManifestRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let pending = store.pendingExportURL(projectID: project.id)
        try FileManager.default.createDirectory(
            at: pending.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("finished".utf8).write(to: pending)
        _ = try store.setPendingExportState(projectID: project.id, pending: true)
        try store.recordPendingExportDescriptor(projectID: project.id, includeCaptions: true)

        XCTAssertTrue(store.pendingExportMatches(projectID: project.id, includeCaptions: true))
        XCTAssertFalse(store.pendingExportMatches(projectID: project.id, includeCaptions: false))

        _ = try store.renameProject(id: project.id, name: "Changed after export")

        XCTAssertFalse(store.pendingExportMatches(projectID: project.id, includeCaptions: true))
    }

    func testInvalidExportRecoveryMetadataStopsRetryWithoutDeletingTheMovie() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let pending = store.pendingExportURL(projectID: project.id)
        try FileManager.default.createDirectory(
            at: pending.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("finished".utf8).write(to: pending)
        _ = try store.setPendingExportState(projectID: project.id, pending: true)
        try store.recordPendingExportDescriptor(projectID: project.id, includeCaptions: false)

        XCTAssertTrue(store.pendingExportMatches(projectID: project.id, includeCaptions: false))

        store.invalidateExportRecoveryMetadata(projectID: project.id)

        XCTAssertFalse(store.pendingExportMatches(projectID: project.id, includeCaptions: false))
        XCTAssertFalse(store.pendingExportNeedsHandoff(projectID: project.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }

    func testSchemaSevenProjectDoesNotInventLineageForComplementaryClipsFromDifferentSplits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let projectID = UUID()
        let take = ProjectTake(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            duration: 12
        )
        let firstGenerationRightID = TimelineClip.ID()
        let secondGenerationLeftID = TimelineClip.ID()
        let firstGenerationLeft = TimelineClip(
            takeID: take.id,
            availableRange: TakeRange(startSeconds: 0, endSeconds: 6),
            selection: TakeRange(startSeconds: 0, endSeconds: 6)
        )
        let secondGenerationRight = TimelineClip(
            takeID: take.id,
            availableRange: TakeRange(startSeconds: 6, endSeconds: 12),
            selection: TakeRange(startSeconds: 6, endSeconds: 12)
        )
        let legacy = ProjectManifest(
            schemaVersion: 7,
            id: projectID,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 1),
            name: "Two Legacy Splits",
            takes: [take],
            primaryStoryline: PrimaryStoryline(clips: []),
            removedClips: [
                RemovedTimelineClip(
                    clip: firstGenerationLeft,
                    placement: TimelinePlacementContext(
                        previousClipID: nil,
                        nextClipID: firstGenerationRightID,
                        originalIndex: 0
                    )
                ),
                RemovedTimelineClip(
                    clip: secondGenerationRight,
                    placement: TimelinePlacementContext(
                        previousClipID: secondGenerationLeftID,
                        nextClipID: nil,
                        originalIndex: 1
                    )
                )
            ]
        )
        try writeLegacyProject(legacy, to: store)

        let migrated = try store.load(id: projectID)
        let migratedClips = migrated.removedClips.map(\.clip)

        XCTAssertTrue(migratedClips.allSatisfy { $0.leadingSplitBoundaryID == nil })
        XCTAssertTrue(migratedClips.allSatisfy { $0.trailingSplitBoundaryID == nil })
        XCTAssertEqual(migrated.primaryStoryline.revision, .zero)
    }

    func testSchemaSevenProjectDoesNotGuessSplitLineageWhenLegacyRangesOverlap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let projectID = UUID()
        let take = ProjectTake(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            duration: 12
        )
        let fullReplacement = TimelineClip(
            takeID: take.id,
            availableRange: TakeRange(startSeconds: 0, endSeconds: 12),
            selection: TakeRange(startSeconds: 0, endSeconds: 12)
        )
        let oldFirst = TimelineClip(
            takeID: take.id,
            availableRange: TakeRange(startSeconds: 0, endSeconds: 6),
            selection: TakeRange(startSeconds: 0, endSeconds: 6)
        )
        let oldLast = TimelineClip(
            takeID: take.id,
            availableRange: TakeRange(startSeconds: 6, endSeconds: 12),
            selection: TakeRange(startSeconds: 6, endSeconds: 12)
        )
        let legacy = ProjectManifest(
            schemaVersion: 7,
            id: projectID,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 1),
            name: "Ambiguous Legacy Split",
            takes: [take],
            primaryStoryline: PrimaryStoryline(clips: [fullReplacement]),
            removedClips: [oldFirst, oldLast].enumerated().map { index, clip in
                RemovedTimelineClip(
                    clip: clip,
                    placement: TimelinePlacementContext(
                        previousClipID: nil,
                        nextClipID: nil,
                        originalIndex: index
                    )
                )
            }
        )
        try writeLegacyProject(legacy, to: store)

        let migrated = try store.load(id: projectID)
        let allClips = migrated.primaryStoryline.clips + migrated.removedClips.map(\.clip)

        XCTAssertTrue(allClips.allSatisfy { $0.leadingSplitBoundaryID == nil })
        XCTAssertTrue(allClips.allSatisfy { $0.trailingSplitBoundaryID == nil })
    }

    func testApprovedTakeSelectionPersistsAndDrivesEffectiveDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        _ = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 10,
            createdAt: Date()
        )

        let updated = try store.setTrimDecision(
            projectID: project.id,
            takeID: takeID,
            decision: .useSelection(TakeRange(startSeconds: 2, endSeconds: 8))
        )

        XCTAssertEqual(updated.takes.first?.duration, 10)
        XCTAssertEqual(updated.takes.first?.effectiveDuration, 6)
        XCTAssertEqual(updated.approximateDuration, 6)
        XCTAssertEqual(try store.load(id: project.id).takes.first?.trimDecision, updated.takes.first?.trimDecision)
    }

    private func writeLegacyProject(
        _ project: ProjectManifest,
        to store: ProjectStore
    ) throws {
        let directory = store.projectDirectory(id: project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: directory.appendingPathComponent("project.json"))
    }

    func testSchemaOneProjectMigratesWithoutChangingItsOriginalRange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let projectID = UUID()
        let legacy = ProjectManifest(
            schemaVersion: 1,
            id: projectID,
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: Date(timeIntervalSince1970: 100),
            name: "Legacy",
            format: .portrait,
            takes: [ProjectTake(createdAt: Date(timeIntervalSince1970: 101), duration: 12)]
        )
        let directory = store.projectDirectory(id: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: directory.appendingPathComponent("project.json"))

        let migrated = try store.load(id: projectID)

        XCTAssertEqual(migrated.schemaVersion, ProjectManifest.currentSchemaVersion)
        XCTAssertEqual(migrated.takes.first?.duration, 12)
        XCTAssertEqual(migrated.primaryStoryline.clips.map(\.takeID), migrated.takes.map(\.id))
        XCTAssertNil(migrated.takes.first?.trimDecision)
        XCTAssertNil(migrated.captionConfiguration)
    }

    func testSchemaFourProjectMigratesRemovedClipBaselineWithoutChangingStoryline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let projectID = UUID()
        let take = ProjectTake(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            duration: 5
        )
        let clip = TimelineClip(
            takeID: take.id,
            availableRange: TakeRange(startSeconds: 0, endSeconds: 5),
            selection: TakeRange(startSeconds: 1, endSeconds: 4)
        )
        let legacy = ProjectManifest(
            schemaVersion: 4,
            id: projectID,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 1),
            name: "Schema Four",
            format: .portrait,
            takes: [take],
            primaryStoryline: PrimaryStoryline(
                revision: StorylineRevision(rawValue: 3),
                clips: [clip]
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any]
        )
        object.removeValue(forKey: "removedClips")
        var storyline = try XCTUnwrap(object["primaryStoryline"] as? [String: Any])
        var clips = try XCTUnwrap(storyline["clips"] as? [[String: Any]])
        clips[0].removeValue(forKey: "isMuted")
        storyline["clips"] = clips
        object["primaryStoryline"] = storyline
        let directory = store.projectDirectory(id: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(
            to: directory.appendingPathComponent("project.json")
        )

        let migrated = try store.load(id: projectID)

        XCTAssertEqual(migrated.schemaVersion, ProjectManifest.currentSchemaVersion)
        XCTAssertEqual(migrated.primaryStoryline.revision, StorylineRevision(rawValue: 3))
        XCTAssertEqual(migrated.primaryStoryline.clips.map(\.id), [clip.id])
        XCTAssertEqual(migrated.primaryStoryline.clips.map(\.selection), [clip.selection])
        XCTAssertEqual(migrated.primaryStoryline.clips.map(\.isMuted), [false])
        XCTAssertTrue(migrated.removedClips.isEmpty)
    }

    func testSchemaNineMigrationRemovesDerivedTakeCaptionsButKeepsPreferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let projectID = UUID()
        let take = ProjectTake(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 3
        )
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .upper,
            style: .highContrast,
            density: .more
        )
        var expectedConfiguration = configuration
        expectedConfiguration.style = .clean
        let legacy = ProjectManifest(
            schemaVersion: 9,
            id: projectID,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 1),
            name: "Legacy Captions",
            format: .portrait,
            takes: [take],
            captionConfiguration: configuration
        )
        let directory = store.projectDirectory(id: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any]
        )
        var legacyTakes = try XCTUnwrap(json["takes"] as? [[String: Any]])
        legacyTakes[0]["captions"] = ["legacyDerivedTrack": true]
        json["takes"] = legacyTakes
        json["captionTimelineIssues"] = [["legacyBoundaryRepair": true]]
        let manifestURL = directory.appendingPathComponent("project.json")
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)

        let migrated = try store.load(id: projectID)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        let persistedTakes = try XCTUnwrap(persisted["takes"] as? [[String: Any]])

        XCTAssertEqual(migrated.schemaVersion, ProjectManifest.currentSchemaVersion)
        XCTAssertEqual(migrated.captionConfiguration, expectedConfiguration)
        XCTAssertNil(persisted["captionTimelineIssues"])
        XCTAssertNil(persistedTakes.first?["captions"])
    }

    func testUnreviewedTrimSuggestionPersistsWithoutChangingEffectiveDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        _ = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 10,
            createdAt: Date()
        )
        let suggestion = TrimSuggestion(
            range: TakeRange(startSeconds: 2, endSeconds: 8),
            algorithmVersion: 1,
            envelopeFileName: "trim-envelope.json"
        )

        let updated = try store.recordTrimAnalysis(
            projectID: project.id,
            takeID: takeID,
            result: .suggestion(suggestion)
        )

        XCTAssertEqual(updated.takes.first?.trimAnalysis, .suggestion(suggestion))
        XCTAssertNil(updated.takes.first?.trimDecision)
        XCTAssertEqual(updated.approximateDuration, 10)
        XCTAssertEqual(try store.load(id: project.id).takes.first?.trimAnalysis, .suggestion(suggestion))
    }

    func testStaleTrimAnalysisCannotWriteMetadataOrEnvelopeAfterStorylineChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        let withTake = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 10,
            createdAt: Date()
        )
        _ = try store.setTrimDecision(
            projectID: project.id,
            takeID: takeID,
            decision: .keepOriginal
        )

        XCTAssertThrowsError(try store.recordTrimAnalysis(
            projectID: project.id,
            takeID: takeID,
            result: .noSuggestion(.negligibleSaving),
            envelope: [0.1, 0.2],
            expectedStorylineRevision: withTake.primaryStoryline.revision
        )) { error in
            XCTAssertEqual(
                error as? ProjectStoreError,
                .staleRevision(
                    expected: withTake.primaryStoryline.revision,
                    actual: StorylineRevision(rawValue: 2)
                )
            )
        }
        let reloaded = try store.load(id: project.id)
        XCTAssertNil(reloaded.takes.first?.trimAnalysis)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.takeTrimEnvelopeURL(projectID: project.id, takeID: takeID).path
        ))
    }

    func testTrimEnvelopePersistsAndResetRestoresOriginalState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        _ = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 10,
            createdAt: Date()
        )

        let analyzed = try store.recordTrimAnalysis(
            projectID: project.id,
            takeID: takeID,
            result: .suggestion(TrimSuggestion(
                range: TakeRange(startSeconds: 2, endSeconds: 8),
                algorithmVersion: 1,
                envelopeFileName: nil
            )),
            envelope: [0, 0.5, 1]
        )
        _ = try store.setTrimDecision(projectID: project.id, takeID: takeID, decision: .useSelection(TakeRange(startSeconds: 2, endSeconds: 8)))

        XCTAssertEqual(try store.trimEnvelope(projectID: project.id, takeID: takeID), [0, 0.5, 1])
        guard case let .suggestion(suggestion) = analyzed.takes.first?.trimAnalysis else {
            return XCTFail("Expected a persisted suggestion")
        }
        XCTAssertEqual(suggestion.envelopeFileName, "trim-envelope.json")

        let reset = try store.resetTrim(projectID: project.id, takeID: takeID)
        XCTAssertNil(reset.takes.first?.trimAnalysis)
        XCTAssertNil(reset.takes.first?.trimDecision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.takeTrimEnvelopeURL(projectID: project.id, takeID: takeID).path))
    }

    func testNoSuggestionStillPersistsItsWaveform() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        _ = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 10,
            createdAt: Date()
        )

        let analyzed = try store.recordTrimAnalysis(
            projectID: project.id,
            takeID: takeID,
            result: .noSuggestion(.negligibleSaving),
            envelope: [0.1, 0.8, 0.2]
        )

        XCTAssertEqual(analyzed.takes.first?.trimAnalysis, .noSuggestion(.negligibleSaving))
        XCTAssertEqual(try store.trimEnvelope(projectID: project.id, takeID: takeID), [0.1, 0.8, 0.2])
    }

    func testReanalysisCannotOverwriteAReviewedTake() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        _ = try store.addTake(projectID: project.id, takeID: takeID, movieAt: makeMovie(), orientation: .portrait, duration: 10, createdAt: Date())
        let originalResult = TrimAnalysisResult.suggestion(TrimSuggestion(
            range: TakeRange(startSeconds: 2, endSeconds: 8),
            algorithmVersion: 1,
            envelopeFileName: nil
        ))
        _ = try store.recordTrimAnalysis(projectID: project.id, takeID: takeID, result: originalResult, envelope: [0, 1])
        _ = try store.setTrimDecision(projectID: project.id, takeID: takeID, decision: .keepOriginal)

        let unchanged = try store.recordTrimAnalysis(projectID: project.id, takeID: takeID, result: .failed(.decodingFailed))

        XCTAssertEqual(unchanged.takes.first?.trimDecision, .keepOriginal)
        guard case .suggestion = unchanged.takes.first?.trimAnalysis else {
            return XCTFail("Reviewed analysis should remain unchanged")
        }
    }

    func testCreatedProjectCanBeReloadedFromTheLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let createdAt = Date(timeIntervalSince1970: 1_755_000_000)

        let created = try store.createProject(createdAt: createdAt)
        let reloaded = try store.load(id: created.id)

        XCTAssertEqual(reloaded, created)
        XCTAssertEqual(reloaded.createdAt, createdAt)
        XCTAssertFalse(reloaded.name.isEmpty)
        XCTAssertNil(reloaded.format)
        XCTAssertTrue(reloaded.takes.isEmpty)
    }

    func testProjectsRootIsExcludedFromBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)

        _ = try store.createProject()

        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testMalformedProjectDirectoryDoesNotHideValidProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(UUID().uuidString, isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(try store.projects().map(\.id), [project.id])
    }

    func testRenamedProjectMovesToTheTopOfTheLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let first = try store.createProject(createdAt: Date(timeIntervalSince1970: 100))
        let second = try store.createProject(createdAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(try store.projects().map(\.id), [second.id, first.id])

        let renamed = try store.renameProject(id: first.id, name: "Launch", modifiedAt: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(renamed.name, "Launch")
        XCTAssertEqual(try store.projects().map(\.id), [first.id, second.id])
        XCTAssertEqual(try store.load(id: first.id).name, "Launch")
    }

    func testCompletedTakeIsOwnedByItsProjectAndEstablishesFormat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        try Data("movie".utf8).write(to: source)
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 100))
        let takeID = UUID()

        let updated = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: source,
            orientation: .portrait,
            duration: 12,
            createdAt: Date(timeIntervalSince1970: 110),
            modifiedAt: Date(timeIntervalSince1970: 120)
        )

        XCTAssertEqual(updated.format, .portrait)
        XCTAssertEqual(updated.takes.map(\.id), [takeID])
        XCTAssertEqual(updated.approximateDuration, 12, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: store.takeMovieURL(projectID: project.id, takeID: takeID)), Data("movie".utf8))
    }

    func testAddingTheSameDurableTakeTwiceIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        let first = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 1,
            createdAt: Date()
        )
        let durableMovie = store.takeMovieURL(projectID: project.id, takeID: takeID)

        let retried = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: durableMovie,
            orientation: .portrait,
            duration: 1,
            createdAt: Date()
        )

        XCTAssertEqual(first.takes.count, 1)
        XCTAssertEqual(retried.takes.map(\.id), [takeID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableMovie.path))
    }

    func testAddingATakeReplacesAnUnreferencedPartialDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        let destination = store.takeMovieURL(projectID: project.id, takeID: takeID)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: destination)
        let source = try makeMovie()
        let expected = try Data(contentsOf: source)

        let updated = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: source,
            orientation: .portrait,
            duration: 1,
            createdAt: Date()
        )

        XCTAssertEqual(updated.takes.map(\.id), [takeID])
        XCTAssertEqual(try Data(contentsOf: destination), expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testTimelineCanBeReorderedAndPersistsItsVisibleOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 100))
        let firstID = UUID()
        let secondID = UUID()
        _ = try store.addTake(projectID: project.id, takeID: firstID, movieAt: makeMovie(), orientation: .portrait, duration: 1, createdAt: Date(timeIntervalSince1970: 101))
        _ = try store.addTake(projectID: project.id, takeID: secondID, movieAt: makeMovie(), orientation: .portrait, duration: 2, createdAt: Date(timeIntervalSince1970: 102))

        let reordered = try store.moveTake(projectID: project.id, takeID: firstID, toIndex: 1, modifiedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(reordered.takes.map(\.id), [secondID, firstID])
        XCTAssertEqual(try store.load(id: project.id).takes.map(\.id), [secondID, firstID])
    }

    func testMovingATakeBeforeALaterTakePlacesItImmediatelyBeforeTheTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        _ = try store.addTake(projectID: project.id, takeID: firstID, movieAt: makeMovie(), orientation: .portrait, duration: 1, createdAt: Date())
        _ = try store.addTake(projectID: project.id, takeID: secondID, movieAt: makeMovie(), orientation: .portrait, duration: 1, createdAt: Date())
        _ = try store.addTake(projectID: project.id, takeID: thirdID, movieAt: makeMovie(), orientation: .portrait, duration: 1, createdAt: Date())

        let reordered = try store.moveTake(projectID: project.id, takeID: firstID, before: thirdID)

        XCTAssertEqual(reordered.takes.map(\.id), [secondID, firstID, thirdID])
    }

    func testNativeListMovePersistsTheDestinationOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        _ = try store.addTake(projectID: project.id, takeID: firstID, movieAt: makeMovie(), orientation: .portrait, duration: 1, createdAt: Date())
        _ = try store.addTake(projectID: project.id, takeID: secondID, movieAt: makeMovie(), orientation: .portrait, duration: 2, createdAt: Date())
        _ = try store.addTake(projectID: project.id, takeID: thirdID, movieAt: makeMovie(), orientation: .portrait, duration: 3, createdAt: Date())

        let reordered = try store.moveTakes(
            projectID: project.id,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3
        )

        XCTAssertEqual(reordered.takes.map(\.id), [secondID, thirdID, firstID])
        XCTAssertEqual(try store.load(id: project.id).takes.map(\.id), [secondID, thirdID, firstID])
    }

    func testNativeListMovePreservesTheOrderOfMultipleSelectedTakes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let ids = [UUID(), UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            _ = try store.addTake(
                projectID: project.id,
                takeID: id,
                movieAt: makeMovie(),
                orientation: .portrait,
                duration: TimeInterval(index + 1),
                createdAt: Date()
            )
        }

        let reordered = try store.moveTakes(
            projectID: project.id,
            fromOffsets: IndexSet([1, 2]),
            toOffset: 4
        )

        XCTAssertEqual(reordered.takes.map(\.id), [ids[0], ids[3], ids[1], ids[2]])
    }

    func testDeletingAReferencedTakeIsRejectedAndPreservesAllMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 100))
        let deletedID = UUID()
        let keptID = UUID()
        _ = try store.addTake(projectID: project.id, takeID: deletedID, movieAt: makeMovie(), orientation: .portrait, duration: 1, createdAt: Date(timeIntervalSince1970: 101))
        _ = try store.addTake(projectID: project.id, takeID: keptID, movieAt: makeMovie(), orientation: .portrait, duration: 2, createdAt: Date(timeIntervalSince1970: 102))

        XCTAssertThrowsError(
            try store.deleteTake(
                projectID: project.id,
                takeID: deletedID,
                modifiedAt: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            XCTAssertEqual(error as? ProjectStoreError, .takeReferencedByStoryline(deletedID))
        }

        XCTAssertEqual(try store.load(id: project.id).takes.map(\.id), [deletedID, keptID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.takeMovieURL(projectID: project.id, takeID: deletedID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.takeMovieURL(projectID: project.id, takeID: keptID).path))
    }

    func testDeletingAProjectCascadesThroughAllOwnedMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 100))
        _ = try store.addTake(projectID: project.id, takeID: UUID(), movieAt: makeMovie(), orientation: .portrait, duration: 1, createdAt: Date(timeIntervalSince1970: 101))

        try store.deleteProject(id: project.id)

        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.projectDirectory(id: project.id).path))
    }

    func testLaunchCleanupPurgesStagedTakeMediaInsideProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let staged = store.projectDirectory(id: project.id)
            .appendingPathComponent("Deleting", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: staged.appendingPathComponent("take.mov"))

        try store.finishPendingDeletions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testLaunchCleanupRestoresStagedMediaStillReferencedByManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        _ = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 1,
            createdAt: Date()
        )
        let movie = store.takeMovieURL(projectID: project.id, takeID: takeID)
        let takeDirectory = movie.deletingLastPathComponent()
        let staged = store.projectDirectory(id: project.id)
            .appendingPathComponent("Deleting", isDirectory: true)
            .appendingPathComponent(takeID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: takeDirectory, to: staged)

        try store.finishPendingDeletions()

        XCTAssertEqual(try store.load(id: project.id).takes.map(\.id), [takeID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testProjectNotePersistsWithTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 100))

        _ = try store.updateNote(projectID: project.id, text: "Next line", modifiedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(try store.load(id: project.id).note, "Next line")
    }

    func testRenameNormalizesWhitespaceAtThePersistenceBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: .distantPast)

        let renamed = try store.renameProject(id: project.id, name: "  Talking Head  \n")

        XCTAssertEqual(renamed.name, "Talking Head")
        XCTAssertEqual(try store.load(id: project.id).name, "Talking Head")
    }

    func testThumbnailAndPendingExportStayInsideTheirOwningProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 100))
        let takeID = UUID()
        _ = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 1,
            createdAt: Date(timeIntervalSince1970: 101)
        )

        let thumbnailURL = store.takeThumbnailURL(projectID: project.id, takeID: takeID)
        try Data("thumbnail".utf8).write(to: thumbnailURL)
        let updated = try store.setThumbnail(projectID: project.id, takeID: takeID)

        XCTAssertEqual(updated.takes.first?.thumbnailFileName, "thumbnail.jpg")
        XCTAssertTrue(thumbnailURL.path.hasPrefix(store.projectDirectory(id: project.id).path))
        XCTAssertTrue(store.pendingExportURL(projectID: project.id).path.hasPrefix(store.projectDirectory(id: project.id).path))
    }

    func testCompletedExportHandoffIsNotOfferedForRetryAndIsCleanedOnLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let export = store.pendingExportURL(projectID: project.id)
        try FileManager.default.createDirectory(at: export.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("export".utf8).write(to: export)

        try store.recordExportHandoffCompleted(projectID: project.id)

        XCTAssertFalse(store.pendingExportNeedsHandoff(projectID: project.id))
        XCTAssertEqual(try store.load(id: project.id).recoveryState, .exportHandoffCompleted)
        store.finishCompletedExports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertEqual(try store.load(id: project.id).recoveryState, .clean)
    }

    func testUndescribedPendingExportIsPreservedButNotOfferedForRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let export = store.pendingExportURL(projectID: project.id)
        try FileManager.default.createDirectory(
            at: export.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("export".utf8).write(to: export)

        _ = try store.setPendingExportState(projectID: project.id, pending: true)

        XCTAssertFalse(store.pendingExportNeedsHandoff(projectID: project.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
        XCTAssertEqual(try store.load(id: project.id).recoveryState, .pendingExport)
    }

    func testLegacyUnfinishedTakesMoveIntoARecoveredProject() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let legacyStore = TakeManifestStore(recordingsRoot: support.appendingPathComponent("Recordings", isDirectory: true))
        let legacyTake = try legacyStore.createTake(orientation: .portrait)
        let store = ProjectStore(projectsRoot: support.appendingPathComponent("Projects", isDirectory: true))

        try store.migrateLegacyRecordingsIfNeeded()

        let recovered = try XCTUnwrap(store.projects().first)
        XCTAssertEqual(recovered.name, "Recovered")
        XCTAssertEqual(store.unfinishedTakes(projectID: recovered.id).map(\.id), [legacyTake.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyStore.recordingsRoot.path))
    }

    private func makeMovie() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data("movie".utf8).write(to: url)
        return url
    }
}
