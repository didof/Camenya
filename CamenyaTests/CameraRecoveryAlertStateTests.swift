import XCTest
@testable import Camenya

final class CameraRecoveryAlertStateTests: XCTestCase {
    func testRecoveredCaptureSessionClearsItsStaleFailureAlert() {
        var state = CameraRecoveryAlertState()
        let alert = state.presentCaptureSessionFailure("Camera unavailable. Your recorded segments are safe.")
        let attempt = state.beginRecoveryAttempt()

        let recoveredAlert = state.recoveredAlert(
            attempt,
            ifPresentedAlertID: alert.id
        )

        XCTAssertEqual(recoveredAlert, alert)
        XCTAssertNil(state.alert)
    }

    func testRecoveredCaptureSessionPreservesANewerUnrelatedAlert() {
        var state = CameraRecoveryAlertState()
        _ = state.presentCaptureSessionFailure("Camera unavailable. Your recorded segments are safe.")
        let attempt = state.beginRecoveryAttempt()

        let recoveredAlert = state.recoveredAlert(
            attempt,
            ifPresentedAlertID: nil
        )

        XCTAssertNil(recoveredAlert)
        XCTAssertNil(state.alert)
    }

    func testEarlierRecoveryAttemptDoesNotClearANewerCameraFailure() {
        var state = CameraRecoveryAlertState()
        let earlierAttempt = state.beginRecoveryAttempt()
        let newerAlert = state.presentCaptureSessionFailure("The camera stopped unexpectedly.")

        let recoveredAlert = state.recoveredAlert(
            earlierAttempt,
            ifPresentedAlertID: newerAlert.id
        )

        XCTAssertNil(recoveredAlert)
        XCTAssertEqual(state.alert, newerAlert)
    }

    func testRepeatedFailureRecoveryCyclesDoNotAccumulateState() {
        var state = CameraRecoveryAlertState()

        for cycle in 1...3 {
            let alert = state.presentCaptureSessionFailure("Camera unavailable \(cycle)")
            let attempt = state.beginRecoveryAttempt()

            XCTAssertEqual(
                state.recoveredAlert(attempt, ifPresentedAlertID: alert.id),
                alert
            )
            XCTAssertNil(state.alert)
        }
    }
}
