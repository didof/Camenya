import XCTest
@testable import Camenya

final class TakeCaptionPresentationTests: XCTestCase {
    func testTakeWithoutTrackShowsNoCaptions() {
        let take = makeTake(captions: nil)

        XCTAssertEqual(
            TakeCaptionPresentation(take: take, configuration: nil),
            TakeCaptionPresentation(
                label: "No captions",
                systemImage: "captions.bubble",
                requiresAttention: false,
                actionTitle: "Create Captions"
            )
        )
    }

    func testReviewAndApprovedStatesAreDistinct() {
        let configuration = ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)

        XCTAssertEqual(
            TakeCaptionPresentation(
                take: makeTake(captions: makeTrack(reviewState: .needsReview)),
                configuration: configuration
            ).label,
            "Captions to review"
        )
        XCTAssertEqual(
            TakeCaptionPresentation(
                take: makeTake(captions: makeTrack(reviewState: .approved)),
                configuration: configuration
            ).label,
            "Captions approved"
        )
    }

    func testMismatchedEffectiveRangeRequiresCaptionUpdate() {
        var take = makeTake(captions: makeTrack(reviewState: .approved))
        take.trimDecision = .useSelection(TakeRange(startSeconds: 1, endSeconds: 9))

        let presentation = TakeCaptionPresentation(
            take: take,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )

        XCTAssertEqual(presentation.label, "Captions need update")
        XCTAssertTrue(presentation.requiresAttention)
        XCTAssertEqual(presentation.actionTitle, "Regenerate Captions")
    }

    private func makeTake(captions: TakeCaptionTrack?) -> ProjectTake {
        ProjectTake(
            createdAt: Date(timeIntervalSince1970: 1),
            duration: 10,
            captions: captions
        )
    }

    private func makeTrack(reviewState: CaptionReviewState) -> TakeCaptionTrack {
        TakeCaptionTrack(
            localeIdentifier: "it-IT",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 10),
            recognizer: .speechRecognizerIOS18,
            reviewState: reviewState,
            cues: []
        )
    }
}
