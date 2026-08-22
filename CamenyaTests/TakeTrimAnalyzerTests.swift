@preconcurrency import AVFoundation
import AudioToolbox
import XCTest
@testable import Camenya

final class TakeTrimAnalyzerTests: XCTestCase {
    @MainActor
    func testTrimWaveformRequestRunsOutsideRecorderIdleAndCachesTheResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let source = root.appendingPathComponent("source.mov")
        try Data("movie fixture supplied to fake analyzer".utf8).write(to: source)
        let takeID = UUID()
        let withTake = try store.addTake(
            projectID: project.id,
            takeID: takeID,
            movieAt: source,
            orientation: .portrait,
            duration: 4,
            createdAt: Date()
        )
        let model = AppModel(
            project: withTake,
            projectStore: store,
            trimAnalysisProvider: { _ in
                TakeTrimAnalysisOutput(
                    result: .noSuggestion(.negligibleSaving),
                    envelope: [0.1, 0.8, 0.3]
                )
            }
        )

        XCTAssertEqual(model.phase, .configuring)
        await model.prepareTrimWaveform(takeID: takeID)

        let take = try XCTUnwrap(model.project.takes.first { $0.id == takeID })
        XCTAssertEqual(model.trimEnvelope(for: take), [0.1, 0.8, 0.3])
        XCTAssertEqual(
            try store.trimEnvelope(projectID: project.id, takeID: takeID),
            [0.1, 0.8, 0.3]
        )
        XCTAssertNil(model.trimWaveformError(for: takeID))
        XCTAssertFalse(model.isPreparingTrimWaveform(for: takeID))
    }

    func testAnalyzerDecodesLocalPCMAndFindsSpokenEdges() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await makeAudioMovie(at: url, duration: 4, activeRange: 1..<3)

        let output = try await TakeTrimAnalyzer().analyze(movieAt: url)

        guard case let .suggestion(suggestion) = output.result else {
            return XCTFail("Expected a trim suggestion from decoded audio")
        }
        XCTAssertEqual(suggestion.range.start.seconds, 0.7, accuracy: 0.1)
        XCTAssertEqual(suggestion.range.end.seconds, 3.3, accuracy: 0.1)
        XCTAssertFalse(output.envelope.isEmpty)
    }

    func testDetectorSuggestsOnlyQuietLeadingAndTrailingEdges() throws {
        let windows = stride(from: 0.0, to: 10.0, by: 0.02).map { start in
            AudioEnergyWindow(
                start: start,
                duration: 0.02,
                decibels: (start >= 2 && start < 8) ? -18 : -72
            )
        }

        let result = TakeTrimDetector().detect(windows: windows, mediaDuration: 10)

        guard case let .suggestion(suggestion) = result else {
            return XCTFail("Expected a trim suggestion")
        }
        XCTAssertEqual(suggestion.range.start.seconds, 1.7, accuracy: 0.04)
        XCTAssertEqual(suggestion.range.end.seconds, 8.3, accuracy: 0.04)
    }

    func testDetectorDoesNotRemoveAnInternalPause() throws {
        let windows = stride(from: 0.0, to: 10.0, by: 0.02).map { start in
            let isVoice = (start >= 1 && start < 4) || (start >= 6 && start < 9)
            return AudioEnergyWindow(start: start, duration: 0.02, decibels: isVoice ? -20 : -70)
        }

        let result = TakeTrimDetector().detect(windows: windows, mediaDuration: 10)

        guard case let .suggestion(suggestion) = result else {
            return XCTFail("Expected a trim suggestion")
        }
        XCTAssertLessThanOrEqual(suggestion.range.start.seconds, 0.72)
        XCTAssertGreaterThanOrEqual(suggestion.range.end.seconds, 9.28)
        XCTAssertGreaterThan(suggestion.range.duration, 8.5)
    }

    private func makeAudioMovie(
        at url: URL,
        duration: TimeInterval,
        activeRange: Range<TimeInterval>
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        guard input.append(try audioSampleBuffer(duration: duration, activeRange: activeRange)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = writer.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func audioSampleBuffer(
        duration: TimeInterval,
        activeRange: Range<TimeInterval>
    ) throws -> CMSampleBuffer {
        let sampleRate = 44_100.0
        let sampleCount = Int((sampleRate * duration).rounded())
        var samples = [Int16](repeating: 0, count: sampleCount)
        for index in samples.indices {
            let time = Double(index) / sampleRate
            if activeRange.contains(time) {
                samples[index] = Int16(sin(2 * .pi * 440 * time) * 8_000)
            }
        }
        var stream = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
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
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &stream,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else { throw CocoaError(.fileWriteUnknown) }

        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { throw CocoaError(.fileWriteUnknown) }
        let replaceStatus = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { throw CocoaError(.fileWriteUnknown) }

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
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
        ) == noErr, let sampleBuffer else { throw CocoaError(.fileWriteUnknown) }
        return sampleBuffer
    }
}
