import XCTest
@testable import Camenya

final class TimelineTakePositionPresentationTests: XCTestCase {
    func testPresentationFormatsOneBasedPositionLabel() {
        let presentation = TimelineTakePositionPresentation(currentIndex: 2, totalCount: 5)

        XCTAssertEqual(presentation.positionLabel, "Take 2 of 5")
        XCTAssertEqual(presentation.accessibilityLabel, "Timeline playback position")
        XCTAssertEqual(presentation.accessibilityValue, "Playing Take 2 of 5")
    }

    func testEmptyPresentationWhenQueueIsNotReady() {
        let presentation = TimelineTakePositionPresentation(currentIndex: 0, totalCount: 5)

        XCTAssertEqual(presentation.positionLabel, "")
        XCTAssertEqual(presentation.accessibilityValue, "No Take is playing")
    }
}
