import XCTest
@testable import Camenya

final class SilenceTrimEditorStateTests: XCTestCase {
    func testSuggestionIsExpressedAsLeadingAndTrailingRemoval() {
        let suggestion = TakeRange(startSeconds: 1.25, endSeconds: 8.5)

        let state = SilenceTrimEditorState(duration: 10, suggestion: suggestion)

        XCTAssertEqual(state.leadingRemoval, 1.25, accuracy: 0.001)
        XCTAssertEqual(state.trailingRemoval, 1.5, accuracy: 0.001)
        XCTAssertEqual(state.keptDuration, 7.25, accuracy: 0.001)
        XCTAssertEqual(state.selection, suggestion)
    }

    func testAdjustmentsAlwaysKeepAtLeastOneSecond() {
        var state = SilenceTrimEditorState(
            duration: 10,
            suggestion: TakeRange(startSeconds: 1, endSeconds: 9)
        )

        state.setLeadingRemoval(9.8)
        state.setTrailingRemoval(9.8)

        XCTAssertGreaterThanOrEqual(state.keptDuration, 1)
        XCTAssertTrue(state.selection.isValid(inside: 10, minimumDuration: 1))
    }

    func testResetRestoresTheAnalyzerSuggestion() {
        let suggestion = TakeRange(startSeconds: 1, endSeconds: 8)
        var state = SilenceTrimEditorState(duration: 10, suggestion: suggestion)
        state.setLeadingRemoval(2)
        state.setTrailingRemoval(3)

        state.resetToSuggestion()

        XCTAssertEqual(state.selection, suggestion)
        XCTAssertFalse(state.hasManualChanges)
    }

    func testWaveformEndpointsClampAndKeepOneSecond() {
        var state = SilenceTrimEditorState(
            duration: 10,
            suggestion: TakeRange(startSeconds: 0, endSeconds: 10)
        )

        state.setSelectionStart(3.25)
        state.setSelectionEnd(3.5)

        XCTAssertEqual(state.selection.start.seconds, 3.25, accuracy: 0.001)
        XCTAssertEqual(state.selection.end.seconds, 4.25, accuracy: 0.001)
        XCTAssertEqual(state.keptDuration, 1, accuracy: 0.001)
    }

    func testExistingDecisionCanBeReopenedOverAnalyzerSuggestion() {
        let state = SilenceTrimEditorState(
            duration: 10,
            suggestion: TakeRange(startSeconds: 1, endSeconds: 9),
            selection: TakeRange(startSeconds: 2, endSeconds: 8)
        )

        XCTAssertEqual(state.selection, TakeRange(startSeconds: 2, endSeconds: 8))
        XCTAssertTrue(state.hasManualChanges)
    }
}
