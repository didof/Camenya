import Foundation

struct ProjectCaptionExportCue: Equatable, Sendable {
    let range: TakeRange
    let text: String
    let timedSpans: [CaptionTimedSpan]
}

struct ProjectCaptionExportTimeline: Equatable, Sendable {
    let placement: CaptionPlacementZone
    let style: CaptionStylePreset
    let duration: TimeInterval
    let cues: [ProjectCaptionExportCue]

    static func make(plan: ProjectExportPlan) -> ProjectCaptionExportTimeline? {
        guard let configuration = plan.captionConfiguration else { return nil }
        var cursor: TimeInterval = 0
        var output: [ProjectCaptionExportCue] = []
        for source in plan.sources {
            let sourceStart = source.selection?.start.seconds ?? 0
            if let captions = source.captions,
               captions.localeIdentifier == configuration.localeIdentifier {
                for cue in captions.cues where cue.isEnabled && !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let projectedCueRange = intersection(
                        cue.range,
                        with: source.selection
                    ) else { continue }
                    let range = rebased(
                        projectedCueRange,
                        sourceStart: sourceStart,
                        timelineStart: cursor
                    )
                    let preservesRecognizerTiming = !cue.wasEdited && !cue.timingWasEdited
                    let spans = preservesRecognizerTiming
                        ? cue.timedSpans.compactMap { span -> CaptionTimedSpan? in
                            guard let projectedSpanRange = intersection(
                                span.range,
                                with: source.selection
                            ) else { return nil }
                            return CaptionTimedSpan(
                                range: rebased(
                                    projectedSpanRange,
                                    sourceStart: sourceStart,
                                    timelineStart: cursor
                                ),
                                text: span.text,
                                granularity: span.granularity,
                                confidence: span.confidence,
                                alternatives: span.alternatives
                            )
                        }
                        : []
                    output.append(ProjectCaptionExportCue(range: range, text: cue.text, timedSpans: spans))
                }
            }
            cursor += source.duration
        }
        return ProjectCaptionExportTimeline(
            placement: configuration.placement,
            style: configuration.style,
            duration: cursor,
            cues: output
        )
    }

    private static func rebased(
        _ range: TakeRange,
        sourceStart: TimeInterval,
        timelineStart: TimeInterval
    ) -> TakeRange {
        TakeRange(
            startSeconds: timelineStart + range.start.seconds - sourceStart,
            endSeconds: timelineStart + range.end.seconds - sourceStart
        )
    }

    private static func intersection(
        _ range: TakeRange,
        with selection: TakeRange?
    ) -> TakeRange? {
        guard let selection else { return range }
        let start = max(range.start.seconds, selection.start.seconds)
        let end = min(range.end.seconds, selection.end.seconds)
        guard end > start else { return nil }
        return TakeRange(startSeconds: start, endSeconds: end)
    }
}
