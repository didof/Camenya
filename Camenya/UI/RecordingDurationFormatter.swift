import Foundation

enum RecordingDurationFormatter {
    static func clock(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func editingClock(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return "00:00.0" }
        let totalTenths = max(0, Int((duration * 10).rounded()))
        let seconds = totalTenths / 10
        return String(
            format: "%02d:%02d.%01d",
            seconds / 60,
            seconds % 60,
            totalTenths % 10
        )
    }
}
