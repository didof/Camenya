import XCTest
import QuartzCore
@testable import Camenya

private actor FinishVideoProbe {
    private(set) var events: [String] = []
    private(set) var photosAttempts = 0
    private(set) var lockAttempts = 0
    private(set) var cleanPlanWasPresentationFree = false

    func record(_ event: String) -> Int {
        events.append(event)
        if event == "photos" { photosAttempts += 1 }
        return photosAttempts
    }

    func recordCleanPlan(_ plan: ProjectExportPlan) {
        cleanPlanWasPresentationFree = plan.captionConfiguration == nil
            && plan.captionTimeline == nil
            && plan.finishingTimeline == nil
    }

    func recordLockAttempt() -> Int {
        events.append("lock")
        lockAttempts += 1
        return lockAttempts
    }
}

private enum FinishVideoProbeError: Error {
    case encodeFailed
    case validationFailed
    case photosFailed
}

private struct LegacyUpgradeCaptionRecognizer: CaptionRecognizing {
    let generation = CaptionRecognizerGeneration.speechRecognizerIOS18

    func availability(for localeIdentifier: String) async -> CaptionRecognitionAvailability {
        .available
    }

    func recognize(
        movieAt url: URL,
        sourceRange: TakeRange,
        localeIdentifier: String
    ) async throws -> [CaptionCue] {
        [CaptionCue(
            range: sourceRange,
            recognizedText: "Preserved caption",
            text: "Preserved caption",
            confidence: nil,
            alternatives: [],
            timedSpans: []
        )]
    }
}

final class ProjectTextOverlayTests: XCTestCase {
    @MainActor
    func testSchemaTenPictureLockMustUpgradeCleanMasterAndPreservesCaptions() async throws {
        let fixture = try makeLockedProject()
        let originalTrack = try XCTUnwrap(fixture.locked.projectCaptionTrack)
        let manifestURL = fixture.store.projectDirectory(id: fixture.project.id)
            .appendingPathComponent("project.json")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        json["schemaVersion"] = 10
        json.removeValue(forKey: "cleanMaster")
        json.removeValue(forKey: "projectTextOverlays")
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL, options: .atomic)

        let migrated = try fixture.store.load(id: fixture.project.id)
        XCTAssertTrue(migrated.needsCleanMasterUpgrade)
        XCTAssertFalse(migrated.hasPhotosConfirmedPictureLock)
        XCTAssertEqual(migrated.projectCaptionTrack, originalTrack)
        var divergentLegacyLock = migrated
        divergentLegacyLock.primaryStoryline.revision = try migrated.primaryStoryline.revision.incremented()
        XCTAssertFalse(divergentLegacyLock.isReadyForCleanMasterCommit)
        let blockedProbe = FinishVideoProbe()
        let blockedModel = AppModel(
            project: divergentLegacyLock,
            projectStore: fixture.store,
            finishVideoDependencies: FinishVideoDependencies(
                validate: { _, _ in migrated.approximateDuration },
                saveToPhotos: { _ in _ = await blockedProbe.record("photos") }
            )
        )
        blockedModel.finishVideo()
        XCTAssertFalse(blockedModel.isExportingProject)
        let blockedPhotosAttempts = await blockedProbe.photosAttempts
        XCTAssertEqual(blockedPhotosAttempts, 0)
        let legacySnapshot = try await TimelineEditor(
            projectID: migrated.id,
            projectStore: fixture.store
        ).snapshot()
        XCTAssertNil(legacySnapshot.finishingTimeline)
        XCTAssertThrowsError(try fixture.store.replaceProjectTextOverlays(
            projectID: migrated.id,
            pictureLockID: try XCTUnwrap(migrated.pictureLock?.id),
            overlays: []
        ))

        let dependencies = FinishVideoDependencies(
            validate: { _, _ in migrated.approximateDuration },
            saveToPhotos: { _ in }
        )
        let model = AppModel(
            project: migrated,
            projectStore: fixture.store,
            finishVideoDependencies: dependencies,
            captionTranscriber: CaptionTranscriber(recognizer: LegacyUpgradeCaptionRecognizer())
        )
        model.resumeProjectCaptionGeneration()
        XCTAssertFalse(model.isTranscribingCaptions)

        model.finishVideo()
        for _ in 0..<500 where model.isExportingProject { await Task.yield() }
        for _ in 0..<500 where model.isTranscribingCaptions { await Task.yield() }

        let upgraded = try fixture.store.load(id: migrated.id)
        XCTAssertTrue(upgraded.hasPhotosConfirmedPictureLock)
        XCTAssertFalse(upgraded.needsCleanMasterUpgrade)
        XCTAssertEqual(
            upgraded.projectCaptionTrack?.pictureLockID,
            originalTrack.pictureLockID
        )
        XCTAssertEqual(
            upgraded.projectCaptionTrack?.regions.map(\.id),
            originalTrack.regions.map(\.id)
        )
        XCTAssertTrue(upgraded.projectCaptionTrack?.isGenerationComplete == true)
        let upgradedSnapshot = try await TimelineEditor(
            projectID: migrated.id,
            projectStore: fixture.store
        ).snapshot()
        XCTAssertNotNil(upgradedSnapshot.finishingTimeline)
    }

    @MainActor
    func testFinishVideoCoordinatorRunsInjectedDependenciesInOrderAndCommitsLock() async throws {
        let fixture = try makeReadyProject()
        let probe = FinishVideoProbe()
        let duration = fixture.ready.approximateDuration
        let dependencies = FinishVideoDependencies(
            export: { plan, url in
                await probe.recordCleanPlan(plan)
                _ = await probe.record("export")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("clean master".utf8).write(to: url)
                return url
            },
            validate: { _, _ in
                _ = await probe.record("validate")
                return duration
            },
            saveToPhotos: { _ in
                _ = await probe.record("photos")
            }
        )
        let model = AppModel(
            project: fixture.ready,
            projectStore: fixture.store,
            finishVideoDependencies: dependencies
        )

        model.finishVideo()
        for _ in 0..<500 where model.isExportingProject { await Task.yield() }

        let events = await probe.events
        let cleanPlanWasPresentationFree = await probe.cleanPlanWasPresentationFree
        XCTAssertFalse(model.isExportingProject)
        XCTAssertEqual(events, ["export", "validate", "photos"])
        XCTAssertTrue(cleanPlanWasPresentationFree)
        XCTAssertNotNil(try fixture.store.load(id: fixture.project.id).pictureLock)
    }

    @MainActor
    func testFinishVideoRetryAfterDefinitivePhotosFailureReusesValidatedMaster() async throws {
        let fixture = try makeReadyProject()
        let probe = FinishVideoProbe()
        let duration = fixture.ready.approximateDuration
        let dependencies = FinishVideoDependencies(
            export: { _, url in
                _ = await probe.record("export")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("clean master".utf8).write(to: url)
                return url
            },
            validate: { _, _ in
                _ = await probe.record("validate")
                return duration
            },
            saveToPhotos: { _ in
                let attempt = await probe.record("photos")
                if attempt == 1 { throw FinishVideoProbeError.photosFailed }
            }
        )
        let model = AppModel(
            project: fixture.ready,
            projectStore: fixture.store,
            finishVideoDependencies: dependencies
        )

        model.finishVideo()
        for _ in 0..<500 where model.isExportingProject { await Task.yield() }
        XCTAssertTrue(model.hasFailedProjectExportRetry)
        XCTAssertNil(fixture.store.recoverableCleanMaster(projectID: fixture.project.id)?.photosSaveStartedAt)

        model.retryFailedProjectExport()
        for _ in 0..<500 where model.isExportingProject { await Task.yield() }

        let photosAttempts = await probe.photosAttempts
        let events = await probe.events
        XCTAssertFalse(model.isExportingProject)
        XCTAssertEqual(photosAttempts, 2)
        XCTAssertEqual(events.filter { $0 == "export" }.count, 1)
        XCTAssertNotNil(try fixture.store.load(id: fixture.project.id).pictureLock)
    }

    @MainActor
    func testFinishVideoEncodeFailureLeavesStorylineEditableAndRetryable() async throws {
        let fixture = try makeReadyProject()
        let probe = FinishVideoProbe()
        let dependencies = FinishVideoDependencies(
            export: { _, _ in
                _ = await probe.record("export")
                throw FinishVideoProbeError.encodeFailed
            },
            validate: { _, _ in
                _ = await probe.record("validate")
                return fixture.ready.approximateDuration
            },
            saveToPhotos: { _ in
                _ = await probe.record("photos")
            }
        )
        let model = AppModel(
            project: fixture.ready,
            projectStore: fixture.store,
            finishVideoDependencies: dependencies
        )

        model.finishVideo()
        for _ in 0..<500 where model.isExportingProject { await Task.yield() }

        let events = await probe.events
        XCTAssertTrue(model.hasFailedProjectExportRetry)
        XCTAssertEqual(events, ["export"])
        XCTAssertNil(try fixture.store.load(id: fixture.project.id).pictureLock)
    }

    @MainActor
    func testFinishVideoRejectsDurationMismatchBeforePhotosAndPictureLock() async throws {
        let fixture = try makeReadyProject()
        let probe = FinishVideoProbe()
        let expectedDuration = fixture.ready.approximateDuration
        let dependencies = FinishVideoDependencies(
            export: { _, url in
                _ = await probe.record("export")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("truncated clean master".utf8).write(to: url)
                return url
            },
            validate: { _, _ in
                _ = await probe.record("validate")
                return expectedDuration - CleanMasterDurationPolicy.tolerance - 0.1
            },
            saveToPhotos: { _ in
                _ = await probe.record("photos")
            }
        )
        let model = AppModel(
            project: fixture.ready,
            projectStore: fixture.store,
            finishVideoDependencies: dependencies
        )

        model.finishVideo()
        for _ in 0..<500 where model.isExportingProject { await Task.yield() }

        let events = await probe.events
        XCTAssertTrue(model.hasFailedProjectExportRetry)
        XCTAssertEqual(events.filter { $0 == "photos" }.count, 0)
        XCTAssertNil(fixture.store.recoverableCleanMaster(projectID: fixture.project.id))
        XCTAssertNil(try fixture.store.load(id: fixture.project.id).pictureLock)
    }

    @MainActor
    func testFinishVideoLockPersistenceRetryDoesNotRepeatEncodeOrPhotosSave() async throws {
        let fixture = try makeReadyProject()
        let probe = FinishVideoProbe()
        let duration = fixture.ready.approximateDuration
        let dependencies = FinishVideoDependencies(
            export: { _, url in
                _ = await probe.record("export")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("clean master".utf8).write(to: url)
                return url
            },
            validate: { _, _ in
                _ = await probe.record("validate")
                return duration
            },
            saveToPhotos: { _ in
                _ = await probe.record("photos")
            },
            commitPictureLock: { store, projectID, revision in
                let attempt = await probe.recordLockAttempt()
                if attempt == 1 { throw FinishVideoProbeError.validationFailed }
                return try store.commitPictureLockAfterCleanMaster(
                    projectID: projectID,
                    expectedRevision: revision
                )
            }
        )
        let model = AppModel(
            project: fixture.ready,
            projectStore: fixture.store,
            finishVideoDependencies: dependencies
        )

        model.finishVideo()
        for _ in 0..<500 where model.isExportingProject { await Task.yield() }
        XCTAssertTrue(model.hasFailedProjectExportRetry)
        XCTAssertNotNil(fixture.store.recoverableCleanMaster(projectID: fixture.project.id)?.savedToPhotosAt)

        model.retryFailedProjectExport()
        for _ in 0..<500 where model.isExportingProject { await Task.yield() }

        let events = await probe.events
        XCTAssertEqual(events.filter { $0 == "export" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "photos" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "lock" }.count, 2)
        XCTAssertNotNil(try fixture.store.load(id: fixture.project.id).pictureLock)
    }

    func testCleanMasterLocksTheCheckedStorylineBeforeFinishingBegins() throws {
        let fixture = try makeReadyProject()
        let cleanMaster = fixture.store.cleanMasterURL(
            projectID: fixture.project.id,
            revision: fixture.ready.primaryStoryline.revision
        )
        try FileManager.default.createDirectory(
            at: cleanMaster.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("validated movie".utf8).write(to: cleanMaster)
        try fixture.store.recordValidatedCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: fixture.ready.primaryStoryline.revision,
            cleanMasterURL: cleanMaster,
            duration: fixture.ready.approximateDuration
        )
        try fixture.store.recordCleanMasterPhotosSaveStarted(
            projectID: fixture.project.id,
            expectedRevision: fixture.ready.primaryStoryline.revision
        )
        try fixture.store.recordCleanMasterSavedToPhotos(
            projectID: fixture.project.id,
            expectedRevision: fixture.ready.primaryStoryline.revision,
            savedAt: Date(timeIntervalSince1970: 50)
        )
        let locked = try fixture.store.commitPictureLockAfterCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: fixture.ready.primaryStoryline.revision
        )

        XCTAssertNotNil(locked.pictureLock)
        XCTAssertNil(locked.projectCaptionTrack)
        XCTAssertEqual(locked.cleanMaster?.storylineRevision, fixture.ready.primaryStoryline.revision)
        XCTAssertEqual(locked.cleanMaster?.savedToPhotosAt, Date(timeIntervalSince1970: 50))
    }

    func testCaptionsCanOnlyBeCreatedAfterTheCleanMasterPictureLock() throws {
        let fixture = try makeReadyProject()
        let configuration = ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)

        XCTAssertThrowsError(try fixture.store.createProjectCaptionTrack(
            projectID: fixture.project.id,
            configuration: configuration
        ))

        let cleanMaster = fixture.store.cleanMasterURL(
            projectID: fixture.project.id,
            revision: fixture.ready.primaryStoryline.revision
        )
        try FileManager.default.createDirectory(at: cleanMaster.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("validated movie".utf8).write(to: cleanMaster)
        try fixture.store.recordValidatedCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: fixture.ready.primaryStoryline.revision,
            cleanMasterURL: cleanMaster,
            duration: fixture.ready.approximateDuration
        )
        try fixture.store.recordCleanMasterPhotosSaveStarted(
            projectID: fixture.project.id,
            expectedRevision: fixture.ready.primaryStoryline.revision
        )
        try fixture.store.recordCleanMasterSavedToPhotos(
            projectID: fixture.project.id,
            expectedRevision: fixture.ready.primaryStoryline.revision
        )
        _ = try fixture.store.commitPictureLockAfterCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: fixture.ready.primaryStoryline.revision
        )

        let captioned = try fixture.store.createProjectCaptionTrack(
            projectID: fixture.project.id,
            configuration: configuration
        )
        XCTAssertNotNil(captioned.projectCaptionTrack)
    }

    func testPictureLockRequiresADurablePhotosConfirmedCleanMaster() throws {
        let fixture = try makeReadyProject()
        let revision = fixture.ready.primaryStoryline.revision
        let cleanMaster = fixture.store.cleanMasterURL(
            projectID: fixture.project.id,
            revision: revision
        )
        try FileManager.default.createDirectory(
            at: cleanMaster.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("validated movie".utf8).write(to: cleanMaster)
        try fixture.store.recordValidatedCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: revision,
            cleanMasterURL: cleanMaster,
            duration: fixture.ready.approximateDuration
        )

        XCTAssertThrowsError(try fixture.store.commitPictureLockAfterCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: revision
        )) { error in
            XCTAssertEqual(error as? ProjectStoreError, .cleanMasterNotSavedToPhotos)
        }
    }

    func testPhotosConfirmedCleanMasterRecoverySurvivesRelaunchWithoutLosingItsPhase() throws {
        let fixture = try makeReadyProject()
        let revision = fixture.ready.primaryStoryline.revision
        let savedAt = Date(timeIntervalSince1970: 123)
        let cleanMaster = fixture.store.cleanMasterURL(
            projectID: fixture.project.id,
            revision: revision
        )
        try FileManager.default.createDirectory(
            at: cleanMaster.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("validated movie".utf8).write(to: cleanMaster)
        try fixture.store.recordValidatedCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: revision,
            cleanMasterURL: cleanMaster,
            duration: fixture.ready.approximateDuration
        )
        try fixture.store.recordCleanMasterPhotosSaveStarted(
            projectID: fixture.project.id,
            expectedRevision: revision
        )
        try fixture.store.recordCleanMasterSavedToPhotos(
            projectID: fixture.project.id,
            expectedRevision: revision,
            savedAt: savedAt
        )

        let reopened = ProjectStore(projectsRoot: fixture.store.projectsRoot)
        let recovered = try XCTUnwrap(reopened.recoverableCleanMaster(projectID: fixture.project.id))
        XCTAssertEqual(recovered.savedToPhotosAt, savedAt)

        let revalidated = try reopened.recordValidatedCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: revision,
            cleanMasterURL: cleanMaster,
            duration: fixture.ready.approximateDuration
        )
        XCTAssertEqual(revalidated.savedToPhotosAt, savedAt)

        let locked = try reopened.commitPictureLockAfterCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: revision
        )
        XCTAssertEqual(locked.cleanMaster?.savedToPhotosAt, savedAt)
        XCTAssertNil(reopened.recoverableCleanMaster(projectID: fixture.project.id))
    }

    func testInFlightPhotosSaveSurvivesRelaunchAndRequiresExplicitResolution() throws {
        let fixture = try makeReadyProject()
        let revision = fixture.ready.primaryStoryline.revision
        let startedAt = Date(timeIntervalSince1970: 120)
        let cleanMaster = fixture.store.cleanMasterURL(
            projectID: fixture.project.id,
            revision: revision
        )
        try FileManager.default.createDirectory(
            at: cleanMaster.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("validated movie".utf8).write(to: cleanMaster)
        try fixture.store.recordValidatedCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: revision,
            cleanMasterURL: cleanMaster,
            duration: fixture.ready.approximateDuration
        )
        try fixture.store.recordCleanMasterPhotosSaveStarted(
            projectID: fixture.project.id,
            expectedRevision: revision,
            startedAt: startedAt
        )

        let reopened = ProjectStore(projectsRoot: fixture.store.projectsRoot)
        let recovered = try XCTUnwrap(reopened.recoverableCleanMaster(projectID: fixture.project.id))
        XCTAssertEqual(recovered.photosSaveStartedAt, startedAt)
        XCTAssertNil(recovered.savedToPhotosAt)

        let revalidated = try reopened.recordValidatedCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: revision,
            cleanMasterURL: cleanMaster,
            duration: fixture.ready.approximateDuration
        )
        XCTAssertEqual(revalidated.photosSaveStartedAt, startedAt)
        XCTAssertNil(revalidated.savedToPhotosAt)
    }

    func testDefinitivePhotosFailureClearsOnlyTheInFlightMarker() throws {
        let fixture = try makeReadyProject()
        let revision = fixture.ready.primaryStoryline.revision
        let cleanMaster = fixture.store.cleanMasterURL(
            projectID: fixture.project.id,
            revision: revision
        )
        try FileManager.default.createDirectory(
            at: cleanMaster.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("validated movie".utf8).write(to: cleanMaster)
        try fixture.store.recordValidatedCleanMaster(
            projectID: fixture.project.id,
            expectedRevision: revision,
            cleanMasterURL: cleanMaster,
            duration: fixture.ready.approximateDuration
        )
        try fixture.store.recordCleanMasterPhotosSaveStarted(
            projectID: fixture.project.id,
            expectedRevision: revision
        )

        try fixture.store.recordCleanMasterPhotosSaveFailed(
            projectID: fixture.project.id,
            expectedRevision: revision
        )

        let recovered = try XCTUnwrap(fixture.store.recoverableCleanMaster(projectID: fixture.project.id))
        XCTAssertNil(recovered.photosSaveStartedAt)
        XCTAssertNil(recovered.savedToPhotosAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanMaster.path))
    }

    func testEditorAddsAThreeSecondOverlayAtThePlayheadAndClampsToProjectEnd() throws {
        var editor = TextOverlayEditorState(overlays: [], duration: 10)

        let first = editor.addOverlay(at: 4, text: "Title")
        let final = editor.addOverlay(at: 9.4, text: "End card")

        XCTAssertEqual(first.range.start.seconds, 4, accuracy: 0.001)
        XCTAssertEqual(first.range.end.seconds, 7, accuracy: 0.001)
        XCTAssertEqual(final.range.start.seconds, 9.4, accuracy: 0.001)
        XCTAssertEqual(final.range.end.seconds, 10, accuracy: 0.001)
        XCTAssertEqual(editor.overlays.map(\.id), [first.id, final.id])
    }

    func testOverlayAcceptsLongUserTextWhenItIsOtherwiseValid() throws {
        let overlay = ProjectTextOverlay(
            text: String(repeating: "A complete thought with natural wrapping. ", count: 8),
            range: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 4)),
            center: NormalizedProjectPoint(x: 0.5, y: 0.5),
            appearance: .default
        )

        XCTAssertTrue(overlay.isValid(inside: 4))
    }

    func testTextAppearanceRoundTripsExactlyThroughCaptionCustomization() {
        let appearance = TextAppearance(
            fontDesign: .monospaced,
            fontWeight: .heavy,
            fontScale: .large,
            color: TextColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.7),
            outline: .strong,
            background: .roundedBox,
            alignment: .leading
        )

        XCTAssertEqual(
            TextAppearance(captionCustomization: appearance.captionCustomization),
            appearance
        )
    }

    func testSharedAppearanceOverridesMatchingCaptionStyleWithoutLosingCaptionHighlighting() {
        var captionCustomization = CaptionStyleCustomization()
        captionCustomization.highlighting = .pill
        let captionStyle = SavedCaptionStyle(name: "Creator", customization: captionCustomization)
        var updatedAppearance = TextAppearance.default
        updatedAppearance.fontDesign = .monospaced
        updatedAppearance.fontWeight = .heavy
        updatedAppearance.color = TextColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        let shared = SavedTextAppearance(
            id: UUID(),
            name: "creator",
            appearance: updatedAppearance
        )

        let resolved = CaptionSavedStyleResolver.customization(
            for: captionStyle,
            sharedAppearances: [shared]
        )

        XCTAssertEqual(TextAppearance(captionCustomization: resolved), updatedAppearance)
        XCTAssertEqual(resolved.highlighting, .pill)
    }

    func testEditorNudgesOverlayEdgesByAnActualHundredthOfASecond() throws {
        let overlay = ProjectTextOverlay(
            text: "Precise",
            range: ProjectTimeRange(start: ProjectTime(seconds: 1), end: ProjectTime(seconds: 4)),
            center: NormalizedProjectPoint(x: 0.5, y: 0.5),
            appearance: .default
        )
        var editor = TextOverlayEditorState(overlays: [overlay], duration: 8)

        try editor.nudgeStart(id: overlay.id, by: 0.01)
        try editor.nudgeEnd(id: overlay.id, by: -0.01)

        XCTAssertEqual(editor.overlays[0].range.start.seconds, 1.01, accuracy: 0.001)
        XCTAssertEqual(editor.overlays[0].range.end.seconds, 3.99, accuracy: 0.001)
    }

    func testEditorUndoAndRedoRestoreWholeOverlayOperations() throws {
        var editor = TextOverlayEditorState(overlays: [], duration: 12)
        let overlay = editor.addOverlay(at: 2, text: "One")
        try editor.updateText(id: overlay.id, text: "Two")

        XCTAssertEqual(editor.overlays[0].text, "Two")
        XCTAssertEqual(editor.undo()?.name, "Edit Text")
        XCTAssertEqual(editor.overlays[0].text, "One")
        XCTAssertEqual(editor.redo()?.name, "Edit Text")
        XCTAssertEqual(editor.overlays[0].text, "Two")
    }

    func testDuplicateCopiesContentAndAppearanceButReceivesIndependentIdentity() throws {
        var appearance = TextAppearance.default
        appearance.fontDesign = .serif
        appearance.color = TextColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1)
        let original = ProjectTextOverlay(
            text: "Chapter",
            range: ProjectTimeRange(
                start: ProjectTime(seconds: 1),
                end: ProjectTime(seconds: 4)
            ),
            center: NormalizedProjectPoint(x: 0.4, y: 0.6),
            appearance: appearance
        )
        var editor = TextOverlayEditorState(overlays: [original], duration: 8)

        let duplicate = try editor.duplicate(id: original.id)

        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.text, original.text)
        XCTAssertEqual(duplicate.range, original.range)
        XCTAssertEqual(duplicate.appearance, original.appearance)
        XCTAssertEqual(editor.overlays.map(\.id), [original.id, duplicate.id])
    }

    @MainActor
    func testRendererConstrainsEveryTextFrameToTheContentSafeRegion() {
        let canvas = CGSize(width: 1080, height: 1920)
        let safeRegion = CaptionPresentationLayout.contentSafeRegion(in: canvas)
        let centers = [
            NormalizedProjectPoint(x: 0, y: 0),
            NormalizedProjectPoint(x: 1, y: 0),
            NormalizedProjectPoint(x: 0, y: 1),
            NormalizedProjectPoint(x: 1, y: 1)
        ]

        for center in centers {
            let overlay = ProjectTextOverlay(
                text: "Safe text near every edge",
                range: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 2)),
                center: center,
                appearance: .default
            )
            let frame = ProjectFinishingRenderer().previewFrame(overlay: overlay, canvas: canvas)
            XCTAssertGreaterThanOrEqual(frame.minX, safeRegion.minX)
            XCTAssertLessThanOrEqual(frame.maxX, safeRegion.maxX)
            XCTAssertGreaterThanOrEqual(frame.minY, safeRegion.minY)
            XCTAssertLessThanOrEqual(frame.maxY, safeRegion.maxY)
        }
    }

    @MainActor
    func testRendererFitsAllLongMultilineTextInsideTheContentSafeRegion() throws {
        let canvas = CGSize(width: 1080, height: 1920)
        let text = (0..<80).map { "Complete overlay line \($0)" }.joined(separator: "\n")
        let overlay = ProjectTextOverlay(
            text: text,
            range: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 2)),
            center: NormalizedProjectPoint(x: 0.5, y: 0.5),
            appearance: .default
        )

        let layer = ProjectFinishingRenderer().makePreviewLayer(overlay: overlay, canvas: canvas)
        let safeRegion = CaptionPresentationLayout.contentSafeRegion(in: canvas)
        let content = try XCTUnwrap(layer.sublayers?.first)
        let textLayer = try XCTUnwrap(content.sublayers?.first as? CATextLayer)
        let rendered = try XCTUnwrap(textLayer.string as? NSAttributedString)

        XCTAssertEqual(rendered.string, text)
        XCTAssertTrue(safeRegion.contains(layer.frame))
        XCTAssertLessThan(content.affineTransform().a, 1)
    }

    func testEditorPresentationPolicyKeepsKeyboardAndAccessibilityBehaviorExplicit() {
        XCTAssertTrue(TextOverlayEditorPresentationPolicy.showsVideoPreview(isTextFieldFocused: false))
        XCTAssertFalse(TextOverlayEditorPresentationPolicy.showsVideoPreview(isTextFieldFocused: true))
        XCTAssertTrue(TextOverlayEditorPresentationPolicy.shouldCommitDraftBeforeDeletion("Title"))
        XCTAssertFalse(TextOverlayEditorPresentationPolicy.shouldCommitDraftBeforeDeletion("  \n"))
        XCTAssertEqual(
            TextOverlayEditorPresentationPolicy.positionAccessibilityLabel(text: "Title"),
            "Text overlay: Title"
        )
        XCTAssertEqual(
            TextOverlayEditorPresentationPolicy.timelineAccessibilityLabel,
            "Text overlay timeline"
        )
    }

    func testPictureLockOwnsAnOrderedValidatedTextOverlayCollection() throws {
        let fixture = try makeLockedProject()
        let lockID = try XCTUnwrap(fixture.locked.pictureLock?.id)
        let back = ProjectTextOverlay(
            text: "Behind",
            range: ProjectTimeRange(
                start: ProjectTime(seconds: 1),
                end: ProjectTime(seconds: 3)
            ),
            center: NormalizedProjectPoint(x: 0.5, y: 0.35),
            appearance: .default
        )
        let front = ProjectTextOverlay(
            text: "In front",
            range: ProjectTimeRange(
                start: ProjectTime(seconds: 2),
                end: ProjectTime(seconds: 4)
            ),
            center: NormalizedProjectPoint(x: 0.5, y: 0.65),
            appearance: .default
        )

        let updated = try fixture.store.replaceProjectTextOverlays(
            projectID: fixture.project.id,
            pictureLockID: lockID,
            overlays: [back, front]
        )

        XCTAssertEqual(updated.projectTextOverlays, [back, front])
    }

    func testInvalidOverlaySaveLeavesThePreviousCollectionUnchanged() throws {
        let fixture = try makeLockedProject()
        let valid = ProjectTextOverlay(
            text: "Safe",
            range: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 2)),
            center: NormalizedProjectPoint(x: 0.5, y: 0.5),
            appearance: .default
        )
        _ = try fixture.store.replaceProjectTextOverlays(
            projectID: fixture.project.id,
            pictureLockID: try XCTUnwrap(fixture.locked.pictureLock?.id),
            overlays: [valid]
        )
        var invalid = valid
        invalid.text = "   "

        XCTAssertThrowsError(try fixture.store.replaceProjectTextOverlays(
            projectID: fixture.project.id,
            pictureLockID: try XCTUnwrap(fixture.locked.pictureLock?.id),
            overlays: [invalid]
        ))
        XCTAssertEqual(try fixture.store.load(id: fixture.project.id).projectTextOverlays, [valid])
    }

    func testUnlockRemovesFinishingTextFromTheEditableStoryline() throws {
        let fixture = try makeLockedProject()
        let overlay = ProjectTextOverlay(
            text: "Temporary finishing text",
            range: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 2)),
            center: NormalizedProjectPoint(x: 0.5, y: 0.5),
            appearance: .default
        )
        _ = try fixture.store.replaceProjectTextOverlays(
            projectID: fixture.project.id,
            pictureLockID: try XCTUnwrap(fixture.locked.pictureLock?.id),
            overlays: [overlay]
        )

        let unlocked = try fixture.store.unlockPictureLock(projectID: fixture.project.id)

        XCTAssertNil(unlocked.pictureLock)
        XCTAssertTrue(unlocked.projectTextOverlays.isEmpty)
    }

    func testLockedSnapshotPublishesTextOverlaysInCompositingOrder() async throws {
        let fixture = try makeLockedProject()
        let lockID = try XCTUnwrap(fixture.locked.pictureLock?.id)
        let first = ProjectTextOverlay(
            text: "First",
            range: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 2)),
            center: NormalizedProjectPoint(x: 0.5, y: 0.4),
            appearance: .default
        )
        let second = ProjectTextOverlay(
            text: "Second",
            range: ProjectTimeRange(
                start: ProjectTime(seconds: 1),
                end: ProjectTime(seconds: 4)
            ),
            center: NormalizedProjectPoint(x: 0.5, y: 0.6),
            appearance: .default
        )
        _ = try fixture.store.replaceProjectTextOverlays(
            projectID: fixture.project.id,
            pictureLockID: lockID,
            overlays: [first, second]
        )

        let snapshot = try await TimelineEditor(
            projectID: fixture.project.id,
            projectStore: fixture.store
        ).snapshot()

        XCTAssertEqual(snapshot.finishingTimeline?.pictureLockID, lockID)
        XCTAssertEqual(snapshot.finishingTimeline?.textOverlays, [first, second])
        XCTAssertEqual(snapshot.finishingTimeline?.activeTextOverlays(at: 1.5), [first, second])
    }

    @MainActor
    func testFinishingRendererAlwaysCompositesCaptionsAboveTextOverlays() throws {
        let overlay = ProjectTextOverlay(
            text: "Overlay",
            range: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 3)),
            center: NormalizedProjectPoint(x: 0.5, y: 0.5),
            appearance: .default
        )
        let captions = ProjectCaptionExportTimeline(
            placement: .lower,
            style: .clean,
            duration: 3,
            cues: [ProjectCaptionExportCue(
                range: TakeRange(startSeconds: 0, endSeconds: 3),
                text: "Caption",
                timedSpans: []
            )]
        )
        let timeline = ProjectFinishingTimeline(
            pictureLockID: UUID(),
            duration: 3,
            textOverlays: [overlay],
            captions: captions
        )

        let tree = ProjectFinishingRenderer().makeLayerTree(
            timeline: timeline,
            canvas: CGSize(width: 1080, height: 1920)
        )

        let layers = try XCTUnwrap(tree.presentation.sublayers)
        XCTAssertEqual(layers.first?.name, "text-overlay")
        XCTAssertEqual(layers.last?.name, "caption")
    }

    func testExportPlanCarriesTheImmutableFinishingTimeline() throws {
        let overlay = ProjectTextOverlay(
            text: "Export me",
            range: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 2)),
            center: NormalizedProjectPoint(x: 0.5, y: 0.5),
            appearance: .default
        )
        let finishing = ProjectFinishingTimeline(
            pictureLockID: UUID(),
            duration: 2,
            textOverlays: [overlay],
            captions: nil
        )
        let snapshot = ExportSnapshot(
            projectID: UUID(),
            revision: .zero,
            format: .portrait,
            captionConfiguration: nil,
            finishingTimeline: finishing,
            clips: [ExportSnapshot.Clip(
                id: TimelineClip.ID(),
                takeID: UUID(),
                mediaURL: URL(fileURLWithPath: "/tmp/take.mov"),
                sourceRange: TakeRange(startSeconds: 0, endSeconds: 2),
                availableRange: TakeRange(startSeconds: 0, endSeconds: 2),
                selection: TakeRange(startSeconds: 0, endSeconds: 2),
                projectTimeRange: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 2))
            )],
            duration: ProjectTime(seconds: 2)
        )

        let plan = try ProjectExportPlan(snapshot: snapshot)

        XCTAssertEqual(plan.finishingTimeline, finishing)
    }

    private func makeLockedProject() throws -> (
        store: ProjectStore,
        project: ProjectManifest,
        locked: ProjectManifest
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 1))
        let movie = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try Data("movie".utf8).write(to: movie)
        addTeardownBlock { try? FileManager.default.removeItem(at: movie) }
        _ = try store.addTake(
            projectID: project.id,
            takeID: UUID(),
            movieAt: movie,
            orientation: .portrait,
            duration: 6,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        _ = try store.markStorylineChecked(projectID: project.id)
        let locked = try store.createPictureLockForTesting(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
        )
        return (store, project, locked)
    }

    private func makeReadyProject() throws -> (
        store: ProjectStore,
        project: ProjectManifest,
        ready: ProjectManifest
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 1))
        let movie = root.appendingPathComponent("source.mov")
        try Data("movie".utf8).write(to: movie)
        _ = try store.addTake(
            projectID: project.id,
            takeID: UUID(),
            movieAt: movie,
            orientation: .portrait,
            duration: 6,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let ready = try store.markStorylineChecked(projectID: project.id)
        return (store, project, ready)
    }
}
