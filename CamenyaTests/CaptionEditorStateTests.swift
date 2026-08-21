import XCTest
@testable import Camenya

final class CaptionEditorStateTests: XCTestCase {
    func testProjectCaptionSplitUsesRequestedTextBoundaryAndDropsUntrustworthyWordTiming() throws {
        let cue = CaptionCue(
            range: TakeRange(startSeconds: 1, endSeconds: 5),
            recognizedText: "one two three four",
            text: "one two three four",
            confidence: 0.9,
            alternatives: [],
            timedSpans: [CaptionTimedSpan(
                range: TakeRange(startSeconds: 1, endSeconds: 2),
                text: "one",
                granularity: .word,
                confidence: 0.9
            )]
        )
        var state = ProjectCaptionEditorState(duration: 8, cues: [cue])

        let selectedID = try XCTUnwrap(state.split(cueID: cue.id, characterOffset: 7))

        XCTAssertEqual(state.cues.map(\.text), ["one two", "three four"])
        XCTAssertTrue(state.cues.allSatisfy { $0.timedSpans.isEmpty })
        XCTAssertEqual(selectedID, state.cues.last?.id)
    }

    func testProjectCaptionAddUsesAvailableGapAndEditedCueSurvivesConfigurationChanges() throws {
        let edited = CaptionCue(
            range: TakeRange(startSeconds: 3, endSeconds: 5),
            recognizedText: "recognized",
            text: "manual correction",
            confidence: 0.5,
            alternatives: [],
            timedSpans: []
        )
        var state = ProjectCaptionEditorState(duration: 10, cues: [edited])

        let insertedID = try XCTUnwrap(state.addCaption(at: 1))

        XCTAssertEqual(state.cues.first?.id, insertedID)
        XCTAssertEqual(state.cues.first?.range, TakeRange(startSeconds: 1, endSeconds: 3))
        XCTAssertEqual(state.cues.last?.text, "manual correction")
    }

    func testDensityReflowNeverCrossesOrReplacesAManuallyEditedCue() {
        let before = makeWordTimedCue(words: ["one", "two", "three"], start: 0)
        let protected = CaptionCue(
            range: TakeRange(startSeconds: 3, endSeconds: 5),
            recognizedText: "old words",
            text: "my exact correction",
            confidence: 0.8,
            alternatives: [],
            timedSpans: []
        )
        let after = makeWordTimedCue(words: ["four", "five", "six", "seven", "eight"], start: 5)

        let reflowed = CaptionDensityReflow.apply(.less, to: [before, protected, after])

        XCTAssertEqual(reflowed.first?.text, "one two three")
        XCTAssertEqual(reflowed[1], protected)
        XCTAssertEqual(reflowed.dropFirst(2).map(\.text), ["four five six seven", "eight"])
    }

    func testDensityReflowDoesNotBridgeASpokenPause() {
        let before = makeWordTimedCue(words: ["one", "two"], start: 0)
        let after = makeWordTimedCue(words: ["three", "four"], start: 3)

        let reflowed = CaptionDensityReflow.apply(.less, to: [before, after])

        XCTAssertEqual(reflowed.map(\.text), ["one two", "three four"])
    }

    func testDensityReflowDoesNotCrossLanguageRegions() {
        let first = makeWordTimedCue(words: ["uno", "due"], start: 0)
        let second = makeWordTimedCue(words: ["three", "four"], start: 2)
        let firstLanguageRegionID = UUID()
        let secondLanguageRegionID = UUID()
        let regions = [
            ProjectCaptionRegion(
                languageRegionID: firstLanguageRegionID,
                clipID: TimelineClip.ID(),
                takeID: UUID(),
                sourceRange: TakeRange(startSeconds: 0, endSeconds: 2),
                projectTimeRange: ProjectTimeRange(
                    start: .zero,
                    end: ProjectTime(seconds: 2)
                ),
                localeIdentifier: "it-IT"
            ),
            ProjectCaptionRegion(
                languageRegionID: secondLanguageRegionID,
                clipID: TimelineClip.ID(),
                takeID: UUID(),
                sourceRange: TakeRange(startSeconds: 0, endSeconds: 2),
                projectTimeRange: ProjectTimeRange(
                    start: ProjectTime(seconds: 2),
                    end: ProjectTime(seconds: 4)
                ),
                localeIdentifier: "en-US"
            )
        ]

        let reflowed = CaptionDensityReflow.apply(.less, to: [first, second], regions: regions)

        XCTAssertEqual(reflowed.map { $0.text }, ["uno due", "three four"])
    }

    func testDensityReflowPrefersNaturalPunctuationNearTheWordTarget() {
        let cue = makeWordTimedCue(
            words: [
                "One", "clear", "idea", "ends", "here.",
                "Then", "another", "thought", "continues", "with", "useful", "detail."
            ],
            start: 0
        )

        let reflowed = CaptionDensityReflow.apply(.standard, to: [cue])

        XCTAssertEqual(reflowed.first?.text, "One clear idea ends here.")
        XCTAssertEqual(reflowed.flatMap(\.timedSpans), cue.timedSpans)
    }

    func testDensityReflowUsesCurrentPresentationFitAsAHardBoundary() {
        let cue = makeWordTimedCue(
            words: (0..<12).map { "substantialword\($0)" },
            start: 0
        )
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower,
            style: .custom,
            density: .more,
            customization: CaptionStyleCustomization(fontScale: .large)
        )

        let reflowed = CaptionDensityReflow.apply(
            .more,
            to: [cue],
            configuration: configuration,
            format: .portrait
        )

        XCTAssertTrue(reflowed.allSatisfy {
            CaptionLineComposer.fits(
                $0.text,
                configuration: configuration,
                canvas: CGSize(width: 1080, height: 1920)
            )
        })
        XCTAssertEqual(reflowed.flatMap(\.timedSpans), cue.timedSpans)
    }

    func testUndoAvailabilityIncludesTheCurrentUncommittedTextEdit() {
        let before = makeWordTimedCue(words: ["before"], start: 0)
        var after = before
        after.text = "after"

        XCTAssertTrue(CaptionEditorHistoryPolicy.canUndo(
            undoCount: 0,
            textBaseline: [before],
            currentCues: [after]
        ))
        XCTAssertFalse(CaptionEditorHistoryPolicy.canRedo(
            redoCount: 1,
            textBaseline: [before],
            currentCues: [after]
        ))
    }

    func testApplyDensityDoesNotAcceptUnrelatedStyleOrPositionDrafts() {
        let persisted = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower,
            style: .clean,
            density: .standard
        )
        let draft = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .upper,
            style: .impact,
            density: .more
        )

        let accepted = CaptionStyleDraftPolicy.densityOnlyConfiguration(
            draft: draft,
            persisted: persisted
        )

        XCTAssertEqual(accepted.density, .more)
        XCTAssertEqual(accepted.placement, .lower)
        XCTAssertEqual(accepted.style, .clean)
    }

    private func makeWordTimedCue(words: [String], start: TimeInterval) -> CaptionCue {
        let spans = words.enumerated().map { offset, word in
            CaptionTimedSpan(
                range: TakeRange(
                    startSeconds: start + Double(offset),
                    endSeconds: start + Double(offset + 1)
                ),
                text: word,
                granularity: .word,
                confidence: 0.9
            )
        }
        return CaptionCue(
            range: TakeRange(startSeconds: start, endSeconds: start + Double(words.count)),
            recognizedText: words.joined(separator: " "),
            text: words.joined(separator: " "),
            confidence: 0.9,
            alternatives: [],
            timedSpans: spans
        )
    }

    func testHistoryCoordinatorAnnouncesTheExactUndoAndRedoOperation() throws {
        let cue = makeWordTimedCue(words: ["keep", "this"], start: 0)
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower
        )
        var history = CaptionHistoryCoordinator()
        history.record(
            cues: [cue],
            configuration: configuration,
            operationName: "Delete Caption"
        )

        let undo = try XCTUnwrap(history.transition(
            isUndo: true,
            currentCues: [],
            currentConfiguration: configuration
        ))
        XCTAssertEqual(undo.announcement, "Undid Delete Caption")
        history.commit(undo)

        let redo = try XCTUnwrap(history.transition(
            isUndo: false,
            currentCues: [cue],
            currentConfiguration: configuration
        ))
        XCTAssertEqual(redo.announcement, "Redid Delete Caption")
    }

    func testFailedHistoryTransitionCannotRetryAfterTheEditorChanges() throws {
        let cue = makeWordTimedCue(words: ["keep", "this"], start: 0)
        var changed = cue
        changed.text = "keep this newer correction"
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower
        )
        var history = CaptionHistoryCoordinator()
        history.record(
            cues: [cue],
            configuration: configuration,
            operationName: "Delete Caption"
        )
        let transition = try XCTUnwrap(history.transition(
            isUndo: true,
            currentCues: [],
            currentConfiguration: configuration
        ))

        XCTAssertTrue(history.canApply(
            transition,
            currentCues: [],
            currentConfiguration: configuration
        ))
        XCTAssertFalse(history.canApply(
            transition,
            currentCues: [changed],
            currentConfiguration: configuration
        ))
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.redoCount, 0)
    }

    func testUndoingDensityAfterTextEditPreservesCommittedEditedText() throws {
        let original = makeWordTimedCue(words: ["original", "caption"], start: 0)
        var edited = original
        edited.text = "manually edited caption"
        let reflowed = CaptionCue(
            range: edited.range,
            recognizedRange: edited.recognizedRange,
            recognizedText: edited.recognizedText,
            text: "manually edited",
            confidence: edited.confidence,
            alternatives: edited.alternatives,
            timedSpans: edited.timedSpans
        )
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower
        )
        let denserConfiguration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower,
            density: .more
        )
        var history = CaptionHistoryCoordinator()
        history.record(
            cues: [original],
            configuration: configuration,
            operationName: "Edit Caption Text"
        )
        history.record(
            cues: [edited],
            configuration: configuration,
            operationName: "Apply Caption Density"
        )

        let undo = try XCTUnwrap(history.transition(
            isUndo: true,
            currentCues: [reflowed],
            currentConfiguration: denserConfiguration
        ))

        XCTAssertEqual(undo.target.cues, [edited])
        XCTAssertEqual(undo.target.cues.first?.text, "manually edited caption")
        XCTAssertEqual(undo.announcement, "Undid Apply Caption Density")
    }

    func testUndoingAddCaptionAfterTextEditPreservesCommittedEditedText() throws {
        let original = makeWordTimedCue(words: ["original", "caption"], start: 0)
        var edited = original
        edited.text = "manually edited caption"
        let added = makeWordTimedCue(words: ["new", "caption"], start: 3)
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower
        )
        var history = CaptionHistoryCoordinator()
        history.record(
            cues: [original],
            configuration: configuration,
            operationName: "Edit Caption Text"
        )
        history.record(
            cues: [edited],
            configuration: configuration,
            operationName: "Add Caption"
        )

        let undo = try XCTUnwrap(history.transition(
            isUndo: true,
            currentCues: [edited, added],
            currentConfiguration: configuration
        ))

        XCTAssertEqual(undo.target.cues, [edited])
        XCTAssertEqual(undo.target.cues.first?.text, "manually edited caption")
        XCTAssertEqual(undo.announcement, "Undid Add Caption")
    }

    func testDensityPreviewRegroupsCurrentUnsavedCuesBeforeApply() throws {
        let cue = makeWordTimedCue(
            words: ["one", "two", "three", "four", "five", "six", "seven", "eight"],
            start: 0
        )
        var edited = makeWordTimedCue(words: ["nine", "ten"], start: 8)
        edited.text = "manual ending"
        let less = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower,
            density: .less
        )
        let more = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower,
            density: .more
        )

        let lessPreview = try XCTUnwrap(CaptionDensityPreviewPolicy.cue(
            in: [cue, edited],
            preferredCueID: cue.id,
            regions: [],
            configuration: less,
            format: .portrait
        ))
        let morePreview = try XCTUnwrap(CaptionDensityPreviewPolicy.cue(
            in: [cue, edited],
            preferredCueID: cue.id,
            regions: [],
            configuration: more,
            format: .portrait
        ))

        XCTAssertNotEqual(lessPreview.text, morePreview.text)
        XCTAssertEqual(
            CaptionDensityPreviewPolicy.preservedEditedCueCount(in: [cue, edited]),
            1
        )
    }
}
