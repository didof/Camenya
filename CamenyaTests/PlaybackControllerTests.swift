@preconcurrency import AVFoundation
import XCTest
@testable import Camenya

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testTimelineReturnsToReplayableStartAfterNaturalCompletion() async {
        let url = URL(fileURLWithPath: "/tmp/timeline.mov")
        let controller = TimelinePlaybackController(urls: [url])
        await waitForCurrentItem(in: controller)
        controller.togglePlayback()
        let completedItem = controller.player.currentItem

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: completedItem)
        await waitForReplacementItem(in: controller, replacing: completedItem)

        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.player.items().count, 1)
    }

    func testTakeReturnsToStartAfterNaturalCompletion() async {
        let controller = TakePlaybackController(url: URL(fileURLWithPath: "/tmp/take.mov"))
        controller.seek(to: 12)

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: controller.player.currentItem)
        await Task.yield()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 0, accuracy: 0.001)
    }

    func testTrimmedTakePreviewUsesSelectionBoundsAndCanCompareOriginal() {
        let controller = TakePlaybackController(
            url: URL(fileURLWithPath: "/tmp/take.mov"),
            originalDuration: 10,
            selection: TakeRange(startSeconds: 2, endSeconds: 8),
            mode: .trimmed
        )

        XCTAssertEqual(controller.activeStart, 2, accuracy: 0.001)
        XCTAssertEqual(controller.activeEnd, 8, accuracy: 0.001)
        XCTAssertEqual(controller.player.currentItem?.forwardPlaybackEndTime.seconds ?? .nan, 8, accuracy: 0.001)

        controller.setPreviewMode(.original)

        XCTAssertEqual(controller.activeStart, 0, accuracy: 0.001)
        XCTAssertEqual(controller.activeEnd, 10, accuracy: 0.001)
    }

    func testTimelineConfiguresEachItemWithItsApprovedBounds() async {
        let source = TimelinePlaybackSource(
            url: URL(fileURLWithPath: "/tmp/take.mov"),
            selection: TakeRange(startSeconds: 2, endSeconds: 8)
        )

        let controller = TimelinePlaybackController(sources: [source])

        await waitForCurrentItem(in: controller)

        XCTAssertEqual(controller.player.currentItem?.forwardPlaybackEndTime.seconds ?? .nan, 8, accuracy: 0.001)
    }

    private func waitForCurrentItem(in controller: TimelinePlaybackController) async {
        for _ in 0..<10_000 where controller.player.currentItem == nil {
            await Task.yield()
        }
        XCTAssertNotNil(controller.player.currentItem)
    }

    private func waitForReplacementItem(
        in controller: TimelinePlaybackController,
        replacing completedItem: AVPlayerItem?
    ) async {
        for _ in 0..<10_000 {
            if let currentItem = controller.player.currentItem, currentItem !== completedItem {
                return
            }
            await Task.yield()
        }
        XCTFail("Timeline did not reload after natural completion")
    }
}
