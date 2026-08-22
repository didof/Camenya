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
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              originalDuration.isFinite else {
            return false
        }
        let quantizedOriginalEnd = MediaTime(seconds: originalDuration).seconds
        return startSeconds >= 0
            && endSeconds <= quantizedOriginalEnd
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
    static let currentSchemaVersion = 7

    var schemaVersion: Int
    var manifestRevision: UInt64
    let id: UUID
    let createdAt: Date
    var modifiedAt: Date
    var name: String
    var isAutomaticallyNamed: Bool
    var format: ProjectFormat?
    var note: String
    var takes: [ProjectTake]
    var primaryStoryline: PrimaryStoryline
    var removedClips: [RemovedTimelineClip]
    var recoveryState: ProjectRecoveryState?
    var captionConfiguration: ProjectCaptionConfiguration?
    var captionTimelineIssues: [CaptionTimelineIssue]

    init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        manifestRevision: UInt64 = 0,
        id: UUID = UUID(),
        createdAt: Date,
        modifiedAt: Date,
        name: String,
        isAutomaticallyNamed: Bool = false,
        format: ProjectFormat? = nil,
        note: String = "",
        takes: [ProjectTake] = [],
        primaryStoryline: PrimaryStoryline? = nil,
        removedClips: [RemovedTimelineClip] = [],
        recoveryState: ProjectRecoveryState? = .clean,
        captionConfiguration: ProjectCaptionConfiguration? = nil,
        captionTimelineIssues: [CaptionTimelineIssue] = []
    ) {
        self.schemaVersion = schemaVersion
        self.manifestRevision = manifestRevision
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.name = name
        self.isAutomaticallyNamed = isAutomaticallyNamed
        self.format = format
        self.note = note
        self.takes = takes
        self.primaryStoryline = primaryStoryline ?? .migrating(takes: takes)
        self.removedClips = removedClips
        self.recoveryState = recoveryState
        self.captionConfiguration = captionConfiguration
        self.captionTimelineIssues = captionTimelineIssues
    }

    var approximateDuration: TimeInterval {
        primaryStoryline.clips.reduce(0) { $0 + $1.selection.duration }
    }

    var unusedTakes: [ProjectTake] {
        takes.filter { !referencedTakeIDs.contains($0.id) }
    }

    var usedTakes: [ProjectTake] {
        takes.filter { referencedTakeIDs.contains($0.id) }
    }

    private var referencedTakeIDs: Set<UUID> {
        Set(primaryStoryline.clips.map(\.takeID))
            .union(removedClips.map { $0.clip.takeID })
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case manifestRevision
        case id
        case createdAt
        case modifiedAt
        case name
        case isAutomaticallyNamed
        case format
        case note
        case takes
        case primaryStoryline
        case removedClips
        case recoveryState
        case captionConfiguration
        case captionTimelineIssues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        manifestRevision = try container.decodeIfPresent(UInt64.self, forKey: .manifestRevision) ?? 0
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        name = try container.decode(String.self, forKey: .name)
        isAutomaticallyNamed = try container.decodeIfPresent(
            Bool.self,
            forKey: .isAutomaticallyNamed
        ) ?? false
        format = try container.decodeIfPresent(ProjectFormat.self, forKey: .format)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        takes = try container.decodeIfPresent([ProjectTake].self, forKey: .takes) ?? []
        primaryStoryline = try container.decodeIfPresent(
            PrimaryStoryline.self,
            forKey: .primaryStoryline
        ) ?? .migrating(takes: takes)
        removedClips = try container.decodeIfPresent(
            [RemovedTimelineClip].self,
            forKey: .removedClips
        ) ?? []
        recoveryState = try container.decodeIfPresent(ProjectRecoveryState.self, forKey: .recoveryState)
        captionConfiguration = try container.decodeIfPresent(
            ProjectCaptionConfiguration.self,
            forKey: .captionConfiguration
        )
        captionTimelineIssues = try container.decodeIfPresent(
            [CaptionTimelineIssue].self,
            forKey: .captionTimelineIssues
        ) ?? []
    }
}
