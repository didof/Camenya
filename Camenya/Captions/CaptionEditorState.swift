import Foundation

enum CaptionEditorHistoryPolicy {
    static func canUndo(
        undoCount: Int,
        textBaseline: [CaptionCue]?,
        currentCues: [CaptionCue]
    ) -> Bool {
        undoCount > 0 || textBaseline.map { $0 != currentCues } == true
    }

    static func canRedo(
        redoCount: Int,
        textBaseline: [CaptionCue]?,
        currentCues: [CaptionCue]
    ) -> Bool {
        redoCount > 0 && textBaseline.map { $0 != currentCues } != true
    }
}

struct CaptionHistoryEntry: Equatable, Sendable {
    let cues: [CaptionCue]
    let configuration: ProjectCaptionConfiguration
    let operationName: String
}

struct CaptionHistoryTransition: Equatable, Sendable {
    let target: CaptionHistoryEntry
    let current: CaptionHistoryEntry
    let isUndo: Bool

    var announcement: String {
        "\(isUndo ? "Undid" : "Redid") \(target.operationName)"
    }
}

struct CaptionHistoryCoordinator: Equatable, Sendable {
    private(set) var undoEntries: [CaptionHistoryEntry] = []
    private(set) var redoEntries: [CaptionHistoryEntry] = []

    var undoCount: Int { undoEntries.count }
    var redoCount: Int { redoEntries.count }

    mutating func record(
        cues: [CaptionCue],
        configuration: ProjectCaptionConfiguration,
        operationName: String
    ) {
        undoEntries.append(CaptionHistoryEntry(
            cues: cues,
            configuration: configuration,
            operationName: operationName
        ))
        redoEntries.removeAll()
    }

    mutating func removeAll() {
        undoEntries.removeAll()
        redoEntries.removeAll()
    }

    func transition(
        isUndo: Bool,
        currentCues: [CaptionCue],
        currentConfiguration: ProjectCaptionConfiguration
    ) -> CaptionHistoryTransition? {
        guard let target = isUndo ? undoEntries.last : redoEntries.last else { return nil }
        return CaptionHistoryTransition(
            target: target,
            current: CaptionHistoryEntry(
                cues: currentCues,
                configuration: currentConfiguration,
                operationName: target.operationName
            ),
            isUndo: isUndo
        )
    }

    func canApply(
        _ transition: CaptionHistoryTransition,
        currentCues: [CaptionCue],
        currentConfiguration: ProjectCaptionConfiguration
    ) -> Bool {
        transition.current.cues == currentCues
            && transition.current.configuration == currentConfiguration
            && (transition.isUndo
                ? undoEntries.last == transition.target
                : redoEntries.last == transition.target)
    }

    @discardableResult
    mutating func commit(_ transition: CaptionHistoryTransition) -> Bool {
        if transition.isUndo {
            guard undoEntries.last == transition.target else { return false }
            _ = undoEntries.popLast()
            redoEntries.append(transition.current)
        } else {
            guard redoEntries.last == transition.target else { return false }
            _ = redoEntries.popLast()
            undoEntries.append(transition.current)
        }
        return true
    }
}

enum CaptionDensityPreviewPolicy {
    static func cue(
        in cues: [CaptionCue],
        preferredCueID: UUID?,
        regions: [ProjectCaptionRegion],
        configuration: ProjectCaptionConfiguration,
        format: ProjectFormat
    ) -> CaptionCue? {
        let regrouped = CaptionDensityReflow.apply(
            configuration.density,
            to: cues,
            regions: regions,
            configuration: configuration,
            format: format
        )
        let preferred = preferredCueID.flatMap { id in cues.first(where: { $0.id == id }) }
        let anchor = preferred.map { ($0.range.start.seconds + $0.range.end.seconds) / 2 }
        return anchor.flatMap { time in
            regrouped.first {
                !$0.wasEdited
                    && time >= $0.range.start.seconds
                    && time < $0.range.end.seconds
            }
        } ?? regrouped.first(where: { !$0.wasEdited })
            ?? regrouped.first
    }

    static func preservedEditedCueCount(in cues: [CaptionCue]) -> Int {
        cues.filter(\.wasEdited).count
    }
}

struct ProjectCaptionEditorState: Equatable, Sendable {
    static let defaultNewCaptionDuration: TimeInterval = 2

    let duration: TimeInterval
    private(set) var cues: [CaptionCue]

    init(duration: TimeInterval, cues: [CaptionCue]) {
        self.duration = max(0, duration)
        self.cues = cues.sorted { $0.range.start.seconds < $1.range.start.seconds }
    }

    mutating func updateText(cueID: UUID, text: String) {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { return }
        cues[index].text = text
    }

    mutating func restore(cueID: UUID) {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { return }
        cues[index].text = cues[index].recognizedText
        cues[index].range = cues[index].recognizedRange
        cues[index].isEnabled = true
        cues.sort { $0.range.start.seconds < $1.range.start.seconds }
    }

    @discardableResult
    mutating func addCaption(at projectTime: TimeInterval) -> UUID? {
        let proposedStart = min(max(0, projectTime), duration)
        let insertionIndex = cues.firstIndex { $0.range.start.seconds >= proposedStart } ?? cues.endIndex
        let previousEnd = insertionIndex > cues.startIndex ? cues[insertionIndex - 1].range.end.seconds : 0
        let nextStart = insertionIndex < cues.endIndex ? cues[insertionIndex].range.start.seconds : duration
        let start = max(proposedStart, previousEnd)
        let end = min(nextStart, start + Self.defaultNewCaptionDuration)
        guard end - start >= 0.1 else { return nil }
        let cue = CaptionCue(
            range: TakeRange(startSeconds: start, endSeconds: end),
            recognizedText: "",
            text: "",
            confidence: nil,
            alternatives: [],
            timedSpans: []
        )
        cues.insert(cue, at: insertionIndex)
        return cue.id
    }

    mutating func delete(cueID: UUID) {
        cues.removeAll { $0.id == cueID }
    }

    @discardableResult
    mutating func split(cueID: UUID, characterOffset: Int? = nil) -> UUID? {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { return nil }
        let cue = cues[index]
        let nsText = cue.text as NSString
        let requested = characterOffset ?? nsText.length / 2
        guard let splitOffset = Self.wordBoundary(in: nsText, near: requested),
              splitOffset > 0,
              splitOffset < nsText.length else { return nil }
        let leftText = nsText.substring(to: splitOffset).trimmingCharacters(in: .whitespacesAndNewlines)
        let rightText = nsText.substring(from: splitOffset).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftText.isEmpty, !rightText.isEmpty else { return nil }
        let timeFraction = Double(splitOffset) / Double(max(1, nsText.length))
        let splitTime = cue.range.start.seconds + cue.range.duration * timeFraction
        guard splitTime - cue.range.start.seconds >= 0.1,
              cue.range.end.seconds - splitTime >= 0.1 else { return nil }
        let left = CaptionCue(
            range: TakeRange(startSeconds: cue.range.start.seconds, endSeconds: splitTime),
            recognizedText: leftText,
            text: leftText,
            confidence: cue.confidence,
            alternatives: [],
            timedSpans: [],
            isEnabled: cue.isEnabled
        )
        let right = CaptionCue(
            range: TakeRange(startSeconds: splitTime, endSeconds: cue.range.end.seconds),
            recognizedText: rightText,
            text: rightText,
            confidence: cue.confidence,
            alternatives: [],
            timedSpans: [],
            isEnabled: cue.isEnabled
        )
        cues.replaceSubrange(index...index, with: [left, right])
        return right.id
    }

    @discardableResult
    mutating func merge(cueID: UUID, withPrevious: Bool) -> UUID? {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { return nil }
        let leadingIndex = withPrevious ? index - 1 : index
        guard leadingIndex >= 0, cues.indices.contains(leadingIndex + 1) else { return nil }
        let first = cues[leadingIndex]
        let second = cues[leadingIndex + 1]
        let merged = CaptionCue(
            range: TakeRange(start: first.range.start, end: second.range.end),
            recognizedRange: TakeRange(start: first.recognizedRange.start, end: second.recognizedRange.end),
            recognizedText: [first.recognizedText, second.recognizedText]
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            text: [first.text, second.text].filter { !$0.isEmpty }.joined(separator: " "),
            confidence: [first.confidence, second.confidence].compactMap { $0 }.min(),
            alternatives: [],
            timedSpans: [],
            isEnabled: first.isEnabled || second.isEnabled
        )
        cues.replaceSubrange(leadingIndex...(leadingIndex + 1), with: [merged])
        return merged.id
    }

    func canMergePrevious(cueID: UUID) -> Bool {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { return false }
        return index > cues.startIndex
    }

    func canMergeNext(cueID: UUID) -> Bool {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { return false }
        return cues.indices.contains(index + 1)
    }

    mutating func updateRange(cueID: UUID, range: TakeRange) -> Bool {
        guard let index = cues.firstIndex(where: { $0.id == cueID }),
              range.duration >= 0.1,
              range.start.seconds >= (index > 0 ? cues[index - 1].range.end.seconds : 0),
              range.end.seconds <= (index + 1 < cues.count ? cues[index + 1].range.start.seconds : duration) else {
            return false
        }
        cues[index].range = range
        return true
    }

    private static func wordBoundary(in text: NSString, near requested: Int) -> Int? {
        let clamped = min(max(1, requested), max(1, text.length - 1))
        let whitespace = CharacterSet.whitespacesAndNewlines
        if let scalar = UnicodeScalar(text.character(at: clamped)), whitespace.contains(scalar) {
            return clamped
        }
        for distance in 1..<text.length {
            let before = clamped - distance
            if before > 0,
               let scalar = UnicodeScalar(text.character(at: before)),
               whitespace.contains(scalar) { return before }
            let after = clamped + distance
            if after < text.length,
               let scalar = UnicodeScalar(text.character(at: after)),
               whitespace.contains(scalar) { return after }
        }
        return nil
    }
}
