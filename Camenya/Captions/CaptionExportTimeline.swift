import Foundation

struct ProjectCaptionTextRange: Equatable, Sendable {
    let location: Int
    let length: Int

    fileprivate var foundationRange: NSRange {
        NSRange(location: location, length: length)
    }
}

struct ProjectCaptionExportCue: Equatable, Sendable {
    let range: TakeRange
    let text: String
    let timedSpans: [CaptionTimedSpan]
    let timedSpanTextRanges: [ProjectCaptionTextRange?]

    init(
        range: TakeRange,
        text: String,
        timedSpans: [CaptionTimedSpan],
        timedSpanTextRanges: [ProjectCaptionTextRange?]? = nil
    ) {
        self.range = range
        let normalizedText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        self.text = normalizedText
        self.timedSpans = timedSpans
        if let timedSpanTextRanges,
           timedSpanTextRanges.count == timedSpans.count {
            self.timedSpanTextRanges = timedSpanTextRanges
        } else {
            self.timedSpanTextRanges = CaptionTextOccurrenceResolver.ranges(
                in: normalizedText,
                for: timedSpans
            )
        }
    }
}

struct ProjectCaptionExportTimeline: Equatable, Sendable {
    let placement: CaptionPlacementZone
    let style: CaptionStylePreset
    let customization: CaptionStyleCustomization
    let duration: TimeInterval
    let cues: [ProjectCaptionExportCue]

    init(
        placement: CaptionPlacementZone,
        style: CaptionStylePreset,
        customization: CaptionStyleCustomization = CaptionStyleCustomization(),
        duration: TimeInterval,
        cues: [ProjectCaptionExportCue]
    ) {
        self.placement = placement
        self.style = style
        self.customization = customization
        self.duration = duration
        self.cues = cues
    }
}

struct ActiveProjectCaptionPresentation: Equatable, Sendable {
    let cue: ProjectCaptionExportCue
    let timedSpan: CaptionTimedSpan?
}

struct ProjectCaptionTextRun: Equatable, Sendable {
    let text: String
    let isHighlighted: Bool
}

private enum CaptionTextOccurrenceResolver {
    static func ranges(
        in text: String,
        for spans: [CaptionTimedSpan]
    ) -> [ProjectCaptionTextRange?] {
        var searchIndex = 0
        let occurrences = lexicalOccurrences(in: text)
        return spans.map { span in
            let targetTokens = lexicalTokens(in: span.text)
            guard targetTokens.count == 1,
                  let matchIndex = occurrences[searchIndex...].firstIndex(where: {
                      $0.token.caseInsensitiveCompare(targetTokens[0]) == .orderedSame
                  }) else { return nil }
            let range = occurrences[matchIndex].range
            searchIndex = matchIndex + 1
            return ProjectCaptionTextRange(
                location: range.location,
                length: range.length
            )
        }
    }

    private static func lexicalOccurrences(
        in text: String
    ) -> [(token: String, range: NSRange)] {
        let source = text as NSString
        var location = 0
        var output: [(String, NSRange)] = []
        while location < source.length {
            let remaining = NSRange(location: location, length: source.length - location)
            let start = source.rangeOfCharacter(from: .alphanumerics, options: [], range: remaining)
            guard start.location != NSNotFound else { break }
            let tokenStart = start.location
            let tail = NSRange(location: tokenStart, length: source.length - tokenStart)
            let separator = source.rangeOfCharacter(
                from: .alphanumerics.inverted,
                options: [],
                range: tail
            )
            let tokenEnd = separator.location == NSNotFound ? source.length : separator.location
            let range = NSRange(location: tokenStart, length: tokenEnd - tokenStart)
            output.append((source.substring(with: range), range))
            location = max(tokenEnd, tokenStart + 1)
        }
        return output
    }

    private static func lexicalTokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

enum ProjectCaptionOverlayResolver {
    static func active(
        in timeline: ProjectCaptionExportTimeline,
        at time: TimeInterval
    ) -> ActiveProjectCaptionPresentation? {
        guard let cue = timeline.cues.first(where: {
            time >= $0.range.start.seconds && time < $0.range.end.seconds
        }) else { return nil }
        return ActiveProjectCaptionPresentation(
            cue: cue,
            timedSpan: cue.timedSpans.first(where: {
                time >= $0.range.start.seconds && time < $0.range.end.seconds
            })
        )
    }

    static func textRuns(
        for presentation: ActiveProjectCaptionPresentation
    ) -> [ProjectCaptionTextRun] {
        let source = presentation.cue.text as NSString
        guard let timedSpan = presentation.timedSpan,
              let highlightedRange = highlightRange(
                for: timedSpan,
                in: presentation.cue
              ) else {
            return [ProjectCaptionTextRun(
                text: presentation.cue.text,
                isHighlighted: false
            )]
        }

        var runs: [ProjectCaptionTextRun] = []
        if highlightedRange.location > 0 {
            runs.append(ProjectCaptionTextRun(
                text: source.substring(with: NSRange(
                    location: 0,
                    length: highlightedRange.location
                )),
                isHighlighted: false
            ))
        }
        runs.append(ProjectCaptionTextRun(
            text: source.substring(with: highlightedRange),
            isHighlighted: true
        ))
        let suffixLocation = NSMaxRange(highlightedRange)
        if suffixLocation < source.length {
            runs.append(ProjectCaptionTextRun(
                text: source.substring(from: suffixLocation),
                isHighlighted: false
            ))
        }
        return runs
    }

    static func highlightRange(
        for target: CaptionTimedSpan,
        in cue: ProjectCaptionExportCue
    ) -> NSRange? {
        guard let index = cue.timedSpans.firstIndex(of: target),
              cue.timedSpanTextRanges.indices.contains(index) else { return nil }
        return cue.timedSpanTextRanges[index]?.foundationRange
    }
}
