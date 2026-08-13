import XCTest
@testable import Camenya

final class ProjectStoreTests: XCTestCase {
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

        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.takes.first?.duration, 12)
        XCTAssertNil(migrated.takes.first?.trimDecision)
        XCTAssertNil(migrated.captionConfiguration)
        XCTAssertNil(migrated.takes.first?.captions)
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

    func testDeletingATakeRemovesOnlyItsOwnedMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 100))
        let deletedID = UUID()
        let keptID = UUID()
        _ = try store.addTake(projectID: project.id, takeID: deletedID, movieAt: makeMovie(), orientation: .portrait, duration: 1, createdAt: Date(timeIntervalSince1970: 101))
        _ = try store.addTake(projectID: project.id, takeID: keptID, movieAt: makeMovie(), orientation: .portrait, duration: 2, createdAt: Date(timeIntervalSince1970: 102))

        let updated = try store.deleteTake(projectID: project.id, takeID: deletedID, modifiedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(updated.takes.map(\.id), [keptID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.takeMovieURL(projectID: project.id, takeID: deletedID).path))
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

    func testCompletedPhotosExportIsNotOfferedForRetryAndIsCleanedOnLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let export = store.pendingExportURL(projectID: project.id)
        try FileManager.default.createDirectory(at: export.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("export".utf8).write(to: export)

        try store.recordPhotosSaveCompleted(projectID: project.id)

        XCTAssertFalse(store.pendingExportNeedsPhotoSave(projectID: project.id))
        XCTAssertEqual(try store.load(id: project.id).recoveryState, .photosSaveCompleted)
        store.finishCompletedExports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertEqual(try store.load(id: project.id).recoveryState, .clean)
    }

    func testPendingPhotosExportRemainsAvailableForRetry() throws {
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

        XCTAssertTrue(store.pendingExportNeedsPhotoSave(projectID: project.id))
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
