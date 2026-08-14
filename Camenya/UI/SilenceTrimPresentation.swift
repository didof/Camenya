import Foundation

struct SilenceTrimNudgePresentation: Equatable, Sendable {
    let title: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let isEnabled: Bool

    init(
        editor: SilenceTrimEditorState,
        boundary: SilenceTrimBoundary,
        direction: SilenceTrimNudgeDirection
    ) {
        let boundaryName: String
        let currentValue: TimeInterval
        switch boundary {
        case .start:
            boundaryName = "start"
            currentValue = editor.selection.start.seconds
        case .end:
            boundaryName = "end"
            currentValue = editor.selection.end.seconds
        }

        let directionName: String
        switch direction {
        case .earlier:
            title = "Earlier"
            directionName = "earlier"
        case .later:
            title = "Later"
            directionName = "later"
        }

        accessibilityLabel = "Trim \(boundaryName) \(directionName) by 0.1 seconds"
        if let candidate = editor.selectionAfterNudge(boundary, direction: direction) {
            let result = boundary == .start ? candidate.start.seconds : candidate.end.seconds
            accessibilityValue = "Result \(RecordingDurationFormatter.editingClock(result))"
            isEnabled = true
        } else {
            accessibilityValue = "Unavailable at \(RecordingDurationFormatter.editingClock(currentValue))"
            isEnabled = false
        }
    }
}

struct SilenceTrimPresentation: Equatable, Sendable {
    let summaryTitle: String
    let keptDuration: String
    let removedDuration: String
    let waveformAccessibilityValue: String
    let showsResetAction: Bool
    let resetActionTitle: String

    init(editor: SilenceTrimEditorState, suggestionWasDetected: Bool = true) {
        if editor.hasManualChanges {
            summaryTitle = "Custom silence trim"
        } else {
            summaryTitle = suggestionWasDetected ? "Suggested silence trim" : "No trim suggested"
        }
        keptDuration = RecordingDurationFormatter.editingClock(editor.keptDuration)
        removedDuration = RecordingDurationFormatter.editingClock(editor.removedDuration)
        waveformAccessibilityValue = [
            "Removes \(RecordingDurationFormatter.editingClock(editor.leadingRemoval)) from the beginning",
            "removes \(RecordingDurationFormatter.editingClock(editor.trailingRemoval)) from the end",
            "keeps \(keptDuration)"
        ].joined(separator: ", ")
        showsResetAction = editor.hasManualChanges
        resetActionTitle = suggestionWasDetected ? "Reset to Suggestion" : "Reset to Full Take"
    }
}
