import XCTest
@testable import Camenya

final class ProjectCaptionLifecycleTests: XCTestCase {
    func testCaptionedExportRequiresCompletedReviewAndCaptionTimeline() async throws {
        let fixture = try makeProjectWithTwoTakes()
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
        )
        let incompleteSnapshot = try await TimelineEditor(
            projectID: fixture.project.id,
            projectStore: fixture.store
        ).snapshot()

        XCTAssertFalse(ProjectExportVariantEligibility.canExportWithCaptions(
            project: locked,
            snapshot: incompleteSnapshot
        ))
    }

    func testPictureLockRequiresEveryActiveTakeToFinishPreparation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        _ = try store.addTake(
            projectID: project.id,
            takeID: UUID(),
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 4,
            createdAt: Date()
        )

        XCTAssertThrowsError(try store.createPictureLock(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
        )) { error in
            XCTAssertEqual(error as? ProjectStoreError, .projectNotReadyForPictureLock)
        }
    }

    func testPictureLockRequiresTheCurrentStorylineToBeChecked() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        _ = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 4,
            createdAt: Date()
        )
        _ = try store.setTrimDecision(
            projectID: project.id,
            takeID: takeID,
            decision: .keepOriginal
        )

        XCTAssertThrowsError(try store.createPictureLock(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
        )) { error in
            XCTAssertEqual(error as? ProjectStoreError, .projectNotReadyForPictureLock)
        }

        let checked = try store.markStorylineChecked(projectID: project.id)
        XCTAssertEqual(checked.checkedStorylineRevision, checked.primaryStoryline.revision)
        XCTAssertNoThrow(try store.createPictureLock(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
        ))
    }

    func testPictureLockFreezesStorylineAndBuildsProjectTimeRegionsWithTakeLanguages() throws {
        let fixture = try makeProjectWithTwoTakes()
        let italian = ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        _ = try fixture.store.setTakeSpokenLanguage(
            projectID: fixture.project.id,
            takeID: fixture.secondTakeID,
            localeIdentifier: "en-US"
        )

        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: italian,
            createdAt: Date(timeIntervalSince1970: 500)
        )

        let lock = try XCTUnwrap(locked.pictureLock)
        let track = try XCTUnwrap(locked.projectCaptionTrack)
        XCTAssertEqual(locked.schemaVersion, ProjectManifest.currentSchemaVersion)
        XCTAssertEqual(lock.storylineRevision, locked.primaryStoryline.revision)
        XCTAssertEqual(lock.clips, locked.primaryStoryline.clips)
        XCTAssertEqual(lock.duration.seconds, 12, accuracy: 0.001)
        XCTAssertEqual(track.pictureLockID, lock.id)
        XCTAssertEqual(track.regions.map(\.localeIdentifier), ["it-IT", "en-US"])
        XCTAssertEqual(track.regions.map(\.projectTimeRange), [
            ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 5)),
            ProjectTimeRange(start: ProjectTime(seconds: 5), end: ProjectTime(seconds: 12))
        ])
        XCTAssertEqual(track.pendingRegions.count, 2)
        XCTAssertEqual(track.languageRegionCount, 2)
    }

    func testConsecutiveClipsWithTheSameLanguageShareOneLanguageRegion() throws {
        let fixture = try makeProjectWithTwoTakes()
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )

        XCTAssertEqual(locked.projectCaptionTrack?.regions.count, 2)
        XCTAssertEqual(locked.projectCaptionTrack?.languageRegionCount, 1)
    }

    func testCaptionCheckpointRebasesCueAndWordTimingIntoProjectTime() throws {
        let fixture = try makeProjectWithTwoTakes()
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        let region = try XCTUnwrap(locked.projectCaptionTrack?.regions.last)
        let draft = TakeCaptionTrack(
            localeIdentifier: region.localeIdentifier,
            sourceRange: region.sourceRange,
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [CaptionCue(
                range: TakeRange(startSeconds: 1, endSeconds: 3),
                recognizedText: "Ciao mondo",
                text: "Ciao mondo",
                confidence: 0.9,
                alternatives: [],
                timedSpans: [CaptionTimedSpan(
                    range: TakeRange(startSeconds: 2, endSeconds: 2.5),
                    text: "mondo",
                    granularity: .word,
                    confidence: 0.9
                )]
            )]
        )

        let checkpointed = try fixture.store.recordProjectCaptionRegion(
            projectID: fixture.project.id,
            regionID: region.id,
            draft: draft
        )

        let track = try XCTUnwrap(checkpointed.projectCaptionTrack)
        XCTAssertEqual(track.completedRegions.count, 1)
        XCTAssertEqual(track.pendingRegions.count, 1)
        XCTAssertEqual(track.cues.first?.range, TakeRange(startSeconds: 6, endSeconds: 8))
        XCTAssertEqual(
            track.cues.first?.timedSpans.first?.range,
            TakeRange(startSeconds: 7, endSeconds: 7.5)
        )
    }

    func testCaptionCheckpointAppliesTheConfiguredDensity() throws {
        let fixture = try makeProjectWithTwoTakes()
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower,
            density: .less
        )
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: configuration
        )
        let region = try XCTUnwrap(locked.projectCaptionTrack?.regions.first)
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
        let spans = words.enumerated().map { index, word in
            CaptionTimedSpan(
                range: TakeRange(
                    startSeconds: Double(index) * 0.5,
                    endSeconds: Double(index + 1) * 0.5
                ),
                text: word,
                granularity: .word,
                confidence: 0.9
            )
        }
        let updated = try fixture.store.recordProjectCaptionRegion(
            projectID: fixture.project.id,
            regionID: region.id,
            draft: TakeCaptionTrack(
                localeIdentifier: region.localeIdentifier,
                sourceRange: region.sourceRange,
                recognizer: .speechRecognizerIOS18,
                reviewState: .needsReview,
                cues: [CaptionCue(
                    range: TakeRange(startSeconds: 0, endSeconds: 4),
                    recognizedText: words.joined(separator: " "),
                    text: words.joined(separator: " "),
                    confidence: 0.9,
                    alternatives: [],
                    timedSpans: spans
                )]
            )
        )

        XCTAssertEqual(updated.projectCaptionTrack?.cues.map(\.text), [
            "one two three four",
            "five six seven eight"
        ])
    }

    func testProjectTimeWaveformSamplesEachLockedClipFromItsSourceRange() throws {
        let fixture = try makeProjectWithTwoTakes()
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        let lock = try XCTUnwrap(locked.pictureLock)

        let samples = ProjectCaptionWaveformBuilder.make(
            lock: lock,
            takes: locked.takes,
            envelopes: [
                fixture.firstTakeID: [0.1, 0.2],
                fixture.secondTakeID: [0.7, 0.8]
            ],
            sampleCount: 4
        )

        XCTAssertEqual(samples.count, 4)
        XCTAssertLessThan(samples[0], 0.5)
        XCTAssertGreaterThan(samples[3], 0.5)
    }

    func testCancelKeepsLockAndConfigurationWhileUnlockRemovesOnlyDerivedCaptions() throws {
        let fixture = try makeProjectWithTwoTakes()
        let configuration = ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .center)
        _ = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: configuration
        )

        let cancelled = try fixture.store.cancelProjectCaptionGeneration(projectID: fixture.project.id)
        XCTAssertNotNil(cancelled.pictureLock)
        XCTAssertNil(cancelled.projectCaptionTrack)
        XCTAssertEqual(cancelled.captionConfiguration, configuration)

        let unlocked = try fixture.store.unlockPictureLock(projectID: fixture.project.id)
        XCTAssertNil(unlocked.pictureLock)
        XCTAssertNil(unlocked.projectCaptionTrack)
        XCTAssertEqual(unlocked.captionConfiguration, configuration)
        XCTAssertEqual(unlocked.primaryStoryline.clips.count, 2)
    }

    func testLanguageChangeRegeneratesTheCompleteLockedTrackAndPreservesPresentation() throws {
        let fixture = try makeProjectWithTwoTakes()
        let initial = ProjectCaptionConfiguration(
            localeIdentifier: "it-IT",
            placement: .upper,
            style: .impact,
            density: .more
        )
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: initial
        )
        let lockID = try XCTUnwrap(locked.pictureLock?.id)

        let regenerated = try fixture.store.regenerateProjectCaptions(
            projectID: fixture.project.id,
            configuration: ProjectCaptionConfiguration(
                localeIdentifier: "en-US",
                placement: .upper,
                style: .impact,
                density: .more
            ),
            takeLanguageOverrides: [fixture.secondTakeID: "de-DE"]
        )

        XCTAssertEqual(regenerated.pictureLock?.id, lockID)
        XCTAssertEqual(regenerated.projectCaptionTrack?.pictureLockID, lockID)
        XCTAssertEqual(regenerated.projectCaptionTrack?.regions.map(\.localeIdentifier), ["en-US", "de-DE"])
        XCTAssertEqual(regenerated.projectCaptionTrack?.cues, [])
        XCTAssertEqual(regenerated.captionConfiguration?.placement, .upper)
        XCTAssertEqual(regenerated.captionConfiguration?.style, .impact)
        XCTAssertEqual(regenerated.captionConfiguration?.density, .more)
    }

    func testPictureLockRejectsStructuralTimelineMutationAndNewTake() async throws {
        let fixture = try makeProjectWithTwoTakes()
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        let clipID = try XCTUnwrap(locked.primaryStoryline.clips.first?.id)
        let editor = TimelineEditor(projectID: fixture.project.id, projectStore: fixture.store)

        do {
            _ = try await editor.perform(
                .remove(clipID: clipID),
                expectedRevision: locked.primaryStoryline.revision
            )
            XCTFail("Expected the Picture Lock to block Storyline editing")
        } catch {
            XCTAssertEqual(error as? TimelineEditorError, .pictureLocked)
        }

        let thirdID = UUID()
        XCTAssertThrowsError(try fixture.store.addTake(
            projectID: fixture.project.id,
            takeID: thirdID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 4,
            createdAt: Date()
        )) { error in
            XCTAssertEqual(error as? ProjectStoreError, .pictureLocked)
        }
        XCTAssertEqual(try fixture.store.load(id: fixture.project.id).takes.count, 2)
    }

    func testReviewCannotCompleteUntilEveryRegionIsCheckpointed() throws {
        let fixture = try makeProjectWithTwoTakes()
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )

        XCTAssertThrowsError(try fixture.store.approveProjectCaptionTrack(
            projectID: fixture.project.id
        )) { error in
            XCTAssertEqual(error as? ProjectStoreError, .incompleteProjectCaptions)
        }

        for region in try XCTUnwrap(locked.projectCaptionTrack).regions {
            _ = try fixture.store.recordProjectCaptionRegion(
                projectID: fixture.project.id,
                regionID: region.id,
                draft: TakeCaptionTrack(
                    localeIdentifier: region.localeIdentifier,
                    sourceRange: region.sourceRange,
                    recognizer: .speechRecognizerIOS18,
                    reviewState: .needsReview,
                    cues: []
                )
            )
        }

        let approved = try fixture.store.approveProjectCaptionTrack(projectID: fixture.project.id)
        XCTAssertEqual(approved.projectCaptionTrack?.reviewState, .approved)
    }

    func testApprovedTrackRejectsAStyleThatWouldNoLongerFit() throws {
        let fixture = try makeProjectWithTwoTakes()
        let clean = ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
        var customization = CaptionStyleCustomization()
        customization.fontDesign = .serif
        customization.fontScale = .large
        let largeSerif = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower,
            style: .custom,
            customization: customization
        )
        let canvas = CGSize(width: 1080, height: 1920)
        let text = try XCTUnwrap((2...40)
            .map { Array(repeating: "caption", count: $0).joined(separator: " ") }
            .first {
                CaptionLineComposer.fits($0, configuration: clean, canvas: canvas)
                    && !CaptionLineComposer.fits($0, configuration: largeSerif, canvas: canvas)
            })
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: clean
        )
        for region in try XCTUnwrap(locked.projectCaptionTrack).regions {
            _ = try fixture.store.recordProjectCaptionRegion(
                projectID: fixture.project.id,
                regionID: region.id,
                draft: TakeCaptionTrack(
                    localeIdentifier: region.localeIdentifier,
                    sourceRange: region.sourceRange,
                    recognizer: .speechRecognizerIOS18,
                    reviewState: .needsReview,
                    cues: []
                )
            )
        }
        _ = try fixture.store.saveProjectCaptionCues(
            projectID: fixture.project.id,
            cues: [CaptionCue(
                range: TakeRange(startSeconds: 0, endSeconds: 2),
                recognizedText: text,
                text: text,
                confidence: 0.9,
                alternatives: [],
                timedSpans: []
            )]
        )
        _ = try fixture.store.approveProjectCaptionTrack(projectID: fixture.project.id)

        XCTAssertThrowsError(try fixture.store.updateProjectCaptionPresentation(
            projectID: fixture.project.id,
            configuration: largeSerif
        )) { error in
            XCTAssertEqual(error as? ProjectStoreError, .invalidProjectCaptionTrack)
        }
        let unchanged = try fixture.store.load(id: fixture.project.id)
        XCTAssertEqual(unchanged.projectCaptionTrack?.reviewState, .approved)
        XCTAssertEqual(unchanged.captionConfiguration, clean)
    }

    func testApprovedProjectTimeTrackFeedsLockedSnapshotWithoutTakeProjection() async throws {
        let fixture = try makeProjectWithTwoTakes()
        let locked = try fixture.store.createPictureLock(
            projectID: fixture.project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .upper)
        )
        for (index, region) in try XCTUnwrap(locked.projectCaptionTrack).regions.enumerated() {
            let cue = CaptionCue(
                range: TakeRange(
                    startSeconds: region.sourceRange.start.seconds + 0.5,
                    endSeconds: region.sourceRange.start.seconds + 1.5
                ),
                recognizedText: "Cue \(index + 1)",
                text: "Cue \(index + 1)",
                confidence: 0.9,
                alternatives: [],
                timedSpans: []
            )
            _ = try fixture.store.recordProjectCaptionRegion(
                projectID: fixture.project.id,
                regionID: region.id,
                draft: TakeCaptionTrack(
                    localeIdentifier: region.localeIdentifier,
                    sourceRange: region.sourceRange,
                    recognizer: .speechRecognizerIOS18,
                    reviewState: .needsReview,
                    cues: [cue]
                )
            )
        }
        _ = try fixture.store.approveProjectCaptionTrack(projectID: fixture.project.id)

        let snapshot = try await TimelineEditor(
            projectID: fixture.project.id,
            projectStore: fixture.store
        ).snapshot()

        XCTAssertEqual(snapshot.captionTimeline?.placement, .upper)
        XCTAssertEqual(snapshot.captionTimeline?.cues.map(\.range), [
            TakeRange(startSeconds: 0.5, endSeconds: 1.5),
            TakeRange(startSeconds: 5.5, endSeconds: 6.5)
        ])
        XCTAssertEqual(snapshot.clips.map(\.id), locked.pictureLock?.clips.map(\.id))
    }

    private func makeProjectWithTwoTakes() throws -> (
        store: ProjectStore,
        project: ProjectManifest,
        firstTakeID: UUID,
        secondTakeID: UUID
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 1))
        let firstTakeID = UUID()
        let secondTakeID = UUID()
        _ = try store.addTake(
            projectID: project.id,
            takeID: firstTakeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 5,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        _ = try store.addTake(
            projectID: project.id,
            takeID: secondTakeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 7,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        _ = try store.setTrimDecision(
            projectID: project.id,
            takeID: firstTakeID,
            decision: .keepOriginal
        )
        _ = try store.setTrimDecision(
            projectID: project.id,
            takeID: secondTakeID,
            decision: .keepOriginal
        )
        _ = try store.markStorylineChecked(projectID: project.id)
        return (store, project, firstTakeID, secondTakeID)
    }

    private func makeMovie() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try? Data("movie".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

}
