import XCTest
@testable import Camenya

final class LogicalRecordingTimerTests: XCTestCase {
    func testPausedWallClockTimeIsExcluded() {
        var timer = LogicalRecordingTimer()
        timer.completeSegment(duration: 12)
        XCTAssertEqual(timer.elapsed(activeSegmentDuration: 0), 12, accuracy: 0.001)
        timer.completeSegment(duration: 8)
        XCTAssertEqual(timer.elapsed(activeSegmentDuration: 0), 20, accuracy: 0.001)
    }

    func testActiveSegmentDurationIsAddedToCompletedSegments() {
        var timer = LogicalRecordingTimer()
        timer.completeSegment(duration: 12)
        XCTAssertEqual(timer.elapsed(activeSegmentDuration: 3.5), 15.5, accuracy: 0.001)
    }
}
