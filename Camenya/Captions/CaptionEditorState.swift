import Foundation

enum CaptionEditorError: Error, Equatable {
    case cueNotFound(UUID)
    case invalidRange
    case cannotSplit(UUID)
    case cannotMerge(UUID)
}

struct CaptionDraftCheckpoint: Equatable, Sendable {
    private(set) var savedTrack: TakeCaptionTrack

    init(track: TakeCaptionTrack) {
        savedTrack = track
    }

    func hasUnsavedChanges(in track: TakeCaptionTrack) -> Bool {
        track != savedTrack
    }

    mutating func markSaved(_ track: TakeCaptionTrack) {
        savedTrack = track
    }
}

struct CaptionEditorState: Equatable, Sendable {
    private(set) var track: TakeCaptionTrack

    init(track: TakeCaptionTrack) {
        self.track = track
    }

    var uncertainCueIDs: [UUID] {
        track.cues.compactMap { cue in
            guard cue.isEnabled, let confidence = cue.confidence, confidence < 0.6 else {
                return nil
            }
            return cue.id
        }
    }

    func nextUncertainCue(after cueID: UUID?) -> CaptionCue? {
        let uncertain = track.cues.filter {
            $0.isEnabled && ($0.confidence.map { $0 < 0.6 } ?? false)
        }
        guard !uncertain.isEmpty else { return nil }
        guard let cueID,
              let currentIndex = track.cues.firstIndex(where: { $0.id == cueID }) else {
            return uncertain.first
        }
        return uncertain.first(where: { candidate in
            guard let candidateIndex = track.cues.firstIndex(where: { $0.id == candidate.id }) else {
                return false
            }
            return candidateIndex > currentIndex
        }) ?? uncertain.first
    }

    mutating func updateText(cueID: UUID, text: String) {
        guard let index = track.cues.firstIndex(where: { $0.id == cueID }) else { return }
        track.cues[index].text = text
        track.reviewState = .needsReview
    }

    mutating func applyAlternative(
        cueID: UUID,
        spanRange: TakeRange,
        alternative: String
    ) {
        guard let index = track.cues.firstIndex(where: { $0.id == cueID }) else { return }
        let cue = track.cues[index]
        var searchStart = cue.text.startIndex
        for span in cue.timedSpans {
            guard let range = cue.text.range(
                of: span.text,
                range: searchStart..<cue.text.endIndex
            ) else { continue }
            if span.range == spanRange {
                track.cues[index].text.replaceSubrange(range, with: alternative)
                track.reviewState = .needsReview
                return
            }
            searchStart = range.upperBound
        }
    }

    mutating func updateRange(cueID: UUID, range: TakeRange) throws {
        guard let index = track.cues.firstIndex(where: { $0.id == cueID }) else {
            throw CaptionEditorError.cueNotFound(cueID)
        }
        guard range.duration >= 0.1,
              range.start.seconds >= track.sourceRange.start.seconds,
              range.end.seconds <= track.sourceRange.end.seconds else {
            throw CaptionEditorError.invalidRange
        }
        if index > 0, range.start.seconds < track.cues[index - 1].range.end.seconds {
            throw CaptionEditorError.invalidRange
        }
        if index + 1 < track.cues.count,
           range.end.seconds > track.cues[index + 1].range.start.seconds {
            throw CaptionEditorError.invalidRange
        }
        track.cues[index].range = range
        track.reviewState = .needsReview
    }

    mutating func setEnabled(cueID: UUID, isEnabled: Bool) {
        guard let index = track.cues.firstIndex(where: { $0.id == cueID }) else { return }
        track.cues[index].isEnabled = isEnabled
        track.reviewState = .needsReview
    }

    mutating func restore(cueID: UUID) throws {
        guard let index = track.cues.firstIndex(where: { $0.id == cueID }) else {
            throw CaptionEditorError.cueNotFound(cueID)
        }
        track.cues[index].text = track.cues[index].recognizedText
        track.cues[index].range = track.cues[index].recognizedRange
        track.cues[index].isEnabled = true
        track.reviewState = .needsReview
    }

    mutating func split(cueID: UUID) throws {
        guard let index = track.cues.firstIndex(where: { $0.id == cueID }) else {
            throw CaptionEditorError.cueNotFound(cueID)
        }
        let cue = track.cues[index]
        let words = cue.text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 2 else { throw CaptionEditorError.cannotSplit(cueID) }
        let leftCount = max(1, words.count / 2 + words.count % 2)
        let leftText = words[..<leftCount].joined(separator: " ")
        let rightText = words[leftCount...].joined(separator: " ")
        let midpoint = cue.range.start.seconds + cue.range.duration / 2
        let leftRange = TakeRange(startSeconds: cue.range.start.seconds, endSeconds: midpoint)
        let rightRange = TakeRange(startSeconds: midpoint, endSeconds: cue.range.end.seconds)
        // A text split has no guaranteed matching recognizer-time boundary.
        let leftSpans: [CaptionTimedSpan] = []
        let rightSpans: [CaptionTimedSpan] = []
        let left = CaptionCue(
            range: leftRange,
            recognizedText: leftText,
            text: leftText,
            confidence: cue.confidence,
            alternatives: [],
            timedSpans: leftSpans,
            isEnabled: cue.isEnabled
        )
        let right = CaptionCue(
            range: rightRange,
            recognizedText: rightText,
            text: rightText,
            confidence: cue.confidence,
            alternatives: [],
            timedSpans: rightSpans,
            isEnabled: cue.isEnabled
        )
        track.cues.replaceSubrange(index...index, with: [left, right])
        track.reviewState = .needsReview
    }

    mutating func mergeWithNext(cueID: UUID) throws {
        guard let index = track.cues.firstIndex(where: { $0.id == cueID }),
              track.cues.indices.contains(index + 1) else {
            throw CaptionEditorError.cannotMerge(cueID)
        }
        let first = track.cues[index]
        let second = track.cues[index + 1]
        let mergedText = [first.text, second.text].joined(separator: " ")
        let retainsTiming = !first.wasEdited && !first.timingWasEdited
            && !second.wasEdited && !second.timingWasEdited
        let merged = CaptionCue(
            range: TakeRange(start: first.range.start, end: second.range.end),
            recognizedRange: TakeRange(start: first.recognizedRange.start, end: second.recognizedRange.end),
            recognizedText: [first.recognizedText, second.recognizedText].joined(separator: " "),
            text: mergedText,
            confidence: [first.confidence, second.confidence].compactMap { $0 }.min(),
            alternatives: Array(Set(first.alternatives + second.alternatives)).sorted(),
            timedSpans: retainsTiming ? first.timedSpans + second.timedSpans : [],
            isEnabled: first.isEnabled || second.isEnabled
        )
        track.cues.replaceSubrange(index...(index + 1), with: [merged])
        track.reviewState = .needsReview
    }
}

struct ActiveCaptionPresentation: Equatable, Sendable {
    let cue: CaptionCue
    let timedSpan: CaptionTimedSpan?
}

enum CaptionOverlayResolver {
    static func active(
        in track: TakeCaptionTrack,
        at time: TimeInterval
    ) -> ActiveCaptionPresentation? {
        guard let cue = track.cues.first(where: {
            $0.isEnabled && time >= $0.range.start.seconds && time < $0.range.end.seconds
        }) else { return nil }
        let timedSpan: CaptionTimedSpan?
        if cue.wasEdited || cue.timingWasEdited {
            timedSpan = nil
        } else {
            timedSpan = cue.timedSpans.first(where: {
                time >= $0.range.start.seconds && time < $0.range.end.seconds
            })
        }
        return ActiveCaptionPresentation(cue: cue, timedSpan: timedSpan)
    }
}
