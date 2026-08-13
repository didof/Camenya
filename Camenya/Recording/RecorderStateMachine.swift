import Foundation

enum RecorderPhase: String, Codable, Equatable, Sendable {
    case configuring
    case idle
    case startingSegment
    case recording
    case stoppingForPause
    case paused
    case switchingCamera
    case resuming
    case stopping
    case finalizing
    case storingTake
    case completed
    case failed
}

enum RecorderEvent: Equatable, Sendable {
    case sessionConfigured
    case recordRequested
    case segmentStarted
    case pauseRequested
    case segmentFinished
    case flipRequested
    case cameraSwitchCompleted
    case cameraSwitchFailed
    case resumeRequested
    case stopRequested
    case finalizationSucceeded
    case takeStored
    case failureOccurred
    case reset
}

struct InvalidRecorderTransition: Error, Equatable, LocalizedError {
    let phase: RecorderPhase
    let event: RecorderEvent

    var errorDescription: String? {
        "Cannot apply \(event) while recorder is \(phase.rawValue)."
    }
}

struct RecorderStateMachine: Sendable {
    private(set) var phase: RecorderPhase
    private var phaseBeforeCameraSwitch: RecorderPhase?

    init(initialPhase: RecorderPhase = .configuring) {
        phase = initialPhase
    }

    mutating func apply(_ event: RecorderEvent) throws {
        switch (phase, event) {
        case (.configuring, .sessionConfigured):
            phase = .idle
        case (.idle, .recordRequested):
            phase = .startingSegment
        case (.startingSegment, .segmentStarted), (.resuming, .segmentStarted):
            phase = .recording
        case (.recording, .pauseRequested):
            phase = .stoppingForPause
        case (.stoppingForPause, .segmentFinished):
            phase = .paused
        case (.recording, .stopRequested):
            phase = .stopping
        case (.stopping, .segmentFinished):
            phase = .finalizing
        case (.paused, .stopRequested):
            phase = .finalizing
        case (.paused, .resumeRequested):
            phase = .resuming
        case (.idle, .flipRequested), (.paused, .flipRequested):
            phaseBeforeCameraSwitch = phase
            phase = .switchingCamera
        case (.switchingCamera, .cameraSwitchCompleted), (.switchingCamera, .cameraSwitchFailed):
            guard let returnPhase = phaseBeforeCameraSwitch else {
                throw InvalidRecorderTransition(phase: phase, event: event)
            }
            phaseBeforeCameraSwitch = nil
            phase = returnPhase
        case (.finalizing, .finalizationSucceeded):
            phase = .storingTake
        case (.storingTake, .takeStored):
            phase = .completed
        case (_, .failureOccurred):
            phaseBeforeCameraSwitch = nil
            phase = .failed
        case (.completed, .reset), (.failed, .reset):
            phase = .idle
        default:
            throw InvalidRecorderTransition(phase: phase, event: event)
        }
    }
}
