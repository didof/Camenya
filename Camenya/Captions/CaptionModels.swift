import Foundation

enum CaptionPlacementZone: String, Codable, Equatable, Hashable, Sendable {
    case lower
    case center
    case upper
}

enum CaptionStylePreset: String, Codable, Equatable, Hashable, Sendable {
    case highContrast
    case clean
    case impact
    case minimal
    case custom
}

enum CaptionFontDesign: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case system, rounded, serif
}

enum CaptionFontScale: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case small, standard, large
}

enum CaptionTextColor: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case white, yellow
}

enum CaptionHighlightStyle: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case none, coloredText, pill
}

enum CaptionAccentColor: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case yellow, cyan, green, pink
}

enum CaptionBackgroundStyle: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case none, shadow, roundedBox
}

enum CaptionContainerOpacity: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case light, medium, strong
}

struct CaptionStyleCustomization: Codable, Equatable, Hashable, Sendable {
    var fontDesign: CaptionFontDesign = .system
    var fontScale: CaptionFontScale = .standard
    var textColor: CaptionTextColor = .white
    var highlighting: CaptionHighlightStyle = .coloredText
    var accentColor: CaptionAccentColor = .yellow
    var background: CaptionBackgroundStyle = .roundedBox
    var containerOpacity: CaptionContainerOpacity = .medium
}

enum CaptionTextDensity: String, Codable, Equatable, Hashable, Sendable {
    case less
    case standard
    case more
}

struct ProjectCaptionConfiguration: Codable, Equatable, Hashable, Sendable {
    let localeIdentifier: String
    var placement: CaptionPlacementZone
    var style: CaptionStylePreset
    var density: CaptionTextDensity
    var customization: CaptionStyleCustomization

    init(
        localeIdentifier: String,
        placement: CaptionPlacementZone,
        style: CaptionStylePreset = .clean,
        density: CaptionTextDensity = .standard,
        customization: CaptionStyleCustomization = CaptionStyleCustomization()
    ) {
        self.localeIdentifier = localeIdentifier
        self.placement = placement
        self.style = style
        self.density = density
        self.customization = customization
    }

    private enum CodingKeys: String, CodingKey {
        case localeIdentifier
        case placement
        case style
        case density
        case customization
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        localeIdentifier = try values.decode(String.self, forKey: .localeIdentifier)
        placement = try values.decode(CaptionPlacementZone.self, forKey: .placement)
        style = try values.decodeIfPresent(CaptionStylePreset.self, forKey: .style) ?? .highContrast
        density = try values.decodeIfPresent(CaptionTextDensity.self, forKey: .density) ?? .standard
        customization = try values.decodeIfPresent(
            CaptionStyleCustomization.self,
            forKey: .customization
        ) ?? CaptionStyleCustomization()
    }
}

enum CaptionStyleDraftPolicy {
    static func densityOnlyConfiguration(
        draft: ProjectCaptionConfiguration,
        persisted: ProjectCaptionConfiguration
    ) -> ProjectCaptionConfiguration {
        var result = persisted
        result.density = draft.density
        return result
    }
}

enum CaptionRecognizerGeneration: String, Codable, Equatable, Hashable, Sendable {
    case speechRecognizerIOS18
    case speechAnalyzerIOS26
}

enum CaptionReviewState: String, Codable, Equatable, Hashable, Sendable {
    case needsReview
    case approved
    case stale
}

enum CaptionTimingGranularity: String, Codable, Equatable, Hashable, Sendable {
    case word
    case segment
}

struct CaptionTimedSpan: Codable, Equatable, Hashable, Sendable {
    let range: TakeRange
    let text: String
    let granularity: CaptionTimingGranularity
    let confidence: Double?
    let alternatives: [String]

    init(
        range: TakeRange,
        text: String,
        granularity: CaptionTimingGranularity,
        confidence: Double?,
        alternatives: [String] = []
    ) {
        self.range = range
        self.text = text
        self.granularity = granularity
        self.confidence = confidence
        self.alternatives = alternatives
    }

    private enum CodingKeys: String, CodingKey {
        case range, text, granularity, confidence, alternatives
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        range = try values.decode(TakeRange.self, forKey: .range)
        text = try values.decode(String.self, forKey: .text)
        granularity = try values.decode(CaptionTimingGranularity.self, forKey: .granularity)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        alternatives = try values.decodeIfPresent([String].self, forKey: .alternatives) ?? []
    }
}

struct CaptionCue: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var range: TakeRange
    let recognizedRange: TakeRange
    let recognizedText: String
    var text: String
    let confidence: Double?
    let alternatives: [String]
    var timedSpans: [CaptionTimedSpan]
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        range: TakeRange,
        recognizedRange: TakeRange? = nil,
        recognizedText: String,
        text: String,
        confidence: Double?,
        alternatives: [String],
        timedSpans: [CaptionTimedSpan],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.range = range
        self.recognizedRange = recognizedRange ?? range
        self.recognizedText = recognizedText
        self.text = text
        self.confidence = confidence
        self.alternatives = alternatives
        self.timedSpans = timedSpans
        self.isEnabled = isEnabled
    }

    var wasEdited: Bool { text != recognizedText }
    var timingWasEdited: Bool { range != recognizedRange }

    var hasTrustworthyWordTiming: Bool {
        !timingWasEdited
            && !timedSpans.isEmpty
            && timedSpans.allSatisfy { $0.granularity == .word }
            && timedSpans.flatMap { Self.lexicalTokens(in: $0.text) }
                == Self.lexicalTokens(in: recognizedText)
            && Self.lexicalTokens(in: text) == Self.lexicalTokens(in: recognizedText)
    }

    private static func lexicalTokens(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

struct TakeCaptionTrack: Codable, Equatable, Hashable, Sendable {
    let localeIdentifier: String
    let sourceRange: TakeRange
    let recognizer: CaptionRecognizerGeneration
    var reviewState: CaptionReviewState
    var cues: [CaptionCue]
}

enum ProjectCaptionRegionState: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case completed
}

struct ProjectCaptionRegion: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let languageRegionID: UUID
    let clipID: TimelineClip.ID
    let takeID: UUID
    let sourceRange: TakeRange
    let projectTimeRange: ProjectTimeRange
    let localeIdentifier: String
    var state: ProjectCaptionRegionState
    var recognizer: CaptionRecognizerGeneration?

    init(
        id: UUID = UUID(),
        languageRegionID: UUID? = nil,
        clipID: TimelineClip.ID,
        takeID: UUID,
        sourceRange: TakeRange,
        projectTimeRange: ProjectTimeRange,
        localeIdentifier: String,
        state: ProjectCaptionRegionState = .pending,
        recognizer: CaptionRecognizerGeneration? = nil
    ) {
        self.id = id
        self.languageRegionID = languageRegionID ?? id
        self.clipID = clipID
        self.takeID = takeID
        self.sourceRange = sourceRange
        self.projectTimeRange = projectTimeRange
        self.localeIdentifier = localeIdentifier
        self.state = state
        self.recognizer = recognizer
    }
}

struct ProjectCaptionTrack: Codable, Equatable, Hashable, Sendable {
    let pictureLockID: UUID
    var reviewState: CaptionReviewState
    var regions: [ProjectCaptionRegion]
    var cues: [CaptionCue]

    var pendingRegions: [ProjectCaptionRegion] {
        regions.filter { $0.state == .pending }
    }

    var completedRegions: [ProjectCaptionRegion] {
        regions.filter { $0.state == .completed }
    }

    var isGenerationComplete: Bool { pendingRegions.isEmpty }
    var languageRegionCount: Int { Set(regions.map(\.languageRegionID)).count }
}

enum ProjectCaptionTimeRebaser {
    static func rebase(_ cue: CaptionCue, from region: ProjectCaptionRegion) -> CaptionCue {
        CaptionCue(
            id: cue.id,
            range: rebase(cue.range, from: region),
            recognizedRange: rebase(cue.recognizedRange, from: region),
            recognizedText: cue.recognizedText,
            text: cue.text,
            confidence: cue.confidence,
            alternatives: cue.alternatives,
            timedSpans: cue.timedSpans.map { span in
                CaptionTimedSpan(
                    range: rebase(span.range, from: region),
                    text: span.text,
                    granularity: span.granularity,
                    confidence: span.confidence,
                    alternatives: span.alternatives
                )
            },
            isEnabled: cue.isEnabled
        )
    }

    private static func rebase(
        _ range: TakeRange,
        from region: ProjectCaptionRegion
    ) -> TakeRange {
        let offset = region.projectTimeRange.start.seconds - region.sourceRange.start.seconds
        return TakeRange(
            startSeconds: range.start.seconds + offset,
            endSeconds: range.end.seconds + offset
        )
    }
}

enum ProjectCaptionTrackValidator {
    static func canComplete(
        _ track: ProjectCaptionTrack,
        duration: TimeInterval,
        format: ProjectFormat,
        configuration: ProjectCaptionConfiguration
    ) -> Bool {
        guard track.isGenerationComplete, duration.isFinite, duration >= 0 else { return false }
        let canvas = format == .portrait
            ? CGSize(width: 1080, height: 1920)
            : CGSize(width: 1920, height: 1080)
        let cues = track.cues.filter(\.isEnabled).sorted {
            $0.range.start.seconds < $1.range.start.seconds
        }
        var previousEnd: TimeInterval = 0
        for cue in cues {
            guard cue.range.start.seconds.isFinite,
                  cue.range.end.seconds.isFinite,
                  cue.range.duration > 0,
                  cue.range.start.seconds >= previousEnd,
                  cue.range.start.seconds >= 0,
                  cue.range.end.seconds <= duration,
                  !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  CaptionLineComposer.fits(cue.text, configuration: configuration, canvas: canvas) else {
                return false
            }
            previousEnd = cue.range.end.seconds
        }
        return true
    }
}

enum CaptionDensityReflow {
    private static let maximumContinuousGap: TimeInterval = 0.45

    private struct WordTargets {
        let minimum: Int
        let preferred: Int
        let maximum: Int
        let maximumDuration: TimeInterval
    }

    static func apply(
        _ density: CaptionTextDensity,
        to cues: [CaptionCue],
        regions: [ProjectCaptionRegion] = [],
        configuration: ProjectCaptionConfiguration? = nil,
        format: ProjectFormat = .portrait
    ) -> [CaptionCue] {
        var resolvedConfiguration = configuration
            ?? ProjectCaptionConfiguration(localeIdentifier: "und", placement: .lower)
        resolvedConfiguration.density = density
        let canvas = format == .portrait
            ? CGSize(width: 1080, height: 1920)
            : CGSize(width: 1920, height: 1080)
        var output: [CaptionCue] = []
        var eligibleRun: [CaptionCue] = []
        var eligibleRegionID: UUID?

        func regionID(for cue: CaptionCue) -> UUID? {
            regions.first(where: {
                cue.range.start.seconds >= $0.projectTimeRange.start.seconds
                    && cue.range.end.seconds <= $0.projectTimeRange.end.seconds
            })?.languageRegionID
        }

        func flushRun() {
            guard !eligibleRun.isEmpty else { return }
            let spans = eligibleRun.flatMap(\.timedSpans)
            guard !spans.isEmpty else {
                output.append(contentsOf: eligibleRun)
                eligibleRun.removeAll()
                eligibleRegionID = nil
                return
            }
            let targets = wordTargets(for: density)
            let sourceCueBoundaries = Set(eligibleRun.map(\.range.end))
            var startIndex = spans.startIndex

            func appendChunk(_ chunk: ArraySlice<CaptionTimedSpan>) {
                guard let first = chunk.first, let last = chunk.last else { return }
                let text = chunk.map(\.text).joined(separator: " ")
                output.append(CaptionCue(
                    range: TakeRange(start: first.range.start, end: last.range.end),
                    recognizedText: text,
                    text: text,
                    confidence: chunk.compactMap(\.confidence).min(),
                    alternatives: [],
                    timedSpans: Array(chunk)
                ))
            }

            while startIndex < spans.endIndex {
                var continuousEnd = startIndex + 1
                while continuousEnd < spans.endIndex,
                      spans[continuousEnd].range.start.seconds
                        - spans[continuousEnd - 1].range.end.seconds <= maximumContinuousGap {
                    continuousEnd += 1
                }
                let remainingCount = continuousEnd - startIndex
                let maximumCandidate = min(targets.maximum, remainingCount)
                let candidates = (1...maximumCandidate).map { count -> (count: Int, score: Double) in
                    let chunk = spans[startIndex..<(startIndex + count)]
                    let text = chunk.map(\.text).joined(separator: " ")
                    let duration = (chunk.last?.range.end.seconds ?? 0)
                        - (chunk.first?.range.start.seconds ?? 0)
                    var score = Double(abs(count - targets.preferred)) * 2
                    if count < targets.minimum {
                        score += Double(targets.minimum - count) * 8
                    }
                    if !CaptionLineComposer.fits(
                        text,
                        configuration: resolvedConfiguration,
                        canvas: canvas
                    ) {
                        score += 1_000
                    }
                    if let lastText = chunk.last?.text
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       let punctuation = lastText.last {
                        if ".!?".contains(punctuation) { score -= 5 }
                        else if ",;:".contains(punctuation) { score -= 2 }
                    }
                    if let boundary = chunk.last?.range.end,
                       sourceCueBoundaries.contains(boundary) {
                        score -= 1.5
                    }
                    if duration > targets.maximumDuration {
                        score += (duration - targets.maximumDuration) * 3
                    }
                    if duration < 0.8 { score += (0.8 - duration) * 4 }
                    return (count, score)
                }
                let selectedCount = candidates.min { lhs, rhs in
                    if lhs.score == rhs.score { return lhs.count > rhs.count }
                    return lhs.score < rhs.score
                }?.count ?? maximumCandidate
                appendChunk(spans[startIndex..<(startIndex + selectedCount)])
                startIndex += selectedCount
                if startIndex == continuousEnd { continue }
            }
            eligibleRun.removeAll()
            eligibleRegionID = nil
        }

        for cue in cues.sorted(by: { $0.range.start.seconds < $1.range.start.seconds }) {
            let cueRegionID = regionID(for: cue)
            let isEligible = !cue.wasEdited
                && !cue.timingWasEdited
                && cue.hasTrustworthyWordTiming
                && (regions.isEmpty || cueRegionID != nil)
            if isEligible {
                if let previous = eligibleRun.last,
                   cue.range.start.seconds - previous.range.end.seconds > maximumContinuousGap
                    || (!eligibleRun.isEmpty && cueRegionID != eligibleRegionID) {
                    flushRun()
                }
                eligibleRun.append(cue)
                eligibleRegionID = cueRegionID
            } else {
                flushRun()
                output.append(cue)
            }
        }
        flushRun()
        return output
    }

    private static func wordTargets(for density: CaptionTextDensity) -> WordTargets {
        switch density {
        case .less: WordTargets(minimum: 3, preferred: 4, maximum: 5, maximumDuration: 3.5)
        case .standard: WordTargets(minimum: 5, preferred: 7, maximum: 8, maximumDuration: 4.5)
        case .more: WordTargets(minimum: 8, preferred: 10, maximum: 12, maximumDuration: 6)
        }
    }
}

enum ProjectCaptionWaveformBuilder {
    static func make(
        lock: ProjectPictureLock,
        takes: [ProjectTake],
        envelopes: [UUID: [Float]],
        sampleCount: Int = 240
    ) -> [Float] {
        guard sampleCount > 0, lock.duration.seconds > 0 else { return [] }
        let takesByID = Dictionary(uniqueKeysWithValues: takes.map { ($0.id, $0) })
        var cursor: TimeInterval = 0
        let segments = lock.clips.map { clip -> (TimelineClip, Range<TimeInterval>) in
            let start = cursor
            cursor += clip.selection.duration
            return (clip, start..<cursor)
        }
        return (0..<sampleCount).map { index in
            let projectTime = lock.duration.seconds * (Double(index) + 0.5) / Double(sampleCount)
            guard let segment = segments.first(where: { $0.1.contains(projectTime) }),
                  let take = takesByID[segment.0.takeID],
                  let envelope = envelopes[take.id],
                  !envelope.isEmpty,
                  take.duration > 0 else { return 0 }
            let sourceTime = segment.0.selection.start.seconds
                + projectTime - segment.1.lowerBound
            let sourceFraction = min(max(0, sourceTime / take.duration), 0.999_999)
            let envelopeIndex = min(
                envelope.count - 1,
                Int(sourceFraction * Double(envelope.count))
            )
            return envelope[envelopeIndex]
        }
    }
}

enum CaptionPresentationComposer {
    static func compose(
        _ cues: [CaptionCue],
        configuration: ProjectCaptionConfiguration,
        format: ProjectFormat
    ) -> [CaptionCue] {
        let canvas = format == .portrait
            ? CGSize(width: 1080, height: 1920)
            : CGSize(width: 1920, height: 1080)
        return cues.flatMap { cue in
            guard !CaptionLineComposer.fits(
                cue.text,
                configuration: configuration,
                canvas: canvas
            ), cue.hasTrustworthyWordTiming else { return [cue] }

            var output: [CaptionCue] = []
            var chunk: [CaptionTimedSpan] = []
            func flush() {
                guard let first = chunk.first, let last = chunk.last else { return }
                let text = chunk.map(\.text).joined(separator: " ")
                output.append(CaptionCue(
                    range: TakeRange(start: first.range.start, end: last.range.end),
                    recognizedText: text,
                    text: text,
                    confidence: chunk.compactMap(\.confidence).min(),
                    alternatives: [],
                    timedSpans: chunk,
                    isEnabled: cue.isEnabled
                ))
                chunk.removeAll()
            }

            for span in cue.timedSpans {
                let candidate = (chunk + [span]).map(\.text).joined(separator: " ")
                if !chunk.isEmpty,
                   !CaptionLineComposer.fits(
                       candidate,
                       configuration: configuration,
                       canvas: canvas
                   ) {
                    flush()
                }
                chunk.append(span)
            }
            flush()
            return output.isEmpty ? [cue] : output
        }
    }
}
