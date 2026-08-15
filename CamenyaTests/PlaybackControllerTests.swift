@preconcurrency import AVFoundation
import XCTest
@testable import Camenya

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testPlaybackSessionStartsFromImmutableSnapshotAtFirstClip() {
        let snapshot = makeSnapshot(durations: [2, 3])

        let session = TimelinePlaybackSession(snapshot: snapshot)

        XCTAssertEqual(session.state.revision, snapshot.revision)
        XCTAssertEqual(session.state.playhead.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(session.state.selectedClipID, snapshot.clips[0].id)
        XCTAssertEqual(session.state.selectedClipOrdinal, 1)
        XCTAssertEqual(session.state.clipCount, 2)
        XCTAssertEqual(session.state.duration.seconds, 5, accuracy: 0.001)
    }

    func testPlaybackSessionSeekAtHardCutSelectsFollowingClipAndPauses() {
        let snapshot = makeSnapshot(durations: [2, 3])
        let session = TimelinePlaybackSession(snapshot: snapshot)

        session.send(.togglePlayback)
        session.send(.seek(ProjectTime(seconds: 2)))

        XCTAssertEqual(session.state.playhead.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(session.state.selectedClipID, snapshot.clips[1].id)
        XCTAssertEqual(session.state.selectedClipOrdinal, 2)
        XCTAssertFalse(session.state.isPlaying)
    }

    func testPlaybackSessionNamedClipNavigationSeeksToClipStart() {
        let snapshot = makeSnapshot(durations: [2, 3, 4])
        let session = TimelinePlaybackSession(snapshot: snapshot)

        session.send(.selectNextClip)

        XCTAssertEqual(session.state.selectedClipID, snapshot.clips[1].id)
        XCTAssertEqual(session.state.playhead.seconds, 2, accuracy: 0.001)
        XCTAssertTrue(session.state.canSelectPreviousClip)
        XCTAssertTrue(session.state.canSelectNextClip)
    }

    func testPlaybackSessionZoomClampsWithoutChangingProjectPosition() {
        let snapshot = makeSnapshot(durations: [2, 3])
        let session = TimelinePlaybackSession(snapshot: snapshot)
        session.send(.seek(ProjectTime(seconds: 2.5)))
        let selectedClipID = session.state.selectedClipID

        for _ in 0..<20 { session.send(.zoomIn) }
        let maximumZoom = session.state.filmstripPointsPerSecond
        session.send(.zoomIn)
        XCTAssertEqual(session.state.filmstripPointsPerSecond, maximumZoom)

        for _ in 0..<40 { session.send(.zoomOut) }
        let minimumZoom = session.state.filmstripPointsPerSecond
        session.send(.zoomOut)
        XCTAssertEqual(session.state.filmstripPointsPerSecond, minimumZoom)
        XCTAssertEqual(session.state.playhead.seconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(session.state.selectedClipID, selectedClipID)
    }

    func testEmptyPlaybackSessionIgnoresPlaybackAndSeekIntents() {
        let snapshot = ExportSnapshot(
            projectID: UUID(),
            revision: StorylineRevision(rawValue: 3),
            format: .portrait,
            captionConfiguration: nil,
            clips: [],
            duration: .zero
        )
        let session = TimelinePlaybackSession(snapshot: snapshot)

        session.send(.togglePlayback)
        session.send(.seek(ProjectTime(seconds: 12)))
        session.send(.selectNextClip)

        XCTAssertEqual(session.state.phase, .empty)
        XCTAssertEqual(session.state.playhead, .zero)
        XCTAssertNil(session.state.selectedClipID)
    }

    func testSeekToProjectEndInvalidatesOlderPreparation() async {
        let session = TimelinePlaybackSession(snapshot: makeSnapshot(
            mediaURL: URL(fileURLWithPath: "/tmp/stale-preparation.mov")
        ))

        session.send(.seek(session.state.duration))
        for _ in 0..<1_000 { await Task.yield() }

        XCTAssertEqual(session.state.phase, .completed)
        XCTAssertEqual(session.state.playhead, session.state.duration)
        XCTAssertEqual(session.state.selectedClipOrdinal, 1)
    }

    func testTimelineReturnsToReplayableStartAfterNaturalCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("timeline.mov")
        try await makeMovie(at: url)
        let session = TimelinePlaybackSession(snapshot: makeSnapshot(mediaURL: url))
        await waitForCurrentItem(in: session)
        session.send(.togglePlayback)
        let completedItem = session.player.currentItem

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: completedItem)
        await waitForPhase(.completed, in: session)

        XCTAssertEqual(session.state.playhead, session.state.duration)
        XCTAssertFalse(session.state.isPlaying)

        session.send(.togglePlayback)
        await waitForPhase(.playing, in: session)
        XCTAssertEqual(session.state.playhead.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(session.state.selectedClipOrdinal, 1)
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

        let session = TimelinePlaybackSession(snapshot: makeSnapshot(
            mediaURL: movieURL,
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 1),
            selection: TakeRange(startSeconds: 0.25, endSeconds: 0.75)
        ))

        await waitForCurrentItem(in: session)

        let item = try XCTUnwrap(session.player.currentItem)
        let duration = try await item.asset.load(.duration).seconds
        let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let transform = try await videoTrack.load(.preferredTransform)
        let frame = try await AVAssetImageGenerator(asset: item.asset)
            .image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        let color = averageColor(frame)
        XCTAssertEqual(duration, 0.5, accuracy: 0.04)
        XCTAssertEqual(session.player.currentTime().seconds, 0, accuracy: 0.04)
        XCTAssertEqual(transform.a, 0, accuracy: 0.001)
        XCTAssertEqual(transform.b, 1, accuracy: 0.001)
        XCTAssertEqual(transform.c, -1, accuracy: 0.001)
        XCTAssertEqual(transform.d, 0, accuracy: 0.001)
        XCTAssertGreaterThan(color.green, color.red)
        XCTAssertGreaterThan(color.green, color.blue)
    }

    func testTimelineReportsPreparationFailureWithoutSubstitutingTheWholeTake() async {
        let session = TimelinePlaybackSession(snapshot: makeSnapshot(
            mediaURL: URL(fileURLWithPath: "/tmp/missing-trimmed.mov"),
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 1),
            selection: TakeRange(startSeconds: 0.25, endSeconds: 0.75)
        ))

        for _ in 0..<10_000 where session.state.phase != .failed {
            await Task.yield()
        }

        XCTAssertEqual(session.state.phase, .failed)
        XCTAssertTrue(session.player.items().isEmpty)
    }

    func testTimelineReportsPreparationFailureForMissingFullRangeSource() async {
        let session = TimelinePlaybackSession(snapshot: makeSnapshot(
            mediaURL: URL(fileURLWithPath: "/tmp/missing-full-range.mov")
        ))

        for _ in 0..<10_000 where session.state.phase != .failed {
            await Task.yield()
        }

        XCTAssertEqual(session.state.phase, .failed)
        XCTAssertTrue(session.player.items().isEmpty)
    }

    func testTimelineCanRetryAfterMissingSourceBecomesReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let movieURL = root.appendingPathComponent("retry.mov")
        let session = TimelinePlaybackSession(snapshot: makeSnapshot(mediaURL: movieURL))
        await waitForPhase(.failed, in: session)

        try await makeMovie(at: movieURL)
        session.send(.retryPreparation)
        await waitForPhase(.paused, in: session)

        XCTAssertNotNil(session.player.currentItem)
        XCTAssertEqual(session.state.revision, StorylineRevision(rawValue: 1))
        XCTAssertEqual(session.state.selectedClipOrdinal, 1)
    }

    private func waitForCurrentItem(in session: TimelinePlaybackSession) async {
        for _ in 0..<10_000 where session.player.currentItem == nil {
            await Task.yield()
        }
        XCTAssertNotNil(session.player.currentItem)
    }

    private func makeSnapshot(durations: [TimeInterval]) -> ExportSnapshot {
        var projectStart = 0.0
        let clips = durations.enumerated().map { index, duration in
            defer { projectStart += duration }
            let takeID = UUID()
            let range = TakeRange(startSeconds: 0, endSeconds: duration)
            return ExportSnapshot.Clip(
                id: TimelineClip.ID(),
                takeID: takeID,
                mediaURL: URL(fileURLWithPath: "/tmp/playback-\(index).mov"),
                sourceRange: range,
                availableRange: range,
                selection: range,
                projectTimeRange: ProjectTimeRange(
                    start: ProjectTime(seconds: projectStart),
                    end: ProjectTime(seconds: projectStart + duration)
                ),
                approvedCaptions: nil
            )
        }
        return ExportSnapshot(
            projectID: UUID(),
            revision: StorylineRevision(rawValue: 7),
            format: .portrait,
            captionConfiguration: nil,
            clips: clips,
            duration: ProjectTime(seconds: durations.reduce(0, +))
        )
    }

    private func waitForPhase(_ phase: TimelinePlaybackSession.Phase, in session: TimelinePlaybackSession) async {
        for _ in 0..<10_000 where session.state.phase != phase {
            await Task.yield()
        }
        XCTAssertEqual(session.state.phase, phase)
    }

    private func makeSnapshot(
        mediaURL: URL,
        sourceRange: TakeRange = TakeRange(startSeconds: 0, endSeconds: 1),
        selection: TakeRange? = nil
    ) -> ExportSnapshot {
        let selectedRange = selection ?? sourceRange
        let clip = ExportSnapshot.Clip(
            id: TimelineClip.ID(),
            takeID: UUID(),
            mediaURL: mediaURL,
            sourceRange: sourceRange,
            availableRange: sourceRange,
            selection: selectedRange,
            projectTimeRange: ProjectTimeRange(
                start: .zero,
                end: ProjectTime(seconds: selectedRange.duration)
            ),
            approvedCaptions: nil
        )
        return ExportSnapshot(
            projectID: UUID(),
            revision: StorylineRevision(rawValue: 1),
            format: .portrait,
            captionConfiguration: nil,
            clips: [clip],
            duration: ProjectTime(seconds: selectedRange.duration)
        )
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
