import XCTest
@testable import Camenya

final class CaptionPersistenceTests: XCTestCase {
    func testNormalTranscriptionPreservesApprovedCaptionsButIncludesMissingAndOutdatedTakes() {
        let configuration = ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        let approved = makeSelectionTake(locale: "it-IT", state: .approved)
        let missing = ProjectTake(createdAt: Date(), duration: 10)
        let stale = makeSelectionTake(locale: "it-IT", state: .stale)

        let ids = CaptionTranscriptionSelection.takeIDs(
            from: [approved, missing, stale],
            configuration: configuration,
            scope: .missingOrOutdated
        )

        XCTAssertEqual(ids, [missing.id, stale.id])
    }

    func testLanguageChangeAndExplicitRegenerationCanReplaceEveryCaptionTrack() {
        let takes = [
            makeSelectionTake(locale: "it-IT", state: .approved),
            makeSelectionTake(locale: "it-IT", state: .needsReview)
        ]
        let english = ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)

        XCTAssertEqual(
            CaptionTranscriptionSelection.takeIDs(
                from: takes,
                configuration: english,
                scope: .missingOrOutdated
            ),
            takes.map(\.id)
        )
        XCTAssertEqual(
            CaptionTranscriptionSelection.takeIDs(
                from: takes,
                configuration: english,
                scope: .all
            ),
            takes.map(\.id)
        )
    }

    func testCaptionConfigurationWithoutStyleMigratesToHighContrast() throws {
        let data = try XCTUnwrap(#"{"localeIdentifier":"it-IT","placement":"lower"}"#.data(using: .utf8))

        let configuration = try JSONDecoder().decode(ProjectCaptionConfiguration.self, from: data)

        XCTAssertEqual(configuration.style, .highContrast)
    }

    func testProjectLocaleAndTimedCaptionDraftPersistWithoutChangingTheTake() throws {
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
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: "it-IT",
            placement: .lower
        )
        let draft = TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 10),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [CaptionCue(
                range: TakeRange(startSeconds: 1, endSeconds: 3),
                recognizedText: "Ciao mondo",
                text: "Ciao mondo",
                confidence: 0.82,
                alternatives: ["Ciao, mondo"],
                timedSpans: [CaptionTimedSpan(
                    range: TakeRange(startSeconds: 1, endSeconds: 3),
                    text: "Ciao mondo",
                    granularity: .segment,
                    confidence: 0.82
                )]
            )]
        )

        _ = try store.setCaptionConfiguration(projectID: project.id, configuration: configuration)
        let updated = try store.recordCaptionDraft(projectID: project.id, takeID: takeID, draft: draft)
        let reloaded = try store.load(id: project.id)

        XCTAssertEqual(updated.captionConfiguration, configuration)
        XCTAssertEqual(reloaded.takes.first?.captions, draft)
        XCTAssertEqual(reloaded.takes.first?.duration, 10)
        XCTAssertEqual(
            try Data(contentsOf: store.takeMovieURL(projectID: project.id, takeID: takeID)),
            Data("movie".utf8)
        )
    }

    func testGeneratedCaptionDraftPersistsWhenTakeDurationRoundsUpToMediaTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        let withTake = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: makeMovie(),
            orientation: .portrait,
            duration: 12.9992,
            createdAt: Date()
        )
        _ = try store.setCaptionConfiguration(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        let sourceRange = try XCTUnwrap(withTake.takes.first?.concreteEffectiveRange)
        XCTAssertEqual(sourceRange.end.seconds, 13)
        let draft = TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: sourceRange,
            recognizer: .speechAnalyzerIOS26,
            reviewState: .needsReview,
            cues: [CaptionCue(
                range: TakeRange(startSeconds: 0.5, endSeconds: 1.5),
                recognizedText: "Ciao",
                text: "Ciao",
                confidence: 0.9,
                alternatives: [],
                timedSpans: []
            )]
        )

        _ = try store.recordCaptionDraft(
            projectID: project.id,
            takeID: takeID,
            draft: draft
        )

        XCTAssertEqual(try store.load(id: project.id).takes.first?.captions, draft)
    }

    func testCaptionDraftStillRejectsSourceRangeOneMediaTimeTickBeyondTake() throws {
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
            duration: 12.9992,
            createdAt: Date()
        )
        _ = try store.setCaptionConfiguration(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        let outsideDraft = TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(
                start: MediaTime(value: 0, timescale: 600),
                end: MediaTime(value: 7_801, timescale: 600)
            ),
            recognizer: .speechAnalyzerIOS26,
            reviewState: .needsReview,
            cues: []
        )

        XCTAssertThrowsError(try store.recordCaptionDraft(
            projectID: project.id,
            takeID: takeID,
            draft: outsideDraft
        )) { error in
            XCTAssertEqual(error as? ProjectStoreError, .invalidCaptionRange(takeID))
        }
    }

    func testCaptionDraftRejectsCoarseTimescaleRangeBeyondPersistedTakeEnd() throws {
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
            duration: 12.6,
            createdAt: Date()
        )
        _ = try store.setCaptionConfiguration(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        let outsideDraft = TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(
                start: MediaTime(value: 0, timescale: 1),
                end: MediaTime(value: 13, timescale: 1)
            ),
            recognizer: .speechAnalyzerIOS26,
            reviewState: .needsReview,
            cues: []
        )

        XCTAssertThrowsError(try store.recordCaptionDraft(
            projectID: project.id,
            takeID: takeID,
            draft: outsideDraft
        )) { error in
            XCTAssertEqual(error as? ProjectStoreError, .invalidCaptionRange(takeID))
        }
    }

    func testOnlyApprovedCaptionsEnterTheImmutableExportPlan() throws {
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
        let configuration = ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        let cue = CaptionCue(
            range: TakeRange(startSeconds: 1, endSeconds: 3),
            recognizedText: "Ciao mondo",
            text: "Ciao mondo",
            confidence: 0.82,
            alternatives: [],
            timedSpans: []
        )
        let draft = TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 10),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [cue]
        )
        _ = try store.setCaptionConfiguration(projectID: project.id, configuration: configuration)
        let withDraft = try store.recordCaptionDraft(projectID: project.id, takeID: takeID, draft: draft)

        let unreviewedPlan = try ProjectExportPlan.make(project: withDraft, store: store)
        XCTAssertNil(unreviewedPlan.sources.first?.captions)

        let approved = try store.approveCaptions(projectID: project.id, takeID: takeID)
        let approvedPlan = try ProjectExportPlan.make(project: approved, store: store)

        XCTAssertEqual(approvedPlan.captionConfiguration, configuration)
        XCTAssertEqual(approvedPlan.sources.first?.captions?.reviewState, .approved)
        XCTAssertEqual(approvedPlan.sources.first?.captions?.cues, [cue])
    }

    func testDraftCannotInjectApprovalAtThePersistenceBoundary() throws {
        let fixture = try makeCaptionedProject(
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 10)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var injected = try XCTUnwrap(
            fixture.store.load(id: fixture.projectID).takes.first?.captions
        )
        injected.reviewState = .approved

        let saved = try fixture.store.recordCaptionDraft(
            projectID: fixture.projectID,
            takeID: fixture.takeID,
            draft: injected
        )

        XCTAssertEqual(saved.takes.first?.captions?.reviewState, .needsReview)
        XCTAssertNil(try ProjectExportPlan.make(project: saved, store: fixture.store).sources.first?.captions)
    }

    func testLocaleStaleTrackCannotBeReapprovedOrExported() throws {
        let fixture = try makeCaptionedProject(
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 10)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let changed = try fixture.store.setCaptionConfiguration(
            projectID: fixture.projectID,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
        )

        XCTAssertThrowsError(try fixture.store.approveCaptions(
            projectID: fixture.projectID,
            takeID: fixture.takeID
        ))
        XCTAssertNil(try ProjectExportPlan.make(project: changed, store: fixture.store).sources.first?.captions)
    }

    func testChangingTheEffectiveRangeMakesApprovedCaptionsStale() throws {
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
        _ = try store.setCaptionConfiguration(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        _ = try store.recordCaptionDraft(
            projectID: project.id,
            takeID: takeID,
            draft: TakeCaptionTrack(
                localeIdentifier: "it-IT",
                sourceRange: TakeRange(startSeconds: 0, endSeconds: 10),
                recognizer: .speechRecognizerIOS18,
                reviewState: .needsReview,
                cues: [CaptionCue(
                    range: TakeRange(startSeconds: 1, endSeconds: 3),
                    recognizedText: "Ciao",
                    text: "Ciao",
                    confidence: nil,
                    alternatives: [],
                    timedSpans: []
                )]
            )
        )
        _ = try store.approveCaptions(projectID: project.id, takeID: takeID)

        let trimmed = try store.setTrimDecision(
            projectID: project.id,
            takeID: takeID,
            decision: .useSelection(TakeRange(startSeconds: 2, endSeconds: 8))
        )
        let exportPlan = try ProjectExportPlan.make(project: trimmed, store: store)

        XCTAssertEqual(trimmed.takes.first?.captions?.reviewState, .stale)
        XCTAssertNil(exportPlan.sources.first?.captions)
    }

    func testResettingTrimMakesCaptionsForTheTrimmedRangeStale() throws {
        let fixture = try makeCaptionedProject(
            sourceRange: TakeRange(startSeconds: 2, endSeconds: 8),
            trimDecision: .useSelection(TakeRange(startSeconds: 2, endSeconds: 8))
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let reset = try fixture.store.resetTrim(
            projectID: fixture.projectID,
            takeID: fixture.takeID
        )

        XCTAssertEqual(reset.takes.first?.captions?.reviewState, .stale)
        XCTAssertNil(try ProjectExportPlan.make(project: reset, store: fixture.store).sources.first?.captions)
    }

    func testChangingCaptionLanguageMakesExistingTracksStale() throws {
        let fixture = try makeCaptionedProject(
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 10)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let changed = try fixture.store.setCaptionConfiguration(
            projectID: fixture.projectID,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
        )

        XCTAssertEqual(changed.takes.first?.captions?.reviewState, .stale)
        XCTAssertNil(try ProjectExportPlan.make(project: changed, store: fixture.store).sources.first?.captions)
    }

    func testCaptionDraftRejectsOverlappingCuesAndOutOfRangeTimedSpans() throws {
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
        _ = try store.setCaptionConfiguration(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        let invalid = TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 10),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [
                CaptionCue(
                    range: TakeRange(startSeconds: 1, endSeconds: 3),
                    recognizedText: "Prima",
                    text: "Prima",
                    confidence: nil,
                    alternatives: [],
                    timedSpans: [CaptionTimedSpan(
                        range: TakeRange(startSeconds: 0.5, endSeconds: 1.5),
                        text: "Prima",
                        granularity: .word,
                        confidence: nil
                    )]
                ),
                CaptionCue(
                    range: TakeRange(startSeconds: 2.5, endSeconds: 4),
                    recognizedText: "Seconda",
                    text: "Seconda",
                    confidence: nil,
                    alternatives: [],
                    timedSpans: []
                )
            ]
        )

        XCTAssertThrowsError(try store.recordCaptionDraft(
            projectID: project.id,
            takeID: takeID,
            draft: invalid
        ))
    }

    private func makeCaptionedProject(
        sourceRange: TakeRange,
        trimDecision: TrimReviewDecision? = nil
    ) throws -> (root: URL, store: ProjectStore, projectID: UUID, takeID: UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        if let trimDecision {
            _ = try store.setTrimDecision(projectID: project.id, takeID: takeID, decision: trimDecision)
        }
        _ = try store.setCaptionConfiguration(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        _ = try store.recordCaptionDraft(
            projectID: project.id,
            takeID: takeID,
            draft: TakeCaptionTrack(
                localeIdentifier: "it-IT",
                sourceRange: sourceRange,
                recognizer: .speechRecognizerIOS18,
                reviewState: .needsReview,
                cues: [CaptionCue(
                    range: TakeRange(startSeconds: sourceRange.start.seconds + 0.5, endSeconds: sourceRange.start.seconds + 1.5),
                    recognizedText: "Ciao",
                    text: "Ciao",
                    confidence: nil,
                    alternatives: [],
                    timedSpans: []
                )]
            )
        )
        _ = try store.approveCaptions(projectID: project.id, takeID: takeID)
        return (root, store, project.id, takeID)
    }

    private func makeSelectionTake(
        locale: String,
        state: CaptionReviewState
    ) -> ProjectTake {
        ProjectTake(
            createdAt: Date(),
            duration: 10,
            captions: TakeCaptionTrack(
                localeIdentifier: locale,
                sourceRange: TakeRange(startSeconds: 0, endSeconds: 10),
                recognizer: .speechRecognizerIOS18,
                reviewState: state,
                cues: []
            )
        )
    }

    private func makeMovie() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data("movie".utf8).write(to: url)
        return url
    }
}
