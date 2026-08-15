import XCTest
@testable import Camenya

final class TakeEdgeCleanupPresentationTests: XCTestCase {
    func testOriginalTakeHasExplicitNonResettablePresentation() {
        let take = ProjectTake(createdAt: Date(), duration: 10)

        XCTAssertEqual(
            TakeEdgeCleanupPresentation(take: take),
            TakeEdgeCleanupPresentation(
                label: "Original range",
                systemImage: "rectangle",
                actionTitle: "Analyze Silence"
            )
        )
    }

    func testPendingSuggestionIsNamedForStorylineReview() {
        let range = TakeRange(startSeconds: 1, endSeconds: 9)
        let take = ProjectTake(
            createdAt: Date(),
            duration: 10,
            trimAnalysis: .suggestion(
                TrimSuggestion(range: range, algorithmVersion: 1, envelopeFileName: nil)
            )
        )

        XCTAssertEqual(
            TakeEdgeCleanupPresentation(take: take),
            TakeEdgeCleanupPresentation(
                label: "Cleanup review needed",
                systemImage: "waveform.badge.magnifyingglass",
                actionTitle: "Review Silence Trim"
            )
        )
    }

    func testLegacyTakeDecisionDoesNotClaimStorylineWasCleaned() {
        let range = TakeRange(startSeconds: 1, endSeconds: 9)
        let take = ProjectTake(
            createdAt: Date(),
            duration: 10,
            trimDecision: .useSelection(range)
        )

        XCTAssertEqual(
            TakeEdgeCleanupPresentation(take: take),
            TakeEdgeCleanupPresentation(
                label: "Original range",
                systemImage: "rectangle",
                actionTitle: "Analyze Silence"
            )
        )
    }

    func testTrimmedStorylineClipOwnsCleanedPresentation() {
        let take = ProjectTake(createdAt: Date(), duration: 10)
        let clip = TimelineClip(
            takeID: take.id,
            availableRange: TakeRange(startSeconds: 0, endSeconds: 10),
            selection: TakeRange(startSeconds: 1, endSeconds: 9)
        )

        XCTAssertEqual(
            TakeEdgeCleanupPresentation(take: take, clips: [clip]),
            TakeEdgeCleanupPresentation(
                label: "Storyline Clip trimmed",
                systemImage: "crop",
                actionTitle: "Edit Storyline Trim"
            )
        )
    }
}
