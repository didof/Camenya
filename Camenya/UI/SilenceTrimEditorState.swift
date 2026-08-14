import Foundation

enum SilenceTrimBoundary: Equatable, Sendable {
    case start
    case end
}

enum SilenceTrimNudgeDirection: Equatable, Sendable {
    case earlier
    case later
}

struct SilenceTrimEditorState: Equatable, Sendable {
    static let nudgeStep: TimeInterval = 0.1

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

    func selectionAfterNudge(
        _ boundary: SilenceTrimBoundary,
        direction: SilenceTrimNudgeDirection
    ) -> TakeRange? {
        let start = selection.start.seconds
        let end = selection.end.seconds
        let candidate: TakeRange
        switch (boundary, direction) {
        case (.start, .earlier):
            candidate = TakeRange(startSeconds: start - Self.nudgeStep, endSeconds: end)
        case (.start, .later):
            candidate = TakeRange(startSeconds: start + Self.nudgeStep, endSeconds: end)
        case (.end, .earlier):
            candidate = TakeRange(startSeconds: start, endSeconds: end - Self.nudgeStep)
        case (.end, .later):
            candidate = TakeRange(startSeconds: start, endSeconds: end + Self.nudgeStep)
        }
        guard candidate != selection,
              candidate.isValid(inside: duration, minimumDuration: minimumKeptDuration) else {
            return nil
        }
        return candidate
    }

    @discardableResult
    mutating func nudge(
        _ boundary: SilenceTrimBoundary,
        direction: SilenceTrimNudgeDirection
    ) -> Bool {
        guard let candidate = selectionAfterNudge(boundary, direction: direction) else {
            return false
        }
        switch boundary {
        case .start:
            setSelectionStart(candidate.start.seconds)
        case .end:
            setSelectionEnd(candidate.end.seconds)
        }
        return true
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
