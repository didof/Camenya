import XCTest
@testable import Camenya

final class SilenceTrimPresentationTests: XCTestCase {
    func testNudgePresentationDescribesTheStepAndPreciseResult() {
        let editor = SilenceTrimEditorState(
            duration: 10,
            suggestion: TakeRange(startSeconds: 1, endSeconds: 9)
        )

        let presentation = SilenceTrimNudgePresentation(
            editor: editor,
            boundary: .start,
            direction: .earlier
        )

        XCTAssertEqual(presentation.title, "Earlier")
        XCTAssertEqual(presentation.accessibilityLabel, "Trim start earlier by 0.1 seconds")
        XCTAssertEqual(presentation.accessibilityValue, "Result 00:00.9")
        XCTAssertTrue(presentation.isEnabled)
    }

    func testUnavailableNudgePresentationExplainsTheCurrentBoundary() {
        let editor = SilenceTrimEditorState(
            duration: 10,
            suggestion: TakeRange(startSeconds: 0, endSeconds: 10)
        )

        let presentation = SilenceTrimNudgePresentation(
            editor: editor,
            boundary: .start,
            direction: .earlier
        )

        XCTAssertEqual(presentation.accessibilityValue, "Unavailable at 00:00.0")
        XCTAssertFalse(presentation.isEnabled)
    }

    func testAnalyzerSuggestionPresentationExplainsTheNonDestructiveResult() {
        let editor = SilenceTrimEditorState(
            duration: 10,
            suggestion: TakeRange(startSeconds: 1, endSeconds: 8)
        )

        let presentation = SilenceTrimPresentation(editor: editor)

        XCTAssertEqual(presentation.summaryTitle, "Suggested silence trim")
        XCTAssertEqual(presentation.keptDuration, "00:07.0")
        XCTAssertEqual(presentation.removedDuration, "00:03.0")
        XCTAssertFalse(presentation.showsResetAction)
        XCTAssertEqual(
            presentation.waveformAccessibilityValue,
            "Removes 00:01.0 from the beginning, removes 00:02.0 from the end, keeps 00:07.0"
        )
    }

    func testManualAdjustmentIsClearlyNamedAndOffersReset() {
        var editor = SilenceTrimEditorState(
            duration: 10,
            suggestion: TakeRange(startSeconds: 1, endSeconds: 8)
        )
        editor.setLeadingRemoval(2)

        let presentation = SilenceTrimPresentation(editor: editor)

        XCTAssertEqual(presentation.summaryTitle, "Custom silence trim")
        XCTAssertTrue(presentation.showsResetAction)
    }

    func testNoSuggestionStillExplainsTheFullTakeWaveform() {
        let editor = SilenceTrimEditorState(
            duration: 10,
            suggestion: TakeRange(startSeconds: 0, endSeconds: 10)
        )

        let presentation = SilenceTrimPresentation(
            editor: editor,
            suggestionWasDetected: false
        )

        XCTAssertEqual(presentation.summaryTitle, "No trim suggested")
        XCTAssertEqual(presentation.resetActionTitle, "Reset to Full Take")
        XCTAssertFalse(presentation.showsResetAction)
    }
}
