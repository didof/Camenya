import Foundation

struct CameraRecoveryAlertState: Equatable, Sendable {
    struct Alert: Equatable, Sendable {
        let id: UInt
        let message: String
    }

    struct RecoveryAttempt: Equatable, Sendable {
        fileprivate let failureGeneration: UInt?
    }

    private(set) var alert: Alert?
    private var failureGeneration: UInt?
    private var nextGeneration: UInt = 0

    mutating func presentCaptureSessionFailure(_ message: String) -> Alert {
        nextGeneration &+= 1
        failureGeneration = nextGeneration
        let alert = Alert(id: nextGeneration, message: message)
        self.alert = alert
        return alert
    }

    func beginRecoveryAttempt() -> RecoveryAttempt {
        RecoveryAttempt(failureGeneration: failureGeneration)
    }

    mutating func recoveredAlert(
        _ attempt: RecoveryAttempt,
        ifPresentedAlertID presentedAlertID: UInt?
    ) -> Alert? {
        guard attempt.failureGeneration == failureGeneration,
              failureGeneration != nil else { return nil }
        let recoveredAlert = alert
        alert = nil
        failureGeneration = nil
        return recoveredAlert?.id == presentedAlertID ? recoveredAlert : nil
    }
}
