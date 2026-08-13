import Foundation
import QuartzCore
import XCTest
@testable import Camenya

final class CaptionExportTimelineTests: XCTestCase {
    func testCaptionPresentationMetricsScaleWithTheDisplayedVideoCanvas() {
        let exportPortrait = CaptionPresentationLayout.metrics(
            for: CGSize(width: 1080, height: 1920)
        )
        let compactPortrait = CaptionPresentationLayout.metrics(
            for: CGSize(width: 157.5, height: 280)
        )
        let compactLandscape = CaptionPresentationLayout.metrics(
            for: CGSize(width: 337.78, height: 190)
        )

        XCTAssertEqual(exportPortrait.fontSize, 58, accuracy: 0.001)
        XCTAssertEqual(exportPortrait.padding, 24, accuracy: 0.001)
        XCTAssertEqual(exportPortrait.cornerRadius, 18, accuracy: 0.001)
        XCTAssertEqual(exportPortrait.minimumContainerHeight, 110, accuracy: 0.001)

        let portraitScale = 157.5 / 1080
        XCTAssertEqual(compactPortrait.fontSize, 58 * portraitScale, accuracy: 0.001)
        XCTAssertEqual(compactPortrait.padding, 24 * portraitScale, accuracy: 0.001)
        XCTAssertEqual(compactPortrait.cornerRadius, 18 * portraitScale, accuracy: 0.001)

        let landscapeScale = 190.0 / 1080
        XCTAssertEqual(compactLandscape.fontSize, 58 * landscapeScale, accuracy: 0.001)
        XCTAssertEqual(compactLandscape.padding, 24 * landscapeScale, accuracy: 0.001)
        XCTAssertEqual(compactLandscape.cornerRadius, 18 * landscapeScale, accuracy: 0.001)
    }

    @MainActor
    func testBurnInExplicitlyClearsEveryCueThroughTheEndOfTheTimeline() throws {
        let timeline = ProjectCaptionExportTimeline(
            placement: .lower,
            style: .highContrast,
            duration: 5,
            cues: [
                ProjectCaptionExportCue(
                    range: TakeRange(startSeconds: 1, endSeconds: 2),
                    text: "Prima caption",
                    timedSpans: []
                ),
                ProjectCaptionExportCue(
                    range: TakeRange(startSeconds: 3, endSeconds: 4),
                    text: "Seconda caption",
                    timedSpans: []
                )
            ]
        )

        let tree = CaptionBurnInRenderer().makeLayerTree(
            timeline: timeline,
            canvas: CGSize(width: 1080, height: 1920)
        )

        let layers = try XCTUnwrap(tree.overlay.sublayers)
        XCTAssertEqual(layers.count, 2)

        let firstVisibility = try XCTUnwrap(
            layers[0].animation(forKey: "captionVisibility") as? CAKeyframeAnimation
        )
        XCTAssertEqual(firstVisibility.values as? [Int], [0, 1, 0, 0])
        XCTAssertEqual(firstVisibility.keyTimes, [0, 0.2, 0.4, 1])

        let secondVisibility = try XCTUnwrap(
            layers[1].animation(forKey: "captionVisibility") as? CAKeyframeAnimation
        )
        XCTAssertEqual(secondVisibility.values as? [Int], [0, 1, 0, 0])
        XCTAssertEqual(secondVisibility.keyTimes, [0, 0.6, 0.8, 1])
    }

    @MainActor
    func testBurnInLayerTreeUsesPixelScaleAndRealTimedSpanAnimation() throws {
        let timeline = ProjectCaptionExportTimeline(
            placement: .lower,
            style: .highContrast,
            duration: 10,
            cues: [ProjectCaptionExportCue(
                range: TakeRange(startSeconds: 1, endSeconds: 4),
                text: "Ciao mondo",
                timedSpans: [CaptionTimedSpan(
                    range: TakeRange(startSeconds: 1, endSeconds: 2),
                    text: "Ciao",
                    granularity: .word,
                    confidence: 0.9
                )]
            )]
        )

        let tree = CaptionBurnInRenderer().makeLayerTree(
            timeline: timeline,
            canvas: CGSize(width: 1080, height: 1920)
        )

        let layers = try XCTUnwrap(tree.overlay.sublayers)
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers[0].frame.midY / 1920, 0.18, accuracy: 0.001)
        XCTAssertLessThan(layers[0].frame.width, 1080 * 0.7)
        XCTAssertEqual((layers[0].sublayers?.first as? CATextLayer)?.contentsScale, 1)
        let cueAnimation = try XCTUnwrap(layers[0].animation(forKey: "captionVisibility") as? CAKeyframeAnimation)
        let spanAnimation = try XCTUnwrap(layers[1].animation(forKey: "captionVisibility") as? CAKeyframeAnimation)
        XCTAssertEqual(cueAnimation.duration, 10)
        XCTAssertEqual(cueAnimation.keyTimes, [0, 0.1, 0.4, 1])
        XCTAssertEqual(spanAnimation.keyTimes, [0, 0.1, 0.2, 1])
    }

    func testTimelineRebasesApprovedCaptionsAcrossTrimmedAndOriginalTakes() {
        let firstCue = CaptionCue(
            range: TakeRange(startSeconds: 3, endSeconds: 4),
            recognizedText: "prima take",
            text: "prima take",
            confidence: 0.9,
            alternatives: [],
            timedSpans: [CaptionTimedSpan(
                range: TakeRange(startSeconds: 3.2, endSeconds: 3.8),
                text: "prima",
                granularity: .word,
                confidence: 0.9
            )]
        )
        let secondCue = CaptionCue(
            range: TakeRange(startSeconds: 0.5, endSeconds: 1.5),
            recognizedText: "seconda take",
            text: "seconda take",
            confidence: 0.8,
            alternatives: [],
            timedSpans: []
        )
        let plan = ProjectExportPlan(
            sources: [
                ProjectExportSource(
                    takeID: UUID(),
                    url: URL(fileURLWithPath: "/first.mov"),
                    selection: TakeRange(startSeconds: 2, endSeconds: 8),
                    duration: 6,
                    captions: track(sourceRange: TakeRange(startSeconds: 2, endSeconds: 8), cues: [firstCue])
                ),
                ProjectExportSource(
                    takeID: UUID(),
                    url: URL(fileURLWithPath: "/second.mov"),
                    selection: nil,
                    duration: 5,
                    captions: track(sourceRange: TakeRange(startSeconds: 0, endSeconds: 5), cues: [secondCue])
                )
            ],
            format: .portrait,
            captionConfiguration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .upper)
        )

        let timeline = ProjectCaptionExportTimeline.make(plan: plan)

        XCTAssertEqual(timeline?.placement, .upper)
        XCTAssertEqual(timeline?.style, .highContrast)
        XCTAssertEqual(timeline?.duration, 11)
        XCTAssertEqual(timeline?.cues.map(\.range), [
            TakeRange(startSeconds: 1, endSeconds: 2),
            TakeRange(startSeconds: 6.5, endSeconds: 7.5)
        ])
        XCTAssertEqual(timeline?.cues.first?.timedSpans.first?.range, TakeRange(startSeconds: 1.2, endSeconds: 1.8))
    }

    func testCoreAnimationLayoutMirrorsTopLeadingPreviewCoordinates() {
        let portrait = CaptionPresentationLayout.coreAnimationFrame(
            placement: .lower,
            width: 800,
            height: 120,
            canvas: CGSize(width: 1080, height: 1920)
        )
        let landscape = CaptionPresentationLayout.coreAnimationFrame(
            placement: .upper,
            width: 1200,
            height: 80,
            canvas: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(CaptionPresentationLayout.centerYFraction(for: .lower), 0.82, accuracy: 0.001)
        XCTAssertEqual(CaptionPresentationLayout.centerYFraction(for: .upper), 0.18, accuracy: 0.001)
        XCTAssertEqual(portrait.midY / 1920, 0.18, accuracy: 0.001)
        XCTAssertEqual(landscape.midY / 1080, 0.82, accuracy: 0.001)
        XCTAssertEqual(portrait.midX / 1080, 0.5, accuracy: 0.001)
        XCTAssertEqual(landscape.midX / 1920, 0.5, accuracy: 0.001)
    }

    func testEditedCueFallsBackToCueTimingAndDisabledCueIsOmitted() {
        let edited = CaptionCue(
            range: TakeRange(startSeconds: 1, endSeconds: 2),
            recognizedText: "raw words",
            text: "correct words",
            confidence: nil,
            alternatives: [],
            timedSpans: [CaptionTimedSpan(
                range: TakeRange(startSeconds: 1, endSeconds: 1.5),
                text: "raw",
                granularity: .word,
                confidence: nil
            )]
        )
        let disabled = CaptionCue(
            range: TakeRange(startSeconds: 3, endSeconds: 4),
            recognizedText: "hidden",
            text: "hidden",
            confidence: nil,
            alternatives: [],
            timedSpans: [],
            isEnabled: false
        )
        let plan = ProjectExportPlan(
            sources: [ProjectExportSource(
                takeID: UUID(),
                url: URL(fileURLWithPath: "/take.mov"),
                selection: nil,
                duration: 5,
                captions: track(sourceRange: TakeRange(startSeconds: 0, endSeconds: 5), cues: [edited, disabled])
            )],
            format: .landscape,
            captionConfiguration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )

        let timeline = ProjectCaptionExportTimeline.make(plan: plan)

        XCTAssertEqual(timeline?.cues.count, 1)
        XCTAssertEqual(timeline?.cues.first?.text, "correct words")
        XCTAssertEqual(timeline?.cues.first?.timedSpans, [])
    }

    private func track(sourceRange: TakeRange, cues: [CaptionCue]) -> TakeCaptionTrack {
        TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: sourceRange,
            recognizer: .speechRecognizerIOS18,
            reviewState: .approved,
            cues: cues
        )
    }
}
