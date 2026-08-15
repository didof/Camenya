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
        self.text = text
        self.timedSpans = timedSpans
        if let timedSpanTextRanges,
           timedSpanTextRanges.count == timedSpans.count {
            self.timedSpanTextRanges = timedSpanTextRanges
        } else {
            self.timedSpanTextRanges = CaptionTextOccurrenceResolver.ranges(
                in: text,
                for: timedSpans
            )
        }
    }
}

struct ProjectCaptionExportTimeline: Equatable, Sendable {
    let placement: CaptionPlacementZone
    let style: CaptionStylePreset
    let duration: TimeInterval
    let cues: [ProjectCaptionExportCue]
}

enum CaptionTimelineProjection {
    private struct Segment {
        let clip: TimelineClip
        let projectStart: TimeInterval
    }

    private struct RunProjection {
        let fragments: [CaptionTimelineFragment]
        let sourceRange: TakeRange
        let projectRange: TakeRange
        let isComplete: Bool
    }

    static func reconciledIssues(in project: ProjectManifest) -> [CaptionTimelineIssue] {
        let candidates = unsafeIssueCandidates(in: project)
        let candidateKeys = Set(candidates.map { IssueKey(takeID: $0.takeID, cueID: $0.cueID) })
        let eligibleCueKeys = Set(project.takes.flatMap { take -> [IssueKey] in
            guard let track = take.captions,
                  track.reviewState == .approved,
                  track.localeIdentifier == project.captionConfiguration?.localeIdentifier else { return [] }
            return track.cues.compactMap {
                guard $0.isEnabled,
                      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return IssueKey(takeID: take.id, cueID: $0.id)
            }
        })
        var reconciled = candidates.map { candidate in
            guard let existing = project.captionTimelineIssues.first(where: {
                $0.takeID == candidate.takeID && $0.cueID == candidate.cueID
            }) else { return candidate }
            guard existing.fragments == candidate.fragments,
                  existing.reason == candidate.reason else {
                return CaptionTimelineIssue(
                    id: existing.id,
                    takeID: candidate.takeID,
                    cueID: candidate.cueID,
                    fragments: candidate.fragments,
                    reason: candidate.reason
                )
            }
            return CaptionTimelineIssue(
                id: existing.id,
                takeID: candidate.takeID,
                cueID: candidate.cueID,
                fragments: candidate.fragments,
                reason: candidate.reason,
                reviewState: existing.reviewState
            )
        }
        reconciled.append(contentsOf: project.captionTimelineIssues.compactMap { existing in
            let key = IssueKey(takeID: existing.takeID, cueID: existing.cueID)
            guard existing.reviewState == .needsReview,
                  eligibleCueKeys.contains(key),
                  !candidateKeys.contains(key) else { return nil }
            return CaptionTimelineIssue(
                id: existing.id,
                takeID: existing.takeID,
                cueID: existing.cueID,
                fragments: [],
                reason: existing.reason
            )
        })
        return reconciled.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    static func makeTimeline(
        project: ProjectManifest,
        clips: [ExportSnapshot.Clip],
        issues: [CaptionTimelineIssue]
    ) -> ProjectCaptionExportTimeline? {
        guard let configuration = project.captionConfiguration else { return nil }
        let issueByCue = Dictionary(
            uniqueKeysWithValues: issues.map { (IssueKey(takeID: $0.takeID, cueID: $0.cueID), $0) }
        )
        var output: [ProjectCaptionExportCue] = []

        for take in project.takes {
            guard let track = take.captions,
                  track.reviewState == .approved,
                  track.localeIdentifier == configuration.localeIdentifier else { continue }
            let runs = projectionRuns(for: take.id, clips: clips)
            for cue in track.cues where cue.isEnabled && !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let key = IssueKey(takeID: take.id, cueID: cue.id)
                if issueByCue[key]?.reviewState == .needsReview { continue }
                for run in runs.compactMap({ projection(of: cue.range, through: $0) }) {
                    guard run.isComplete || issueByCue[key]?.reviewState == .approved else { continue }
                    let sourceTextRanges = CaptionTextOccurrenceResolver.ranges(
                        in: cue.text,
                        for: cue.timedSpans
                    )
                    let projectedTiming: [(CaptionTimedSpan, ProjectCaptionTextRange?)] =
                        (!cue.wasEdited && !cue.timingWasEdited)
                        ? cue.timedSpans.enumerated().compactMap { index, span in
                            guard span.range.start.seconds >= run.sourceRange.start.seconds,
                                  span.range.end.seconds <= run.sourceRange.end.seconds else { return nil }
                            return (
                                CaptionTimedSpan(
                                    range: rebase(span.range, from: run.sourceRange, to: run.projectRange),
                                    text: span.text,
                                    granularity: span.granularity,
                                    confidence: span.confidence,
                                    alternatives: span.alternatives
                                ),
                                sourceTextRanges[index]
                            )
                        }
                        : []
                    output.append(ProjectCaptionExportCue(
                        range: run.projectRange,
                        text: cue.text,
                        timedSpans: projectedTiming.map(\.0),
                        timedSpanTextRanges: projectedTiming.map(\.1)
                    ))
                }
            }
        }

        return ProjectCaptionExportTimeline(
            placement: configuration.placement,
            style: configuration.style,
            duration: clips.last?.projectTimeRange.end.seconds ?? 0,
            cues: output.sorted { $0.range.start.seconds < $1.range.start.seconds }
        )
    }

    private struct IssueKey: Hashable {
        let takeID: UUID
        let cueID: UUID
    }

    private static func unsafeIssueCandidates(in project: ProjectManifest) -> [CaptionTimelineIssue] {
        guard let configuration = project.captionConfiguration else { return [] }
        let segments = segments(from: project.primaryStoryline.clips)
        var issues: [CaptionTimelineIssue] = []
        for take in project.takes {
            guard let track = take.captions,
                  track.reviewState == .approved,
                  track.localeIdentifier == configuration.localeIdentifier else { continue }
            let runs = segmentRuns(for: take.id, segments: segments)
            for cue in track.cues where cue.isEnabled && !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let projections = runs.compactMap { projection(of: cue.range, through: $0) }
                let unsafe = projections.filter { !$0.isComplete }
                guard !unsafe.isEmpty else { continue }
                issues.append(CaptionTimelineIssue(
                    takeID: take.id,
                    cueID: cue.id,
                    fragments: unsafe.flatMap(\.fragments),
                    reason: unsafe.count > 1 ? .discontinuousProjection : .boundaryCut
                ))
            }
        }
        return issues
    }

    private static func segments(from clips: [TimelineClip]) -> [Segment] {
        var cursor: TimeInterval = 0
        return clips.map { clip in
            defer { cursor += clip.selection.duration }
            return Segment(clip: clip, projectStart: cursor)
        }
    }

    private static func segmentRuns(for takeID: UUID, segments: [Segment]) -> [[Segment]] {
        var runs: [[Segment]] = []
        for segment in segments where segment.clip.takeID == takeID {
            if let last = runs.last?.last,
               last.clip.selection.end == segment.clip.selection.start,
               last.projectStart + last.clip.selection.duration == segment.projectStart {
                runs[runs.count - 1].append(segment)
            } else {
                runs.append([segment])
            }
        }
        return runs
    }

    private static func projectionRuns(
        for takeID: UUID,
        clips: [ExportSnapshot.Clip]
    ) -> [[Segment]] {
        segmentRuns(
            for: takeID,
            segments: clips.map {
                Segment(
                    clip: TimelineClip(
                        id: $0.id,
                        takeID: $0.takeID,
                        availableRange: $0.availableRange,
                        selection: $0.selection,
                        isMuted: $0.isMuted
                    ),
                    projectStart: $0.projectTimeRange.start.seconds
                )
            }
        )
    }

    private static func projection(
        of cueRange: TakeRange,
        through run: [Segment]
    ) -> RunProjection? {
        let pieces = run.compactMap { segment -> (Segment, TakeRange)? in
            guard let range = intersection(cueRange, segment.clip.selection) else { return nil }
            return (segment, range)
        }
        guard let first = pieces.first, let last = pieces.last else { return nil }
        let sourceRange = TakeRange(start: first.1.start, end: last.1.end)
        let projectRange = TakeRange(
            startSeconds: first.0.projectStart + first.1.start.seconds - first.0.clip.selection.start.seconds,
            endSeconds: last.0.projectStart + last.1.end.seconds - last.0.clip.selection.start.seconds
        )
        return RunProjection(
            fragments: pieces.map {
                CaptionTimelineFragment(clipID: $0.0.clip.id, sourceRange: $0.1)
            },
            sourceRange: sourceRange,
            projectRange: projectRange,
            isComplete: sourceRange == cueRange
        )
    }

    private static func intersection(_ lhs: TakeRange, _ rhs: TakeRange) -> TakeRange? {
        let start = max(lhs.start.seconds, rhs.start.seconds)
        let end = min(lhs.end.seconds, rhs.end.seconds)
        guard end > start else { return nil }
        return TakeRange(startSeconds: start, endSeconds: end)
    }

    private static func rebase(
        _ range: TakeRange,
        from sourceRange: TakeRange,
        to projectRange: TakeRange
    ) -> TakeRange {
        TakeRange(
            startSeconds: projectRange.start.seconds + range.start.seconds - sourceRange.start.seconds,
            endSeconds: projectRange.start.seconds + range.end.seconds - sourceRange.start.seconds
        )
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
        var searchLocation = 0
        let source = text as NSString
        return spans.map { span in
            let location = min(searchLocation, source.length)
            let range = source.range(
                of: span.text,
                options: [],
                range: NSRange(location: location, length: source.length - location)
            )
            guard range.location != NSNotFound else { return nil }
            searchLocation = NSMaxRange(range)
            return ProjectCaptionTextRange(
                location: range.location,
                length: range.length
            )
        }
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
