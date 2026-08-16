import Foundation

/// Pure model for rear-camera torch availability and desired on/off state.
/// AVFoundation integration (#11) will drive events from `CameraController`.
enum TorchPhase: Equatable, Sendable {
    case unavailable
    case off
    case on
}

struct TorchHardwareContext: Equatable, Sendable {
    var selectedCamera: CameraPosition
    var rearTorchSupported: Bool
    var captureInterrupted: Bool
    var configurationFailed: Bool

    init(
        selectedCamera: CameraPosition = .front,
        rearTorchSupported: Bool = false,
        captureInterrupted: Bool = false,
        configurationFailed: Bool = false
    ) {
        self.selectedCamera = selectedCamera
        self.rearTorchSupported = rearTorchSupported
        self.captureInterrupted = captureInterrupted
        self.configurationFailed = configurationFailed
    }
}

enum TorchControlEvent: Equatable, Sendable {
    case cameraChanged(CameraPosition, rearTorchSupported: Bool)
    case userToggleRequested
    case interruptionBegan
    case interruptionEnded(rearTorchSupported: Bool)
    case configurationFailed
    case reconciled(rearTorchSupported: Bool)
}

struct TorchControlState: Equatable, Sendable {
    private(set) var phase: TorchPhase
    private(set) var hardware: TorchHardwareContext
    private var desiredOn: Bool

    init(hardware: TorchHardwareContext, desiredOn: Bool = false) {
        self.hardware = hardware
        self.desiredOn = desiredOn
        phase = Self.resolvePhase(hardware: hardware, desiredOn: desiredOn)
    }

    mutating func apply(_ event: TorchControlEvent) {
        switch event {
        case let .cameraChanged(position, rearTorchSupported):
            hardware.selectedCamera = position
            hardware.rearTorchSupported = rearTorchSupported
            hardware.captureInterrupted = false
            hardware.configurationFailed = false
            if position == .front || !rearTorchSupported {
                desiredOn = false
            }
        case .userToggleRequested:
            guard hardware.selectedCamera == .rear,
                  hardware.rearTorchSupported,
                  !hardware.captureInterrupted,
                  !hardware.configurationFailed else { return }
            desiredOn.toggle()
        case .interruptionBegan:
            hardware.captureInterrupted = true
            desiredOn = false
        case let .interruptionEnded(rearTorchSupported):
            hardware.captureInterrupted = false
            hardware.rearTorchSupported = rearTorchSupported
            desiredOn = false
        case .configurationFailed:
            hardware.configurationFailed = true
            desiredOn = false
        case let .reconciled(rearTorchSupported):
            hardware.configurationFailed = false
            hardware.captureInterrupted = false
            hardware.rearTorchSupported = rearTorchSupported
            if hardware.selectedCamera == .front || !rearTorchSupported {
                desiredOn = false
            }
        }
        phase = Self.resolvePhase(hardware: hardware, desiredOn: desiredOn)
    }

    private static func resolvePhase(hardware: TorchHardwareContext, desiredOn: Bool) -> TorchPhase {
        guard hardware.selectedCamera == .rear,
              hardware.rearTorchSupported,
              !hardware.captureInterrupted,
              !hardware.configurationFailed else {
            return .unavailable
        }
        return desiredOn ? .on : .off
    }
}

struct TorchControlPresentation: Equatable, Sendable {
    let label: String
    let symbolName: String
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityValue: String

    init(state: TorchControlState) {
        switch state.phase {
        case .unavailable:
            label = "Torch Unavailable"
            symbolName = "flashlight.slash"
            isEnabled = false
            accessibilityLabel = "Torch"
            accessibilityValue = "Unavailable"
        case .off:
            label = "Torch Off"
            symbolName = "flashlight.slash.fill"
            isEnabled = true
            accessibilityLabel = "Torch"
            accessibilityValue = "Off"
        case .on:
            label = "Torch On"
            symbolName = "flashlight.on.fill"
            isEnabled = true
            accessibilityLabel = "Torch"
            accessibilityValue = "On"
        }
    }
}

/// Contract for #11: hardware writes happen only after `TorchControlState` reaches `.on`/`.off`
/// on a torch-capable rear camera; failures emit `.configurationFailed` then `.reconciled(...)`.
enum TorchControlIntegrationContract {
    static let documentation = """
    TorchControlState is the single source of truth for torch UI before AVFoundation mutation.
    CameraController must serialize torch writes on the capture-session queue and emit
    .configurationFailed when lockForConfiguration() or setTorchModeOn fails, followed by
    .reconciled(rearTorchSupported:) from the live device capability snapshot.
    """
}
