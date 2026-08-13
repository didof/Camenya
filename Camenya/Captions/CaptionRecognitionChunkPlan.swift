import Foundation

struct CaptionRecognitionChunk: Equatable, Sendable {
    let coreRange: TakeRange
    let extractionRange: TakeRange
    let includesUpperBound: Bool

    init(
        coreRange: TakeRange,
        extractionRange: TakeRange,
        includesUpperBound: Bool = false
    ) {
        self.coreRange = coreRange
        self.extractionRange = extractionRange
        self.includesUpperBound = includesUpperBound
    }

    func owns(segmentRange: TakeRange) -> Bool {
        let midpoint = segmentRange.start.seconds + segmentRange.duration / 2
        return midpoint >= coreRange.start.seconds
            && (midpoint < coreRange.end.seconds
                || (includesUpperBound && midpoint <= coreRange.end.seconds))
    }
}

struct CaptionRecognitionChunkPlan: Equatable, Sendable {
    let chunks: [CaptionRecognitionChunk]

    init(
        sourceRange: TakeRange,
        coreDuration: TimeInterval = 50,
        contextPadding: TimeInterval = 1
    ) throws {
        guard sourceRange.start.seconds.isFinite,
              sourceRange.end.seconds.isFinite,
              sourceRange.start.seconds >= 0,
              sourceRange.duration > 0,
              coreDuration > 0,
              contextPadding >= 0 else {
            throw CaptionTranscriptionError.invalidSourceRange
        }
        var result: [CaptionRecognitionChunk] = []
        var coreStart = sourceRange.start.seconds
        while coreStart < sourceRange.end.seconds {
            let coreEnd = min(coreStart + coreDuration, sourceRange.end.seconds)
            result.append(CaptionRecognitionChunk(
                coreRange: TakeRange(startSeconds: coreStart, endSeconds: coreEnd),
                extractionRange: TakeRange(
                    startSeconds: max(sourceRange.start.seconds, coreStart - contextPadding),
                    endSeconds: min(sourceRange.end.seconds, coreEnd + contextPadding)
                ),
                includesUpperBound: coreEnd == sourceRange.end.seconds
            ))
            coreStart = coreEnd
        }
        chunks = result
    }
}

struct CaptionRecognitionChunkResult: Equatable, Sendable {
    let chunk: CaptionRecognitionChunk
    let units: [CaptionRecognizedUnit]
}

struct CaptionRecognitionChunkReconciler: Sendable {
    func reconcile(_ results: [CaptionRecognitionChunkResult]) -> [CaptionRecognizedUnit] {
        let owned = results.flatMap { result in
            result.units.filter { result.chunk.owns(segmentRange: $0.range) }
        }
        var reconciled: [CaptionRecognizedUnit] = []
        for unit in owned.sorted(by: { $0.range.start.seconds < $1.range.start.seconds }) {
            if let index = reconciled.lastIndex(where: { isDuplicate($0, unit) }) {
                if preferred(unit, over: reconciled[index]) {
                    reconciled[index] = unit
                }
            } else {
                reconciled.append(unit)
            }
        }
        return removingCompositeDuplicates(from: reconciled)
            .sorted { $0.range.start.seconds < $1.range.start.seconds }
    }

    private func isDuplicate(_ first: CaptionRecognizedUnit, _ second: CaptionRecognizedUnit) -> Bool {
        guard normalized(first.text) == normalized(second.text) else { return false }
        let intersectionStart = max(first.range.start.seconds, second.range.start.seconds)
        let intersectionEnd = min(first.range.end.seconds, second.range.end.seconds)
        return intersectionEnd > intersectionStart
            || abs(first.range.start.seconds - second.range.start.seconds) <= 0.35
    }

    private func preferred(_ candidate: CaptionRecognizedUnit, over current: CaptionRecognizedUnit) -> Bool {
        let candidateConfidence = candidate.confidence ?? -1
        let currentConfidence = current.confidence ?? -1
        if candidateConfidence != currentConfidence { return candidateConfidence > currentConfidence }
        return candidate.range.duration > current.range.duration
    }

    private func removingCompositeDuplicates(
        from units: [CaptionRecognizedUnit]
    ) -> [CaptionRecognizedUnit] {
        units.filter { candidate in
            let candidateWords = normalized(candidate.text).split(whereSeparator: { $0.isWhitespace })
            guard candidateWords.count > 1 else { return true }
            let components = units.filter { component in
                component != candidate
                    && component.granularity == .word
                    && component.range.end.seconds >= candidate.range.start.seconds - 0.35
                    && component.range.start.seconds <= candidate.range.end.seconds + 0.35
            }
            .sorted { $0.range.start.seconds < $1.range.start.seconds }
            let componentText = components.map { normalized($0.text) }.joined(separator: " ")
            return componentText != normalized(candidate.text)
        }
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
