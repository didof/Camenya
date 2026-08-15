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

    let id: ID
    let takeID: UUID
    let availableRange: TakeRange
    let selection: TakeRange

    init(
        id: ID = ID(),
        takeID: UUID,
        availableRange: TakeRange,
        selection: TakeRange
    ) {
        self.id = id
        self.takeID = takeID
        self.availableRange = availableRange
        self.selection = selection
    }
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
        let projectTimeRange: ProjectTimeRange
        let approvedCaptions: TakeCaptionTrack?

        init(
            id: TimelineClip.ID,
            takeID: UUID,
            mediaURL: URL,
            thumbnailURL: URL? = nil,
            sourceCreatedAt: Date? = nil,
            sourceRange: TakeRange,
            availableRange: TakeRange,
            selection: TakeRange,
            projectTimeRange: ProjectTimeRange,
            approvedCaptions: TakeCaptionTrack?
        ) {
            self.id = id
            self.takeID = takeID
            self.mediaURL = mediaURL
            self.thumbnailURL = thumbnailURL
            self.sourceCreatedAt = sourceCreatedAt
            self.sourceRange = sourceRange
            self.availableRange = availableRange
            self.selection = selection
            self.projectTimeRange = projectTimeRange
            self.approvedCaptions = approvedCaptions
        }
    }

    let projectID: UUID
    let revision: StorylineRevision
    let format: ProjectFormat?
    let captionConfiguration: ProjectCaptionConfiguration?
    let clips: [Clip]
    let duration: ProjectTime

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
