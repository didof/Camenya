import XCTest
@testable import Camenya

final class CameraLifecyclePolicyTests: XCTestCase {
    func testForegroundSessionFailureIsUnexpected() {
        let policy = CameraLifecyclePolicy()

        XCTAssertEqual(policy.sessionFailureDisposition, .presentUnexpectedFailure)
    }

    func testSessionInterruptionWhileApplicationIsInactiveIsExpectedLifecycle() {
        var policy = CameraLifecyclePolicy()

        policy.applicationBecameInactive()

        XCTAssertEqual(policy.sessionFailureDisposition, .suppressExpectedLifecycle)
    }

    func testBecomingActiveKeepsFailuresSuppressedUntilRestorationCompletes() {
        var policy = CameraLifecyclePolicy()
        policy.applicationBecameInactive()
        policy.applicationEnteredBackground()

        _ = policy.applicationBecameActive()

        XCTAssertEqual(policy.sessionFailureDisposition, .suppressExpectedLifecycle)
    }

    func testUsableRestorationReturnsToForegroundFailureHandling() {
        var policy = CameraLifecyclePolicy()
        policy.applicationBecameInactive()
        policy.applicationEnteredBackground()
        let attempt = policy.applicationBecameActive()

        let result = policy.restorationCompleted(attempt, isUsable: true)

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(policy.sessionFailureDisposition, .presentUnexpectedFailure)
    }

    func testUnusableRestorationReturnsToForegroundFailureHandling() {
        var policy = CameraLifecyclePolicy()
        policy.applicationBecameInactive()
        policy.applicationEnteredBackground()
        let attempt = policy.applicationBecameActive()

        let result = policy.restorationCompleted(attempt, isUsable: false)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(policy.sessionFailureDisposition, .presentUnexpectedFailure)
    }

    func testInterruptionEndingInBackgroundDoesNotRequestSessionRestart() {
        var policy = CameraLifecyclePolicy()
        policy.applicationBecameInactive()
        policy.applicationEnteredBackground()

        XCTAssertFalse(policy.shouldRestartAfterInterruptionEnded)
    }

    func testInterruptionEndingDuringRestorationDoesNotStartCompetingRestart() {
        var policy = CameraLifecyclePolicy()
        policy.applicationBecameInactive()
        _ = policy.applicationBecameActive()

        XCTAssertFalse(policy.shouldRestartAfterInterruptionEnded)
    }

    func testRestorationCallbackIsIgnoredAfterApplicationLeavesForegroundAgain() {
        var policy = CameraLifecyclePolicy()
        policy.applicationBecameInactive()
        policy.applicationEnteredBackground()
        let attempt = policy.applicationBecameActive()

        policy.applicationBecameInactive()
        policy.applicationEnteredBackground()

        XCTAssertNil(policy.restorationCompleted(attempt, isUsable: true))
        XCTAssertEqual(policy.sessionFailureDisposition, .suppressExpectedLifecycle)
    }

    func testOnlyNewestRestorationAttemptCanComplete() {
        var policy = CameraLifecyclePolicy()
        policy.applicationBecameInactive()
        let earlierAttempt = policy.applicationBecameActive()
        let newestAttempt = policy.applicationBecameActive()

        XCTAssertNil(policy.restorationCompleted(earlierAttempt, isUsable: true))
        XCTAssertEqual(
            policy.restorationCompleted(newestAttempt, isUsable: true),
            .restored
        )
    }

    func testBackgroundingWhilePausedPreservesTakeState() {
        let policy = CameraLifecyclePolicy()

        XCTAssertEqual(
            policy.takeDispositionForBackground(activity: .paused),
            .preserveCurrentState
        )
    }

    func testBackgroundingAnActiveSegmentInterruptsTake() {
        let policy = CameraLifecyclePolicy()

        XCTAssertEqual(
            policy.takeDispositionForBackground(activity: .activeSegment),
            .interruptTake
        )
    }

    func testCameraOperationalStateExposesOnlyCompatiblePresentationValues() {
        XCTAssertTrue(CameraOperationalState.ready.isReady)
        XCTAssertFalse(CameraOperationalState.restoring.isReady)
        XCTAssertTrue(CameraOperationalState.restoring.isRestoring)
        XCTAssertEqual(
            CameraOperationalState.unavailable("Camera unavailable").recoveryMessage,
            "Camera unavailable"
        )
        XCTAssertNil(CameraOperationalState.suspended.recoveryMessage)
    }

    func testExpectedLifecycleFailurePreservesPausedTake() {
        var policy = CameraLifecyclePolicy()
        policy.applicationBecameInactive()

        XCTAssertEqual(
            policy.takeDispositionForSessionFailure(activity: .paused),
            .preserveCurrentState
        )
    }

    func testUnexpectedForegroundFailureInterruptsPausedTake() {
        let policy = CameraLifecyclePolicy()

        XCTAssertEqual(
            policy.takeDispositionForSessionFailure(activity: .paused),
            .interruptTake
        )
    }
}
