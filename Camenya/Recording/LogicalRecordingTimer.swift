import Foundation

struct LogicalRecordingTimer: Equatable, Sendable {
    private(set) var completedDuration: TimeInterval = 0

    mutating func completeSegment(duration: TimeInterval) {
        completedDuration += max(0, duration)
    }

    func elapsed(activeSegmentDuration: TimeInterval) -> TimeInterval {
        completedDuration + max(0, activeSegmentDuration)
    }

    mutating func reset() {
        completedDuration = 0
    }
}
