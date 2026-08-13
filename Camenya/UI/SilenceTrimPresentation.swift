import Foundation

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
        keptDuration = RecordingDurationFormatter.clock(editor.keptDuration)
        removedDuration = RecordingDurationFormatter.clock(editor.removedDuration)
        waveformAccessibilityValue = [
            "Removes \(RecordingDurationFormatter.clock(editor.leadingRemoval)) from the beginning",
            "removes \(RecordingDurationFormatter.clock(editor.trailingRemoval)) from the end",
            "keeps \(keptDuration)"
        ].joined(separator: ", ")
        showsResetAction = editor.hasManualChanges
        resetActionTitle = suggestionWasDetected ? "Reset to Suggestion" : "Reset to Full Take"
    }
}
