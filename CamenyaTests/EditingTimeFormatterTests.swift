import XCTest
@testable import Camenya

final class EditingTimeFormatterTests: XCTestCase {
    func testZeroShowsTenths() {
        XCTAssertEqual(RecordingDurationFormatter.editingClock(0), "00:00.0")
    }

    func testFractionalSecondsRoundToNearestTenth() {
        XCTAssertEqual(RecordingDurationFormatter.editingClock(3.04), "00:03.0")
    }

    func testMinutesAndTenthsAreDisplayedTogether() {
        XCTAssertEqual(RecordingDurationFormatter.editingClock(63.26), "01:03.3")
    }

    func testRoundingCarriesIntoTheNextMinute() {
        XCTAssertEqual(RecordingDurationFormatter.editingClock(59.96), "01:00.0")
    }

    func testNegativeInputFallsBackToZero() {
        XCTAssertEqual(RecordingDurationFormatter.editingClock(-1.23), "00:00.0")
    }

    func testNonFiniteInputFallsBackToZero() {
        XCTAssertEqual(RecordingDurationFormatter.editingClock(.infinity), "00:00.0")
    }

    func testWholeSecondClockRemainsUnchanged() {
        XCTAssertEqual(RecordingDurationFormatter.clock(63.26), "01:03")
    }
}
