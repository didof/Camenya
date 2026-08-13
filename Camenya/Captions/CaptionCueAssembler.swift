import Foundation

struct CaptionRecognizedUnit: Equatable, Sendable {
    let range: TakeRange
    let text: String
    let confidence: Double?
    let alternatives: [String]
    let granularity: CaptionTimingGranularity
    let cueAlternativeGroupID: UUID?
    let cueAlternatives: [String]

    init(
        range: TakeRange,
        text: String,
        confidence: Double?,
        alternatives: [String],
        granularity: CaptionTimingGranularity,
        cueAlternativeGroupID: UUID? = nil,
        cueAlternatives: [String] = []
    ) {
        self.range = range
        self.text = text
        self.confidence = confidence
        self.alternatives = alternatives
        self.granularity = granularity
        self.cueAlternativeGroupID = cueAlternativeGroupID
        self.cueAlternatives = cueAlternatives
    }
}

struct CaptionCueAssembler: Sendable {
    let maximumCharacters: Int
    let maximumDuration: TimeInterval
    let maximumGap: TimeInterval

    init(
        maximumCharacters: Int = 42,
        maximumDuration: TimeInterval = 3,
        maximumGap: TimeInterval = 0.8
    ) {
        self.maximumCharacters = maximumCharacters
        self.maximumDuration = maximumDuration
        self.maximumGap = maximumGap
    }

    func assemble(_ units: [CaptionRecognizedUnit]) -> [CaptionCue] {
        let alternativeGroupCounts = Dictionary(
            grouping: units.compactMap(\.cueAlternativeGroupID),
            by: { $0 }
        ).mapValues(\.count)
        var groups: [[CaptionRecognizedUnit]] = []
        for unit in units.sorted(by: { $0.range.start.seconds < $1.range.start.seconds }) {
            guard unit.range.duration > 0,
                  unit.range.start.seconds.isFinite,
                  unit.range.end.seconds.isFinite else { continue }
            guard var current = groups.popLast() else {
                groups.append([unit])
                continue
            }
            let candidateText = joinedText(current.map(\.text) + [unit.text])
            let candidateDuration = unit.range.end.seconds - (current.first?.range.start.seconds ?? 0)
            let gap = unit.range.start.seconds - (current.last?.range.end.seconds ?? 0)
            if candidateText.count <= maximumCharacters,
               candidateDuration <= maximumDuration,
               gap <= maximumGap {
                current.append(unit)
                groups.append(current)
            } else {
                groups.append(current)
                groups.append([unit])
            }
        }
        return groups.compactMap {
            makeCue($0, alternativeGroupCounts: alternativeGroupCounts)
        }
    }

    private func makeCue(
        _ units: [CaptionRecognizedUnit],
        alternativeGroupCounts: [UUID: Int]
    ) -> CaptionCue? {
        guard let first = units.first, let last = units.last else { return nil }
        let text = joinedText(units.map(\.text))
        guard !text.isEmpty else { return nil }
        let groupID = first.cueAlternativeGroupID
        let cueAlternatives = groupID != nil
            && units.allSatisfy({ $0.cueAlternativeGroupID == groupID })
            && alternativeGroupCounts[groupID!] == units.count
            ? first.cueAlternatives
            : []
        return CaptionCue(
            range: TakeRange(start: first.range.start, end: last.range.end),
            recognizedText: text,
            text: text,
            confidence: units.compactMap(\.confidence).min(),
            alternatives: cueAlternatives.isEmpty && units.count == 1
                ? first.alternatives
                : cueAlternatives,
            timedSpans: units.map { unit in
                CaptionTimedSpan(
                    range: unit.range,
                    text: unit.text,
                    granularity: unit.granularity,
                    confidence: unit.confidence,
                    alternatives: unit.alternatives
                )
            }
        )
    }

    private func joinedText(_ parts: [String]) -> String {
        parts.reduce(into: "") { result, part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if result.isEmpty || trimmed.first.map({ ",.!?;:%)]}".contains($0) }) == true {
                result += trimmed
            } else {
                result += " " + trimmed
            }
        }
    }
}
