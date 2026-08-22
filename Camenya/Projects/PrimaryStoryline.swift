import Foundation

struct StorylineRevision: Codable, Equatable, Hashable, Comparable, Sendable {
    static let zero = StorylineRevision(rawValue: 0)

    let rawValue: UInt64

    func incremented() throws -> StorylineRevision {
        guard rawValue < UInt64.max else { throw TimelineEditorError.revisionExhausted }
        return StorylineRevision(rawValue: rawValue + 1)
    }

    static func < (lhs: StorylineRevision, rhs: StorylineRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TimelineClip: Codable, Equatable, Hashable, Identifiable, Sendable {
    struct ID: Codable, Equatable, Hashable, Sendable {
        let rawValue: UUID

        init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    struct SplitBoundaryID: Codable, Equatable, Hashable, Sendable {
        let rawValue: UUID

        init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    let id: ID
    let takeID: UUID
    let availableRange: TakeRange
    let selection: TakeRange
    let isMuted: Bool
    let leadingSplitBoundaryID: SplitBoundaryID?
    let trailingSplitBoundaryID: SplitBoundaryID?

    init(
        id: ID = ID(),
        takeID: UUID,
        availableRange: TakeRange,
        selection: TakeRange,
        isMuted: Bool = false,
        leadingSplitBoundaryID: SplitBoundaryID? = nil,
        trailingSplitBoundaryID: SplitBoundaryID? = nil
    ) {
        self.id = id
        self.takeID = takeID
        self.availableRange = availableRange
        self.selection = selection
        self.isMuted = isMuted
        self.leadingSplitBoundaryID = leadingSplitBoundaryID
        self.trailingSplitBoundaryID = trailingSplitBoundaryID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case takeID
        case availableRange
        case selection
        case isMuted
        case leadingSplitBoundaryID
        case trailingSplitBoundaryID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        takeID = try container.decode(UUID.self, forKey: .takeID)
        availableRange = try container.decode(TakeRange.self, forKey: .availableRange)
        selection = try container.decode(TakeRange.self, forKey: .selection)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        leadingSplitBoundaryID = try container.decodeIfPresent(
            SplitBoundaryID.self,
            forKey: .leadingSplitBoundaryID
        )
        trailingSplitBoundaryID = try container.decodeIfPresent(
            SplitBoundaryID.self,
            forKey: .trailingSplitBoundaryID
        )
    }
}

struct TimelinePlacementContext: Codable, Equatable, Hashable, Sendable {
    let previousClipID: TimelineClip.ID?
    let nextClipID: TimelineClip.ID?
    let originalIndex: Int
}

struct RemovedTimelineClip: Codable, Equatable, Hashable, Identifiable, Sendable {
    let clip: TimelineClip
    let placement: TimelinePlacementContext

    var id: TimelineClip.ID { clip.id }
}

struct PrimaryStoryline: Codable, Equatable, Hashable, Sendable {
    var revision: StorylineRevision
    var clips: [TimelineClip]

    init(revision: StorylineRevision = .zero, clips: [TimelineClip] = []) {
        self.revision = revision
        self.clips = clips
    }

    static func migrating(takes: [ProjectTake]) -> PrimaryStoryline {
        PrimaryStoryline(clips: takes.map { take in
            let availableRange = TakeRange(startSeconds: 0, endSeconds: take.duration)
            return TimelineClip(
                takeID: take.id,
                availableRange: availableRange,
                selection: take.concreteEffectiveRange ?? availableRange
            )
        })
    }
}

struct ProjectTime: Codable, Equatable, Hashable, Sendable {
    static let zero = ProjectTime(mediaTime: MediaTime(value: 0, timescale: 600))

    let mediaTime: MediaTime

    init(mediaTime: MediaTime) {
        self.mediaTime = mediaTime
    }

    init(seconds: TimeInterval) {
        mediaTime = seconds.isFinite
            ? MediaTime(seconds: seconds)
            : MediaTime(value: 0, timescale: 0)
    }

    var seconds: TimeInterval { mediaTime.seconds }
}

struct ProjectTimeRange: Codable, Equatable, Hashable, Sendable {
    let start: ProjectTime
    let end: ProjectTime

    var duration: TimeInterval { end.seconds - start.seconds }
}

struct ExportSnapshot: Equatable, Sendable {
    struct Clip: Equatable, Sendable, Identifiable {
        let id: TimelineClip.ID
        let takeID: UUID
        let mediaURL: URL
        let thumbnailURL: URL?
        let sourceCreatedAt: Date?
        let sourceRange: TakeRange
        let availableRange: TakeRange
        let selection: TakeRange
        let trimSuggestion: TakeRange?
        let isMuted: Bool
        let projectTimeRange: ProjectTimeRange

        init(
            id: TimelineClip.ID,
            takeID: UUID,
            mediaURL: URL,
            thumbnailURL: URL? = nil,
            sourceCreatedAt: Date? = nil,
            sourceRange: TakeRange,
            availableRange: TakeRange,
            selection: TakeRange,
            trimSuggestion: TakeRange? = nil,
            isMuted: Bool = false,
            projectTimeRange: ProjectTimeRange
        ) {
            self.id = id
            self.takeID = takeID
            self.mediaURL = mediaURL
            self.thumbnailURL = thumbnailURL
            self.sourceCreatedAt = sourceCreatedAt
            self.sourceRange = sourceRange
            self.availableRange = availableRange
            self.selection = selection
            self.trimSuggestion = trimSuggestion
            self.isMuted = isMuted
            self.projectTimeRange = projectTimeRange
        }
    }

    let projectID: UUID
    let revision: StorylineRevision
    let format: ProjectFormat?
    let captionConfiguration: ProjectCaptionConfiguration?
    let captionTimeline: ProjectCaptionExportTimeline?
    let finishingTimeline: ProjectFinishingTimeline?
    let clips: [Clip]
    let duration: ProjectTime

    init(
        projectID: UUID,
        revision: StorylineRevision,
        format: ProjectFormat?,
        captionConfiguration: ProjectCaptionConfiguration?,
        captionTimeline: ProjectCaptionExportTimeline? = nil,
        finishingTimeline: ProjectFinishingTimeline? = nil,
        clips: [Clip],
        duration: ProjectTime
    ) {
        self.projectID = projectID
        self.revision = revision
        self.format = format
        self.captionConfiguration = captionConfiguration
        self.captionTimeline = captionTimeline
        self.finishingTimeline = finishingTimeline
        self.clips = clips
        self.duration = duration
    }

    func position(at projectTime: ProjectTime) -> StorylinePosition? {
        let seconds = projectTime.seconds
        guard seconds.isFinite, seconds >= 0, seconds < duration.seconds else {
            return nil
        }
        guard let clip = clips.first(where: {
            seconds >= $0.projectTimeRange.start.seconds
                && seconds < $0.projectTimeRange.end.seconds
        }) else {
            return nil
        }
        let offset = seconds - clip.projectTimeRange.start.seconds
        return StorylinePosition(
            clipID: clip.id,
            takeID: clip.takeID,
            sourceTime: MediaTime(seconds: clip.selection.start.seconds + offset)
        )
    }
}

struct StorylinePosition: Equatable, Sendable {
    let clipID: TimelineClip.ID
    let takeID: UUID
    let sourceTime: MediaTime
}
