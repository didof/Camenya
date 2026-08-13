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
                    let range = rebased(cue.range, sourceStart: sourceStart, timelineStart: cursor)
                    let preservesRecognizerTiming = !cue.wasEdited && !cue.timingWasEdited
                    let spans = preservesRecognizerTiming
                        ? cue.timedSpans.map {
                            CaptionTimedSpan(
                                range: rebased($0.range, sourceStart: sourceStart, timelineStart: cursor),
                                text: $0.text,
                                granularity: $0.granularity,
                                confidence: $0.confidence,
                                alternatives: $0.alternatives
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
}
