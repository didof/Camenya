import Foundation

enum CaptionPlacementZone: String, Codable, Equatable, Hashable, Sendable {
    case lower
    case center
    case upper
}

enum CaptionStylePreset: String, Codable, Equatable, Hashable, Sendable {
    case highContrast
}

struct ProjectCaptionConfiguration: Codable, Equatable, Hashable, Sendable {
    let localeIdentifier: String
    var placement: CaptionPlacementZone
    var style: CaptionStylePreset

    init(
        localeIdentifier: String,
        placement: CaptionPlacementZone,
        style: CaptionStylePreset = .highContrast
    ) {
        self.localeIdentifier = localeIdentifier
        self.placement = placement
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case localeIdentifier
        case placement
        case style
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        localeIdentifier = try values.decode(String.self, forKey: .localeIdentifier)
        placement = try values.decode(CaptionPlacementZone.self, forKey: .placement)
        style = try values.decodeIfPresent(CaptionStylePreset.self, forKey: .style) ?? .highContrast
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
}

struct TakeCaptionTrack: Codable, Equatable, Hashable, Sendable {
    let localeIdentifier: String
    let sourceRange: TakeRange
    let recognizer: CaptionRecognizerGeneration
    var reviewState: CaptionReviewState
    var cues: [CaptionCue]
}

enum CaptionTimelineIssueReason: String, Codable, Equatable, Hashable, Sendable {
    case boundaryCut
    case discontinuousProjection
}

enum CaptionTimelineIssueReviewState: String, Codable, Equatable, Hashable, Sendable {
    case needsReview
    case approved
}

struct CaptionTimelineFragment: Codable, Equatable, Hashable, Sendable {
    let clipID: TimelineClip.ID
    let sourceRange: TakeRange
}

struct CaptionTimelineIssue: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let takeID: UUID
    let cueID: UUID
    let fragments: [CaptionTimelineFragment]
    let reason: CaptionTimelineIssueReason
    var reviewState: CaptionTimelineIssueReviewState

    init(
        id: UUID = UUID(),
        takeID: UUID,
        cueID: UUID,
        fragments: [CaptionTimelineFragment],
        reason: CaptionTimelineIssueReason,
        reviewState: CaptionTimelineIssueReviewState = .needsReview
    ) {
        self.id = id
        self.takeID = takeID
        self.cueID = cueID
        self.fragments = fragments
        self.reason = reason
        self.reviewState = reviewState
    }
}

enum CaptionTranscriptionScope: Equatable, Sendable {
    case missingOrOutdated
    case all
}

enum CaptionTranscriptionSelection {
    static func takeIDs(
        from takes: [ProjectTake],
        configuration: ProjectCaptionConfiguration,
        scope: CaptionTranscriptionScope
    ) -> [UUID] {
        takes.compactMap { take in
            if scope == .all { return take.id }
            guard take.captions?.reviewState != .approved
                    || take.captions?.localeIdentifier != configuration.localeIdentifier else {
                return nil
            }
            return take.id
        }
    }
}
