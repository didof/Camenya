@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import XCTest
@testable import Camenya

final class ProjectExporterTests: XCTestCase {
    func testEmptyStorylineCannotCreateExportPlan() throws {
        let snapshot = fixtureSnapshot(
            projectID: UUID(),
            format: .portrait,
            sources: []
        )

        XCTAssertThrowsError(try ProjectExportPlan(snapshot: snapshot)) { error in
            XCTAssertEqual(error as? ProjectExportError, .emptyTimeline)
            XCTAssertEqual(
                (error as? ProjectExportError)?.errorDescription,
                "A Project needs at least one Storyline Clip before export."
            )
        }
    }

    func testExportPlanUsesEveryTakeInTimelineOrder() throws {
        let root = URL(fileURLWithPath: "/projects")
        let store = ProjectStore(projectsRoot: root)
        let projectID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let plan = try ProjectExportPlan(snapshot: fixtureSnapshot(
            projectID: projectID,
            format: .portrait,
            sources: [
                (secondID, store.takeMovieURL(projectID: projectID, takeID: secondID), TakeRange(startSeconds: 0, endSeconds: 8)),
                (firstID, store.takeMovieURL(projectID: projectID, takeID: firstID), TakeRange(startSeconds: 0, endSeconds: 12))
            ]
        ))

        XCTAssertEqual(plan.format, .portrait)
        XCTAssertEqual(plan.urls, [
            store.takeMovieURL(projectID: projectID, takeID: secondID),
            store.takeMovieURL(projectID: projectID, takeID: firstID)
        ])
    }

    func testExportPlanCarriesOnlyApprovedSelections() throws {
        let root = URL(fileURLWithPath: "/projects")
        let store = ProjectStore(projectsRoot: root)
        let projectID = UUID()
        let trimmedID = UUID()
        let originalID = UUID()
        let approved = TakeRange(startSeconds: 2, endSeconds: 8)
        let plan = try ProjectExportPlan(snapshot: fixtureSnapshot(
            projectID: projectID,
            format: .portrait,
            sources: [
                (trimmedID, store.takeMovieURL(projectID: projectID, takeID: trimmedID), approved),
                (originalID, store.takeMovieURL(projectID: projectID, takeID: originalID), TakeRange(startSeconds: 0, endSeconds: 10))
            ]
        ))

        XCTAssertEqual(plan.sources.map(\.selection), [
            approved,
            TakeRange(startSeconds: 0, endSeconds: 10)
        ])
    }

    func testExportPlanCarriesPerClipMutePolicyFromImmutableSnapshot() throws {
        let range = TakeRange(startSeconds: 0, endSeconds: 2)
        let muted = ExportSnapshot.Clip(
            id: TimelineClip.ID(),
            takeID: UUID(),
            mediaURL: URL(fileURLWithPath: "/muted.mov"),
            sourceRange: range,
            availableRange: range,
            selection: range,
            isMuted: true,
            projectTimeRange: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 2))
        )
        let audible = ExportSnapshot.Clip(
            id: TimelineClip.ID(),
            takeID: UUID(),
            mediaURL: URL(fileURLWithPath: "/audible.mov"),
            sourceRange: range,
            availableRange: range,
            selection: range,
            isMuted: false,
            projectTimeRange: ProjectTimeRange(
                start: ProjectTime(seconds: 2),
                end: ProjectTime(seconds: 4)
            )
        )
        let snapshot = ExportSnapshot(
            projectID: UUID(),
            revision: StorylineRevision(rawValue: 7),
            format: .portrait,
            captionConfiguration: nil,
            clips: [muted, audible],
            duration: ProjectTime(seconds: 4)
        )

        let plan = try ProjectExportPlan(snapshot: snapshot)

        XCTAssertEqual(plan.sources.map(\.isMuted), [true, false])
        XCTAssertEqual(plan.revision, snapshot.revision)
    }

    @MainActor
    func testExporterOmitsAudioTrackWhenEveryStorylineClipIsMuted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        let source = root.appendingPathComponent("muted-source.mov")
        try await makeMovie(at: source, red: 30, green: 180, blue: 80)
        let completed = try await TimelineEditor(
            projectID: project.id,
            projectStore: store
        ).completeFinalizedTake(
            FinalizedTake(
                id: takeID,
                movieURL: source,
                orientation: .landscapeLeft,
                duration: 0.5,
                createdAt: Date()
            ),
            expectedRevision: .zero
        )
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let muted = try await editor.perform(
            .setMuted(clipID: completed.clip.id, isMuted: true),
            expectedRevision: completed.snapshot.revision
        )

        let output = try await ProjectExporter().export(
            plan: try ProjectExportPlan(snapshot: muted.snapshot),
            to: store.pendingExportURL(projectID: project.id)
        )

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty)
        XCTAssertEqual(duration, 0.5, accuracy: 0.08)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.takeMovieURL(projectID: project.id, takeID: takeID).path
        ))
    }

    @MainActor
    func testExporterDoesNotCreateOutputWhenTakeMediaIsInvalid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data("not a movie".utf8).write(to: source)
        let updated = try store.addTake(
            projectID: project.id,
            takeID: UUID(),
            movieAt: source,
            orientation: .portrait,
            duration: 1,
            createdAt: Date()
        )
        let output = store.pendingExportURL(projectID: project.id)

        do {
            _ = try await ProjectExporter().export(
                plan: try await persistedExportPlan(projectID: updated.id, store: store),
                to: output
            )
            XCTFail("Expected invalid media to fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    @MainActor
    func testExporterConcatenatesValidTakesAndPreservesSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        var project = try store.createProject()
        let firstID = UUID()
        let secondID = UUID()
        let firstSource = root.appendingPathComponent("first.mov")
        let secondSource = root.appendingPathComponent("second.mov")
        try await makeMovie(at: firstSource, red: 255, green: 0, blue: 0)
        try await makeMovie(at: secondSource, red: 0, green: 0, blue: 255)
        project = try store.addTake(projectID: project.id, takeID: firstID, movieAt: firstSource, orientation: .landscapeLeft, duration: 0.5, createdAt: Date())
        project = try store.addTake(projectID: project.id, takeID: secondID, movieAt: secondSource, orientation: .landscapeLeft, duration: 0.5, createdAt: Date())

        let output = try await ProjectExporter().export(
            plan: try await persistedExportPlan(projectID: project.id, store: store),
            to: store.pendingExportURL(projectID: project.id)
        )

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first)
        let size = try await video.load(.naturalSize)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        let firstFrame = try await imageGenerator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let secondFrame = try await imageGenerator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image
        let firstColor = averageColor(firstFrame)
        let secondColor = averageColor(secondFrame)
        XCTAssertEqual(duration, 1, accuracy: 0.08)
        XCTAssertEqual(size.width, 1920, accuracy: 1)
        XCTAssertEqual(size.height, 1080, accuracy: 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertGreaterThan(firstColor.red, firstColor.blue)
        XCTAssertGreaterThan(secondColor.blue, secondColor.red)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.takeMovieURL(projectID: project.id, takeID: firstID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.takeMovieURL(projectID: project.id, takeID: secondID).path))
    }

    @MainActor
    func testExporterRejectsMissingAudioForUnmutedStorylineAndPreservesSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        let source = root.appendingPathComponent("video-only.mov")
        try await makeMovie(
            at: source,
            red: 30,
            green: 180,
            blue: 80,
            includeAudio: false
        )
        let completed = try await TimelineEditor(
            projectID: project.id,
            projectStore: store
        ).completeFinalizedTake(
            FinalizedTake(
                id: takeID,
                movieURL: source,
                orientation: .landscapeLeft,
                duration: 0.5,
                createdAt: Date()
            ),
            expectedRevision: .zero
        )
        let output = store.pendingExportURL(projectID: project.id)

        do {
            _ = try await ProjectExporter().export(
                plan: try ProjectExportPlan(snapshot: completed.snapshot),
                to: output
            )
            XCTFail("Expected an unmuted Storyline with missing audio to be rejected")
        } catch {
            XCTAssertEqual(error as? ProjectExportError, .missingAudioTrack(output.lastPathComponent))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.takeMovieURL(projectID: project.id, takeID: takeID).path
        ))
    }

    @MainActor
    func testExporterUsesVideoDurationWhenAudioIsLonger() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        let source = root.appendingPathComponent("long-audio.mov")
        try await makeMovie(at: source, red: 30, green: 180, blue: 80, audioDuration: 0.75)
        let updated = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: source,
            orientation: .landscapeLeft,
            duration: 0.5,
            createdAt: Date()
        )

        let output = try await ProjectExporter().export(
            plan: try await persistedExportPlan(projectID: updated.id, store: store),
            to: store.pendingExportURL(projectID: project.id)
        )

        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.08)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.takeMovieURL(projectID: project.id, takeID: takeID).path))
    }

    @MainActor
    func testCaptionAudioExtractionClampsNominalTakeEndToAvailableAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("short-audio.mov")
        let output = root.appendingPathComponent("captions.m4a")
        try await makeMovie(
            at: source,
            red: 30,
            green: 180,
            blue: 80,
            videoDuration: 2,
            audioDuration: 1.9
        )

        try await CaptionAudioExtractor().extract(
            from: source,
            range: TakeRange(startSeconds: 0, endSeconds: 2),
            to: output
        )

        let extractedDuration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(extractedDuration, 1.9, accuracy: 0.08)

        do {
            try await CaptionAudioExtractor().extract(
                from: source,
                range: TakeRange(startSeconds: 0, endSeconds: 3),
                to: root.appendingPathComponent("invalid-captions.m4a")
            )
            XCTFail("A materially invalid Take range must still be rejected")
        } catch {
            XCTAssertEqual(error as? CaptionTranscriptionError, .invalidSourceRange)
        }
    }

    @MainActor
    func testExporterRendersOnlyTheApprovedTakeSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        let source = root.appendingPathComponent("selected.mov")
        try await makeMovie(at: source, red: 200, green: 80, blue: 20, videoDuration: 1.5, audioDuration: 1.5)
        var updated = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: source,
            orientation: .landscapeLeft,
            duration: 1.5,
            createdAt: Date()
        )
        updated = try store.setTrimDecision(
            projectID: project.id,
            takeID: takeID,
            decision: .useSelection(TakeRange(startSeconds: 0.25, endSeconds: 1.25))
        )

        let output = try await ProjectExporter().export(
            plan: try await persistedExportPlan(projectID: updated.id, store: store),
            to: store.pendingExportURL(projectID: project.id)
        )

        let exportedDuration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(exportedDuration, 1, accuracy: 0.08)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.takeMovieURL(projectID: project.id, takeID: takeID).path))
    }

    @MainActor
    func testExporterBurnsApprovedCaptionsIntoTheirScheduledFrames() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone only: Core Animation video-composition export crashes Apple's Simulator compositor and produces a host macOS crash alert.")
#else
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let takeID = UUID()
        let source = root.appendingPathComponent("captioned.mov")
        try await makeMovie(
            at: source,
            red: 210,
            green: 40,
            blue: 30,
            videoDuration: 1,
            audioDuration: 1
        )
        var updated = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: source,
            orientation: .landscapeLeft,
            duration: 1,
            createdAt: Date()
        )
        updated = try store.setCaptionConfiguration(
            projectID: project.id,
            configuration: ProjectCaptionConfiguration(localeIdentifier: "it-IT", placement: .lower)
        )
        updated = try store.recordCaptionDraft(
            projectID: project.id,
            takeID: takeID,
            draft: TakeCaptionTrack(
                localeIdentifier: "it-IT",
                sourceRange: TakeRange(startSeconds: 0, endSeconds: 1),
                recognizer: .speechRecognizerIOS18,
                reviewState: .needsReview,
                cues: [CaptionCue(
                    range: TakeRange(startSeconds: 0.1, endSeconds: 0.5),
                    recognizedText: "Caption visible",
                    text: "Caption visible",
                    confidence: 0.9,
                    alternatives: [],
                    timedSpans: []
                )]
            )
        )
        updated = try store.approveCaptions(projectID: project.id, takeID: takeID)

        let output = try await ProjectExporter().export(
            plan: try await persistedExportPlan(projectID: updated.id, store: store),
            to: store.pendingExportURL(projectID: project.id)
        )
        let asset = AVURLAsset(url: output)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let captionFrame = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600)).image
        let plainFrame = try await generator.image(at: CMTime(seconds: 0.75, preferredTimescale: 600)).image

        XCTAssertGreaterThan(Int(averageColor(plainFrame).red) - Int(averageColor(captionFrame).red), 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.takeMovieURL(projectID: project.id, takeID: takeID).path))
#endif
    }

    @MainActor
    func testCancellingExportRemovesOutputAndPreservesSourceTake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        var project = try store.createProject()
        let takeID = UUID()
        let source = root.appendingPathComponent("source.mov")
        try await makeMovie(at: source, red: 20, green: 140, blue: 220)
        project = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: source,
            orientation: .landscapeLeft,
            duration: 0.5,
            createdAt: Date()
        )
        let exporter = ProjectExporter()
        let output = store.pendingExportURL(projectID: project.id)
        let task = Task { @MainActor in
            try await exporter.export(
                plan: try await persistedExportPlan(projectID: project.id, store: store),
                to: output
            )
        }
        for _ in 0..<10_000 where !exporter.isActive { await Task.yield() }

        exporter.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? ProjectExportError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.takeMovieURL(projectID: project.id, takeID: takeID).path))
    }

    private func makeMovie(
        at url: URL,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        videoDuration: TimeInterval = 0.5,
        audioDuration: TimeInterval = 0.5,
        includeAudio: Bool = true
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 1080
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        if includeAudio {
            XCTAssertTrue(writer.canAdd(audioInput))
            writer.add(audioInput)
        }
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        if includeAudio {
            XCTAssertTrue(audioInput.append(try silentAudioSampleBuffer(duration: audioDuration)))
            audioInput.markAsFinished()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var frame = 0
            let frameCount = max(1, Int((videoDuration * 30).rounded()))
            var finished = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "CamenyaTests.AssetWriter")) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData && frame < frameCount {
                    var buffer: CVPixelBuffer?
                    CVPixelBufferCreate(
                        kCFAllocatorDefault,
                        1920,
                        1080,
                        kCVPixelFormatType_32BGRA,
                        nil,
                        &buffer
                    )
                    guard let pixelBuffer = buffer else {
                        finished = true
                        writer.cancelWriting()
                        continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                        return
                    }
                    CVPixelBufferLockBaseAddress(pixelBuffer, [])
                    let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
                    let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * 1080
                    for offset in stride(from: 0, to: byteCount, by: 4) {
                        bytes[offset] = blue
                        bytes[offset + 1] = green
                        bytes[offset + 2] = red
                        bytes[offset + 3] = 255
                    }
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                    guard adaptor.append(
                        pixelBuffer,
                        withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)
                    ) else {
                        finished = true
                        writer.cancelWriting()
                        continuation.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown))
                        return
                    }
                    frame += 1
                }
                if frame == frameCount {
                    finished = true
                    let outputDuration = includeAudio ? max(videoDuration, audioDuration) : videoDuration
                    writer.endSession(atSourceTime: CMTime(seconds: outputDuration, preferredTimescale: 600))
                    input.markAsFinished()
                    writer.finishWriting {
                        if let error = writer.error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
        }
    }

    private func silentAudioSampleBuffer(duration: TimeInterval) throws -> CMSampleBuffer {
        let sampleCount = Int((44_100 * duration).rounded())
        let byteCount = sampleCount * MemoryLayout<Int16>.size
        var stream = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &stream,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else { throw CocoaError(.fileWriteUnknown) }

        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        )
        guard blockStatus == kCMBlockBufferNoErr, let block else { throw CocoaError(.fileWriteUnknown) }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: sampleCount,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { throw CocoaError(.fileWriteUnknown) }
        return sampleBuffer
    }

    private func averageColor(_ image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }

    private func persistedExportPlan(
        projectID: UUID,
        store: ProjectStore
    ) async throws -> ProjectExportPlan {
        let snapshot = try await TimelineEditor(
            projectID: projectID,
            projectStore: store
        ).snapshot()
        return try ProjectExportPlan(snapshot: snapshot)
    }

    private func fixtureSnapshot(
        projectID: UUID,
        format: ProjectFormat,
        sources: [(takeID: UUID, url: URL, selection: TakeRange)]
    ) -> ExportSnapshot {
        var cursor: TimeInterval = 0
        let clips = sources.map { source in
            let start = cursor
            cursor += source.selection.duration
            return ExportSnapshot.Clip(
                id: TimelineClip.ID(),
                takeID: source.takeID,
                mediaURL: source.url,
                sourceRange: source.selection,
                availableRange: source.selection,
                selection: source.selection,
                projectTimeRange: ProjectTimeRange(
                    start: ProjectTime(seconds: start),
                    end: ProjectTime(seconds: cursor)
                )
            )
        }
        return ExportSnapshot(
            projectID: projectID,
            revision: .zero,
            format: format,
            captionConfiguration: nil,
            clips: clips,
            duration: ProjectTime(seconds: cursor)
        )
    }
}
