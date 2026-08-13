import Foundation

struct SilenceTrimEditorState: Equatable, Sendable {
    let duration: TimeInterval
    let suggestion: TakeRange
    private(set) var leadingRemoval: TimeInterval
    private(set) var trailingRemoval: TimeInterval

    init(duration: TimeInterval, suggestion: TakeRange, selection: TakeRange? = nil) {
        self.duration = max(0, duration)
        self.suggestion = suggestion
        leadingRemoval = 0
        trailingRemoval = 0
        restoreValues(from: selection ?? suggestion)
        normalize()
    }

    var keptDuration: TimeInterval {
        max(0, duration - leadingRemoval - trailingRemoval)
    }

    var removedDuration: TimeInterval {
        leadingRemoval + trailingRemoval
    }

    var selection: TakeRange {
        TakeRange(
            startSeconds: leadingRemoval,
            endSeconds: duration - trailingRemoval
        )
    }

    var hasManualChanges: Bool {
        selection != suggestion
    }

    var maximumLeadingRemoval: TimeInterval {
        max(0, duration - trailingRemoval - minimumKeptDuration)
    }

    var maximumTrailingRemoval: TimeInterval {
        max(0, duration - leadingRemoval - minimumKeptDuration)
    }

    mutating func setLeadingRemoval(_ value: TimeInterval) {
        leadingRemoval = min(max(0, value), maximumLeadingRemoval)
    }

    mutating func setTrailingRemoval(_ value: TimeInterval) {
        trailingRemoval = min(max(0, value), maximumTrailingRemoval)
    }

    mutating func setSelectionStart(_ value: TimeInterval) {
        setLeadingRemoval(value)
    }

    mutating func setSelectionEnd(_ value: TimeInterval) {
        setTrailingRemoval(duration - value)
    }

    mutating func resetToSuggestion() {
        restoreValues(from: suggestion)
        normalize()
    }

    private mutating func restoreValues(from range: TakeRange) {
        leadingRemoval = max(0, range.start.seconds)
        trailingRemoval = max(0, duration - range.end.seconds)
    }

    private var minimumKeptDuration: TimeInterval {
        min(1, duration)
    }

    private mutating func normalize() {
        leadingRemoval = min(leadingRemoval, max(0, duration - minimumKeptDuration))
        trailingRemoval = min(
            trailingRemoval,
            max(0, duration - leadingRemoval - minimumKeptDuration)
        )
    }
}
