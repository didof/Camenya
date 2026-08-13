import Foundation

enum ProjectFormat: String, Codable, Equatable, Hashable, Sendable {
    case portrait
    case landscape

    init(orientation: TakeOrientation) {
        switch orientation {
        case .portrait: self = .portrait
        case .landscapeLeft, .landscapeRight: self = .landscape
        }
    }
}

enum ProjectRecoveryState: String, Codable, Equatable, Hashable, Sendable {
    case clean
    case pendingExport
    case photosSaveCompleted
}

struct MediaTime: Codable, Equatable, Hashable, Sendable {
    let value: Int64
    let timescale: Int32

    init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    init(seconds: TimeInterval, preferredTimescale: Int32 = 600) {
        timescale = preferredTimescale
        value = Int64((seconds * Double(preferredTimescale)).rounded())
    }

    var seconds: TimeInterval {
        guard timescale > 0 else { return .nan }
        return TimeInterval(value) / TimeInterval(timescale)
    }
}

struct TakeRange: Codable, Equatable, Hashable, Sendable {
    let start: MediaTime
    let end: MediaTime

    init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.end = end
    }

    init(startSeconds: TimeInterval, endSeconds: TimeInterval) {
        start = MediaTime(seconds: startSeconds)
        end = MediaTime(seconds: endSeconds)
    }

    var duration: TimeInterval {
        end.seconds - start.seconds
    }

    func isValid(inside originalDuration: TimeInterval, minimumDuration: TimeInterval) -> Bool {
        let startSeconds = start.seconds
        let endSeconds = end.seconds
        return startSeconds.isFinite
            && endSeconds.isFinite
            && originalDuration.isFinite
            && startSeconds >= 0
            && endSeconds <= originalDuration
            && duration >= minimumDuration
    }
}

enum TrimReviewDecision: Codable, Equatable, Hashable, Sendable {
    case keepOriginal
    case useSelection(TakeRange)
}

enum EffectiveTakeRange: Equatable, Sendable {
    case original
    case selection(TakeRange)
    case invalid
}

struct TrimSuggestion: Codable, Equatable, Hashable, Sendable {
    let range: TakeRange
    let algorithmVersion: Int
    let envelopeFileName: String?
}

enum TrimAnalysisResult: Codable, Equatable, Hashable, Sendable {
    case suggestion(TrimSuggestion)
    case noSuggestion(TrimNoSuggestionReason)
    case failed(TrimAnalysisFailure)
}

enum TrimNoSuggestionReason: String, Codable, Equatable, Hashable, Sendable {
    case missingAudio
    case noSustainedActivity
    case negligibleSaving
    case selectionTooShort
}

enum TrimAnalysisFailure: String, Codable, Equatable, Hashable, Sendable {
    case unreadableMedia
    case decodingFailed
}

struct ProjectTake: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let movieFileName: String
    var thumbnailFileName: String?
    var trimAnalysis: TrimAnalysisResult?
    var trimDecision: TrimReviewDecision?
    var captions: TakeCaptionTrack?

    init(
        id: UUID = UUID(),
        createdAt: Date,
        duration: TimeInterval,
        movieFileName: String = "take.mov",
        thumbnailFileName: String? = nil,
        trimAnalysis: TrimAnalysisResult? = nil,
        trimDecision: TrimReviewDecision? = nil,
        captions: TakeCaptionTrack? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.movieFileName = movieFileName
        self.thumbnailFileName = thumbnailFileName
        self.trimAnalysis = trimAnalysis
        self.trimDecision = trimDecision
        self.captions = captions
    }

    var effectiveDuration: TimeInterval {
        switch effectiveRange {
        case .original: return max(0, duration)
        case let .selection(range): return range.duration
        case .invalid: return 0
        }
    }

    var effectiveRange: EffectiveTakeRange {
        switch trimDecision {
        case .keepOriginal, nil:
            return .original
        case let .useSelection(range):
            return range.isValid(inside: duration, minimumDuration: 1) ? .selection(range) : .invalid
        }
    }

    var concreteEffectiveRange: TakeRange? {
        switch effectiveRange {
        case .original:
            TakeRange(startSeconds: 0, endSeconds: duration)
        case let .selection(range):
            range
        case .invalid:
            nil
        }
    }
}

struct ProjectManifest: Codable, Equatable, Hashable, Identifiable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var modifiedAt: Date
    var name: String
    var format: ProjectFormat?
    var note: String
    var takes: [ProjectTake]
    var recoveryState: ProjectRecoveryState?
    var captionConfiguration: ProjectCaptionConfiguration?

    init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date,
        modifiedAt: Date,
        name: String,
        format: ProjectFormat? = nil,
        note: String = "",
        takes: [ProjectTake] = [],
        recoveryState: ProjectRecoveryState? = .clean,
        captionConfiguration: ProjectCaptionConfiguration? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.name = name
        self.format = format
        self.note = note
        self.takes = takes
        self.recoveryState = recoveryState
        self.captionConfiguration = captionConfiguration
    }

    var approximateDuration: TimeInterval {
        takes.reduce(0) { $0 + $1.effectiveDuration }
    }
}
