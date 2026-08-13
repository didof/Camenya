import XCTest
@testable import Camenya

final class CameraControllerTests: XCTestCase {
    func testStartingAnUnconfiguredSessionReportsThatItIsNotUsable() async {
        let controller = CameraController()

        let isRunning = await withCheckedContinuation { continuation in
            controller.startSession { isRunning in
                continuation.resume(returning: isRunning)
            }
        }

        XCTAssertFalse(isRunning)
    }

    func testStoppingAnIdleSessionStillCompletesTheProjectExit() async {
        let controller = CameraController()

        await withCheckedContinuation { continuation in
            controller.stopSession { continuation.resume() }
        }
    }
}
