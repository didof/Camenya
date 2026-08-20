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

    func testProjectOverlayResolvesTheSameCueAndTimedSpanUsedByExport() throws {
        let cue = ProjectCaptionExportCue(
            range: TakeRange(startSeconds: 2, endSeconds: 5),
            text: "Shared timeline",
            timedSpans: [CaptionTimedSpan(
                range: TakeRange(startSeconds: 2.5, endSeconds: 3.5),
                text: "Shared",
                granularity: .word,
                confidence: 0.9
            )]
        )
        let timeline = ProjectCaptionExportTimeline(
            placement: .lower,
            style: .highContrast,
            duration: 8,
            cues: [cue]
        )

        let active = try XCTUnwrap(ProjectCaptionOverlayResolver.active(in: timeline, at: 3))

        XCTAssertEqual(active.cue, cue)
        XCTAssertEqual(active.timedSpan?.text, "Shared")
        XCTAssertNil(ProjectCaptionOverlayResolver.active(in: timeline, at: 5))
    }

    func testProjectOverlayHighlightPreservesTheFullExportCueText() throws {
        let active = ActiveProjectCaptionPresentation(
            cue: ProjectCaptionExportCue(
                range: TakeRange(startSeconds: 0, endSeconds: 3),
                text: "Hello, brave new world!",
                timedSpans: [
                    CaptionTimedSpan(
                        range: TakeRange(startSeconds: 0, endSeconds: 1),
                        text: "brave",
                        granularity: .word,
                        confidence: 0.9
                    )
                ]
            ),
            timedSpan: CaptionTimedSpan(
                range: TakeRange(startSeconds: 0, endSeconds: 1),
                text: "brave",
                granularity: .word,
                confidence: 0.9
            )
        )

        let runs = ProjectCaptionOverlayResolver.textRuns(for: active)

        XCTAssertEqual(runs.map(\.text).joined(), "Hello, brave new world!")
        XCTAssertEqual(runs.filter(\.isHighlighted).map(\.text), ["brave"])
    }

}
