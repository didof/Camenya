@preconcurrency import AVFoundation
import XCTest
@testable import Camenya

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testTimelineReturnsToReplayableStartAfterNaturalCompletion() async {
        let url = URL(fileURLWithPath: "/tmp/timeline.mov")
        let controller = TimelinePlaybackController(
            sources: [TimelinePlaybackSource(url: url, selection: nil)]
        )
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

    func testTimelineMakesTrimmedClipAPlayableItemWithOnlyItsSelectedDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let movieURL = root.appendingPathComponent("trimmed.mov")
        try await makeMovie(at: movieURL)

        let controller = TimelinePlaybackController(sources: [
            TimelinePlaybackSource(
                url: movieURL,
                selection: TakeRange(startSeconds: 0.25, endSeconds: 0.75)
            )
        ])

        await waitForCurrentItem(in: controller)

        let item = try XCTUnwrap(controller.player.currentItem)
        let duration = try await item.asset.load(.duration).seconds
        let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let transform = try await videoTrack.load(.preferredTransform)
        let frame = try await AVAssetImageGenerator(asset: item.asset)
            .image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        let color = averageColor(frame)
        XCTAssertEqual(duration, 0.5, accuracy: 0.04)
        XCTAssertEqual(controller.player.currentTime().seconds, 0, accuracy: 0.04)
        XCTAssertEqual(transform.a, 0, accuracy: 0.001)
        XCTAssertEqual(transform.b, 1, accuracy: 0.001)
        XCTAssertEqual(transform.c, -1, accuracy: 0.001)
        XCTAssertEqual(transform.d, 0, accuracy: 0.001)
        XCTAssertGreaterThan(color.green, color.red)
        XCTAssertGreaterThan(color.green, color.blue)
    }

    func testTimelineReportsPreparationFailureWithoutSubstitutingTheWholeTake() async {
        let controller = TimelinePlaybackController(sources: [
            TimelinePlaybackSource(
                url: URL(fileURLWithPath: "/tmp/missing-trimmed.mov"),
                selection: TakeRange(startSeconds: 0.25, endSeconds: 0.75)
            )
        ])

        for _ in 0..<10_000 where !controller.preparationFailed {
            await Task.yield()
        }

        XCTAssertTrue(controller.preparationFailed)
        XCTAssertTrue(controller.player.items().isEmpty)
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

    private func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 90
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = PlaybackMovieWriterContext(writer: writer, input: input, adaptor: adaptor)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var frame = 0
            var finished = false
            context.input.requestMediaDataWhenReady(on: DispatchQueue(label: "CamenyaTests.PlaybackAssetWriter")) {
                guard !finished else { return }
                while context.input.isReadyForMoreMediaData && frame < 30 {
                    var buffer: CVPixelBuffer?
                    CVPixelBufferCreate(
                        kCFAllocatorDefault,
                        160,
                        90,
                        kCVPixelFormatType_32BGRA,
                        nil,
                        &buffer
                    )
                    guard let pixelBuffer = buffer,
                          Self.paintGreen(pixelBuffer),
                          context.adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
                        finished = true
                        context.writer.cancelWriting()
                        continuation.resume(throwing: context.writer.error ?? CocoaError(.fileWriteUnknown))
                        return
                    }
                    frame += 1
                }
                if frame == 30 {
                    finished = true
                    context.input.markAsFinished()
                    context.writer.finishWriting {
                        if let error = context.writer.error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
        }
    }

    private nonisolated static func paintGreen(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        for offset in stride(from: 0, to: byteCount, by: 4) {
            bytes[offset] = 20
            bytes[offset + 1] = 220
            bytes[offset + 2] = 30
            bytes[offset + 3] = 255
        }
        return true
    }

    private func averageColor(_ image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }
}

private final class PlaybackMovieWriterContext: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor

    init(
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) {
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }
}
