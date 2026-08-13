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
                canReset: false,
                actionTitle: "Analyze Silence"
            )
        )
    }

    func testPendingSuggestionIsNamedAndResettable() {
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
                canReset: true,
                actionTitle: "Review Silence Trim"
            )
        )
    }

    func testApprovedSelectionUsesCleanedPresentation() {
        let range = TakeRange(startSeconds: 1, endSeconds: 9)
        let take = ProjectTake(
            createdAt: Date(),
            duration: 10,
            trimDecision: .useSelection(range)
        )

        XCTAssertEqual(
            TakeEdgeCleanupPresentation(take: take),
            TakeEdgeCleanupPresentation(
                label: "Cleaned selection",
                systemImage: "crop",
                canReset: true,
                actionTitle: "Edit Silence Trim"
            )
        )
    }
}
