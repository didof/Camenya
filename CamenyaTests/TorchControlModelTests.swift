import XCTest
@testable import Camenya

final class TorchControlModelTests: XCTestCase {
    func testFrontCameraIsAlwaysUnavailable() {
        var state = TorchControlState(
            hardware: TorchHardwareContext(selectedCamera: .front, rearTorchSupported: true)
        )

        XCTAssertEqual(state.phase, .unavailable)
        XCTAssertEqual(TorchControlPresentation(state: state).accessibilityValue, "Unavailable")

        state.apply(.userToggleRequested)
        XCTAssertEqual(state.phase, .unavailable)
    }

    func testRearCameraWithoutTorchHardwareIsUnavailable() {
        let state = TorchControlState(
            hardware: TorchHardwareContext(selectedCamera: .rear, rearTorchSupported: false)
        )

        XCTAssertEqual(state.phase, .unavailable)
        XCTAssertFalse(TorchControlPresentation(state: state).isEnabled)
    }

    func testRearTorchCanToggleOffAndOn() {
        var state = TorchControlState(
            hardware: TorchHardwareContext(selectedCamera: .rear, rearTorchSupported: true)
        )

        XCTAssertEqual(state.phase, .off)
        state.apply(.userToggleRequested)
        XCTAssertEqual(state.phase, .on)
        XCTAssertEqual(TorchControlPresentation(state: state).label, "Torch On")

        state.apply(.userToggleRequested)
        XCTAssertEqual(state.phase, .off)
    }

    func testSwitchingToFrontCameraForcesTorchOffAndUnavailable() {
        var state = TorchControlState(
            hardware: TorchHardwareContext(selectedCamera: .rear, rearTorchSupported: true),
            desiredOn: true
        )
        state.apply(.userToggleRequested)
        XCTAssertEqual(state.phase, .on)

        state.apply(.cameraChanged(.front, rearTorchSupported: true))
        XCTAssertEqual(state.phase, .unavailable)

        state.apply(.cameraChanged(.rear, rearTorchSupported: true))
        XCTAssertEqual(state.phase, .off)
    }

    func testInterruptionAndReconciliationReturnToUnavailableThenOff() {
        var state = TorchControlState(
            hardware: TorchHardwareContext(selectedCamera: .rear, rearTorchSupported: true)
        )
        state.apply(.userToggleRequested)
        XCTAssertEqual(state.phase, .on)

        state.apply(.interruptionBegan)
        XCTAssertEqual(state.phase, .unavailable)

        state.apply(.interruptionEnded(rearTorchSupported: true))
        XCTAssertEqual(state.phase, .off)

        state.apply(.configurationFailed)
        XCTAssertEqual(state.phase, .unavailable)

        state.apply(.reconciled(rearTorchSupported: true))
        XCTAssertEqual(state.phase, .off)
        XCTAssertEqual(TorchControlPresentation(state: state).symbolName, "flashlight.slash.fill")
    }
}
