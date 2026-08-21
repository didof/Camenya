import Foundation

enum CameraOperationalState: Equatable, Sendable {
    case configuring
    case suspended
    case restoring
    case ready
    case unavailable(String)

    var isReady: Bool { self == .ready }
    var isRestoring: Bool { self == .restoring }

    var recoveryMessage: String? {
        guard case let .unavailable(message) = self else { return nil }
        return message
    }
}

struct CameraLifecyclePolicy: Equatable, Sendable {
    struct RestorationAttempt: Equatable, Sendable {
        fileprivate let generation: UInt
    }

    enum SessionFailureDisposition: Equatable, Sendable {
        case presentUnexpectedFailure
        case suppressExpectedLifecycle
    }

    enum RestorationResult: Equatable, Sendable {
        case restored
        case unavailable
    }

    enum TakeActivity: Equatable, Sendable {
        case inactive
        case paused
        case activeSegment
    }

    enum BackgroundTakeDisposition: Equatable, Sendable {
        case preserveCurrentState
        case interruptTake
    }

    private enum ApplicationState: Equatable, Sendable {
        case active
        case inactive
        case background
        case restoring
    }

    private var applicationState: ApplicationState = .active
    private var restorationGeneration: UInt = 0

    var sessionFailureDisposition: SessionFailureDisposition {
        applicationState == .active
            ? .presentUnexpectedFailure
            : .suppressExpectedLifecycle
    }

    var shouldRestartAfterInterruptionEnded: Bool {
        applicationState == .active
    }

    func takeDispositionForBackground(
        activity: TakeActivity
    ) -> BackgroundTakeDisposition {
        activity == .activeSegment ? .interruptTake : .preserveCurrentState
    }

    func takeDispositionForSessionFailure(
        activity: TakeActivity
    ) -> BackgroundTakeDisposition {
        if sessionFailureDisposition == .suppressExpectedLifecycle {
            return takeDispositionForBackground(activity: activity)
        }
        return activity == .inactive ? .preserveCurrentState : .interruptTake
    }

    mutating func applicationBecameInactive() {
        restorationGeneration &+= 1
        applicationState = .inactive
    }

    mutating func applicationEnteredBackground() {
        restorationGeneration &+= 1
        applicationState = .background
    }

    @discardableResult
    mutating func applicationBecameActive() -> RestorationAttempt {
        restorationGeneration &+= 1
        applicationState = .restoring
        return RestorationAttempt(generation: restorationGeneration)
    }

    mutating func restorationCompleted(
        _ attempt: RestorationAttempt,
        isUsable: Bool
    ) -> RestorationResult? {
        guard applicationState == .restoring,
              attempt.generation == restorationGeneration else { return nil }
        applicationState = .active
        return isUsable ? .restored : .unavailable
    }
}
