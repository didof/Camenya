import XCTest
@testable import Camenya

final class CaptionEditorStateTests: XCTestCase {
    func testNudgeMovesCueStartEarlierByExactlyOneTenth() throws {
        let cueID = UUID()
        var editor = makeNudgeEditor(cueID: cueID)

        try editor.nudge(cueID: cueID, boundary: .start, direction: .earlier)

        XCTAssertEqual(editor.track.cues[0].range.start.seconds, 0.9, accuracy: 0.001)
    }

    func testNudgeMovesCueStartLaterByExactlyOneTenth() throws {
        let cueID = UUID()
        var editor = makeNudgeEditor(cueID: cueID)

        try editor.nudge(cueID: cueID, boundary: .start, direction: .later)

        XCTAssertEqual(editor.track.cues[0].range.start.seconds, 1.1, accuracy: 0.001)
    }

    func testNudgeMovesCueEndEarlierByExactlyOneTenth() throws {
        let cueID = UUID()
        var editor = makeNudgeEditor(cueID: cueID)

        try editor.nudge(cueID: cueID, boundary: .end, direction: .earlier)

        XCTAssertEqual(editor.track.cues[0].range.end.seconds, 2.9, accuracy: 0.001)
    }

    func testNudgeMovesCueEndLaterByExactlyOneTenth() throws {
        let cueID = UUID()
        var editor = makeNudgeEditor(cueID: cueID)

        try editor.nudge(cueID: cueID, boundary: .end, direction: .later)

        XCTAssertEqual(editor.track.cues[0].range.end.seconds, 3.1, accuracy: 0.001)
    }

    func testRepeatedCueNudgesRemainTenthSecondSteps() throws {
        let cueID = UUID()
        var editor = makeNudgeEditor(cueID: cueID)

        try editor.nudge(cueID: cueID, boundary: .start, direction: .later)
        try editor.nudge(cueID: cueID, boundary: .start, direction: .later)
        try editor.nudge(cueID: cueID, boundary: .start, direction: .later)

        XCTAssertEqual(editor.track.cues[0].range.start.seconds, 1.3, accuracy: 0.001)
    }

    func testCueNudgesStopAtTheSourceBoundaries() throws {
        let cueID = UUID()
        let editor = makeNudgeEditor(
            cueID: cueID,
            range: TakeRange(startSeconds: 0, endSeconds: 5)
        )

        XCTAssertNil(try editor.rangeAfterNudge(cueID: cueID, boundary: .start, direction: .earlier))
        XCTAssertNil(try editor.rangeAfterNudge(cueID: cueID, boundary: .end, direction: .later))
    }

    func testCueNudgesStopAtAdjacentCueBoundaries() throws {
        let targetID = UUID()
        let editor = CaptionEditorState(track: TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 5),
            recognizer: .speechRecognizerIOS18,
            reviewState: .approved,
            cues: [
                makeCue(range: TakeRange(startSeconds: 0, endSeconds: 1)),
                makeCue(id: targetID, range: TakeRange(startSeconds: 1, endSeconds: 3)),
                makeCue(range: TakeRange(startSeconds: 3, endSeconds: 5))
            ]
        ))

        XCTAssertNil(try editor.rangeAfterNudge(cueID: targetID, boundary: .start, direction: .earlier))
        XCTAssertNil(try editor.rangeAfterNudge(cueID: targetID, boundary: .end, direction: .later))
    }

    func testCueNudgesPreserveTheMinimumDuration() throws {
        let cueID = UUID()
        let editor = makeNudgeEditor(
            cueID: cueID,
            range: TakeRange(startSeconds: 1, endSeconds: 1.1)
        )

        XCTAssertNil(try editor.rangeAfterNudge(cueID: cueID, boundary: .start, direction: .later))
        XCTAssertNil(try editor.rangeAfterNudge(cueID: cueID, boundary: .end, direction: .earlier))
    }

    func testSuccessfulCueNudgeMarksTheTrackAsNeedingReview() throws {
        let cueID = UUID()
        var editor = makeNudgeEditor(cueID: cueID)

        try editor.nudge(cueID: cueID, boundary: .start, direction: .earlier)

        XCTAssertEqual(editor.track.reviewState, .needsReview)
    }

    func testDraftCheckpointTracksOnlyChangesAfterTheLastSuccessfulSave() {
        let cueID = UUID()
        let track = TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 2),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [CaptionCue(
                id: cueID,
                range: TakeRange(startSeconds: 0, endSeconds: 2),
                recognizedText: "Ciao",
                text: "Ciao",
                confidence: 0.8,
                alternatives: [],
                timedSpans: []
            )]
        )
        var editor = CaptionEditorState(track: track)
        var checkpoint = CaptionDraftCheckpoint(track: track)

        XCTAssertFalse(checkpoint.hasUnsavedChanges(in: editor.track))
        editor.updateText(cueID: cueID, text: "Ciao Camenya")
        XCTAssertTrue(checkpoint.hasUnsavedChanges(in: editor.track))

        checkpoint.markSaved(editor.track)
        XCTAssertFalse(checkpoint.hasUnsavedChanges(in: editor.track))
    }

    func testEditingTextFallsBackToCueTimingAndRestoreRecoversWordTiming() throws {
        let cueID = UUID()
        var editor = CaptionEditorState(track: TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 4),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [CaptionCue(
                id: cueID,
                range: TakeRange(startSeconds: 0, endSeconds: 2),
                recognizedText: "Ciao mondo",
                text: "Ciao mondo",
                confidence: 0.8,
                alternatives: [],
                timedSpans: [
                    CaptionTimedSpan(
                        range: TakeRange(startSeconds: 0, endSeconds: 0.8),
                        text: "Ciao",
                        granularity: .word,
                        confidence: 0.9
                    ),
                    CaptionTimedSpan(
                        range: TakeRange(startSeconds: 1, endSeconds: 2),
                        text: "mondo",
                        granularity: .word,
                        confidence: 0.7
                    )
                ]
            )]
        ))

        editor.updateText(cueID: cueID, text: "Ciao Camenya")

        XCTAssertNil(CaptionOverlayResolver.active(in: editor.track, at: 0.5)?.timedSpan)
        XCTAssertEqual(CaptionOverlayResolver.active(in: editor.track, at: 0.5)?.cue.text, "Ciao Camenya")

        try editor.restore(cueID: cueID)

        XCTAssertEqual(editor.track.cues.first?.text, "Ciao mondo")
        XCTAssertEqual(CaptionOverlayResolver.active(in: editor.track, at: 0.5)?.timedSpan?.text, "Ciao")
    }

    func testCueCanBeSplitAndMergedWithoutLeavingTheSourceRange() throws {
        let cueID = UUID()
        var editor = CaptionEditorState(track: TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 4),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [CaptionCue(
                id: cueID,
                range: TakeRange(startSeconds: 0, endSeconds: 4),
                recognizedText: "Una frase breve",
                text: "Una frase breve",
                confidence: nil,
                alternatives: [],
                timedSpans: []
            )]
        ))

        try editor.split(cueID: cueID)

        XCTAssertEqual(editor.track.cues.map(\.text), ["Una frase", "breve"])
        XCTAssertEqual(editor.track.cues.map(\.range), [
            TakeRange(startSeconds: 0, endSeconds: 2),
            TakeRange(startSeconds: 2, endSeconds: 4)
        ])

        try editor.mergeWithNext(cueID: editor.track.cues[0].id)

        XCTAssertEqual(editor.track.cues.map(\.text), ["Una frase breve"])
        XCTAssertEqual(editor.track.cues.first?.range, TakeRange(startSeconds: 0, endSeconds: 4))
    }

    func testSplittingEditedTextDoesNotClaimRecognizerWordTiming() throws {
        let cueID = UUID()
        var editor = CaptionEditorState(track: TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 4),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [CaptionCue(
                id: cueID,
                range: TakeRange(startSeconds: 0, endSeconds: 4),
                recognizedText: "Una frase breve",
                text: "Una frase breve",
                confidence: nil,
                alternatives: [],
                timedSpans: [CaptionTimedSpan(
                    range: TakeRange(startSeconds: 0, endSeconds: 1),
                    text: "Una",
                    granularity: .word,
                    confidence: nil
                )]
            )]
        ))
        editor.updateText(cueID: cueID, text: "Testo corretto qui")

        try editor.split(cueID: cueID)

        XCTAssertTrue(editor.track.cues.allSatisfy { $0.timedSpans.isEmpty })
    }

    func testTimingEditCannotOverlapTheNextCue() throws {
        let firstID = UUID()
        var editor = CaptionEditorState(track: TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 5),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [
                CaptionCue(
                    id: firstID,
                    range: TakeRange(startSeconds: 1, endSeconds: 2),
                    recognizedText: "Prima",
                    text: "Prima",
                    confidence: nil,
                    alternatives: [],
                    timedSpans: []
                ),
                CaptionCue(
                    range: TakeRange(startSeconds: 3, endSeconds: 4),
                    recognizedText: "Dopo",
                    text: "Dopo",
                    confidence: nil,
                    alternatives: [],
                    timedSpans: []
                )
            ]
        ))

        XCTAssertThrowsError(try editor.updateRange(
            cueID: firstID,
            range: TakeRange(startSeconds: 1, endSeconds: 3.2)
        ))
    }

    func testSpanAlternativeTargetsTheSelectedRepeatedOccurrence() throws {
        let cueID = UUID()
        let secondRange = TakeRange(startSeconds: 1, endSeconds: 2)
        var editor = CaptionEditorState(track: TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 3),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [CaptionCue(
                id: cueID,
                range: TakeRange(startSeconds: 0, endSeconds: 2),
                recognizedText: "go go",
                text: "go go",
                confidence: nil,
                alternatives: [],
                timedSpans: [
                    CaptionTimedSpan(
                        range: TakeRange(startSeconds: 0, endSeconds: 1),
                        text: "go",
                        granularity: .word,
                        confidence: nil,
                        alternatives: ["no"]
                    ),
                    CaptionTimedSpan(
                        range: secondRange,
                        text: "go",
                        granularity: .word,
                        confidence: nil,
                        alternatives: ["slow"]
                    )
                ]
            )]
        ))

        editor.applyAlternative(cueID: cueID, spanRange: secondRange, alternative: "slow")

        XCTAssertEqual(editor.track.cues.first?.text, "go slow")
    }

    func testNextUncertainCueAdvancesAndWraps() {
        let firstID = UUID()
        let certainID = UUID()
        let lastID = UUID()
        let editor = CaptionEditorState(track: TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 6),
            recognizer: .speechRecognizerIOS18,
            reviewState: .needsReview,
            cues: [
                CaptionCue(
                    id: firstID,
                    range: TakeRange(startSeconds: 0, endSeconds: 1),
                    recognizedText: "Forse",
                    text: "Forse",
                    confidence: 0.4,
                    alternatives: [],
                    timedSpans: []
                ),
                CaptionCue(
                    id: certainID,
                    range: TakeRange(startSeconds: 2, endSeconds: 3),
                    recognizedText: "Certo",
                    text: "Certo",
                    confidence: 0.9,
                    alternatives: [],
                    timedSpans: []
                ),
                CaptionCue(
                    id: lastID,
                    range: TakeRange(startSeconds: 4, endSeconds: 5),
                    recognizedText: "Controlla",
                    text: "Controlla",
                    confidence: 0.5,
                    alternatives: [],
                    timedSpans: []
                )
            ]
        ))

        XCTAssertEqual(editor.uncertainCueIDs, [firstID, lastID])
        XCTAssertEqual(editor.nextUncertainCue(after: firstID)?.id, lastID)
        XCTAssertEqual(editor.nextUncertainCue(after: lastID)?.id, firstID)
        XCTAssertEqual(editor.nextUncertainCue(after: certainID)?.id, lastID)
    }

    private func makeNudgeEditor(
        cueID: UUID,
        range: TakeRange = TakeRange(startSeconds: 1, endSeconds: 3)
    ) -> CaptionEditorState {
        CaptionEditorState(track: TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 5),
            recognizer: .speechRecognizerIOS18,
            reviewState: .approved,
            cues: [makeCue(id: cueID, range: range)]
        ))
    }

    private func makeCue(id: UUID = UUID(), range: TakeRange) -> CaptionCue {
        CaptionCue(
            id: id,
            range: range,
            recognizedText: "Ciao",
            text: "Ciao",
            confidence: nil,
            alternatives: [],
            timedSpans: []
        )
    }
}
