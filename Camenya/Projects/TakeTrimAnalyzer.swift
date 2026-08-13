@preconcurrency import AVFoundation
import Foundation

struct AudioEnergyWindow: Equatable, Sendable {
    let start: TimeInterval
    let duration: TimeInterval
    let decibels: Float
}

struct TakeTrimAnalysisOutput: Equatable, Sendable {
    let result: TrimAnalysisResult
    let envelope: [Float]
}

struct TakeTrimDetector: Sendable {
    struct Configuration: Equatable, Sendable {
        var entryThreshold: Float = -42
        var exitThreshold: Float = -48
        var sustainedActivity: TimeInterval = 0.12
        var padding: TimeInterval = 0.3
        var minimumSaving: TimeInterval = 0.5
        var minimumSelection: TimeInterval = 1
    }

    let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func detect(windows: [AudioEnergyWindow], mediaDuration: TimeInterval) -> TrimAnalysisResult {
        guard mediaDuration.isFinite, mediaDuration > 0, !windows.isEmpty else {
            return .noSuggestion(.noSustainedActivity)
        }
        let smoothed = windows.indices.map { index -> Float in
            let lower = max(0, index - 2)
            let upper = min(windows.count - 1, index + 2)
            return windows[lower...upper].reduce(0) { $0 + $1.decibels } / Float(upper - lower + 1)
        }
        guard let firstActive = sustainedRunStart(
            in: smoothed,
            windows: windows,
            threshold: configuration.entryThreshold,
            duration: configuration.sustainedActivity
        ), let lastActive = sustainedRunEnd(
            in: smoothed,
            windows: windows,
            threshold: configuration.entryThreshold,
            duration: configuration.sustainedActivity
        ) else {
            return .noSuggestion(.noSustainedActivity)
        }

        var startIndex = firstActive
        while startIndex > 0, smoothed[startIndex - 1] >= configuration.exitThreshold { startIndex -= 1 }
        var endIndex = lastActive
        while endIndex + 1 < smoothed.count, smoothed[endIndex + 1] >= configuration.exitThreshold { endIndex += 1 }

        let start = max(0, windows[startIndex].start - configuration.padding)
        let end = min(mediaDuration, windows[endIndex].start + windows[endIndex].duration + configuration.padding)
        let range = TakeRange(startSeconds: start, endSeconds: end)
        guard range.duration >= configuration.minimumSelection else {
            return .noSuggestion(.selectionTooShort)
        }
        guard start + (mediaDuration - end) >= configuration.minimumSaving else {
            return .noSuggestion(.negligibleSaving)
        }
        return .suggestion(TrimSuggestion(range: range, algorithmVersion: 1, envelopeFileName: nil))
    }

    private func sustainedRunStart(
        in values: [Float],
        windows: [AudioEnergyWindow],
        threshold: Float,
        duration: TimeInterval
    ) -> Int? {
        var runDuration: TimeInterval = 0
        for index in values.indices {
            runDuration = values[index] >= threshold ? runDuration + windows[index].duration : 0
            if runDuration >= duration {
                var start = index
                var accumulated: TimeInterval = windows[index].duration
                while start > 0, accumulated < duration {
                    start -= 1
                    accumulated += windows[start].duration
                }
                return start
            }
        }
        return nil
    }

    private func sustainedRunEnd(
        in values: [Float],
        windows: [AudioEnergyWindow],
        threshold: Float,
        duration: TimeInterval
    ) -> Int? {
        var runDuration: TimeInterval = 0
        for index in values.indices.reversed() {
            runDuration = values[index] >= threshold ? runDuration + windows[index].duration : 0
            if runDuration >= duration {
                var end = index
                var accumulated: TimeInterval = windows[index].duration
                while end + 1 < windows.count, accumulated < duration {
                    end += 1
                    accumulated += windows[end].duration
                }
                return end
            }
        }
        return nil
    }
}

enum TakeTrimAnalyzerError: Error, Equatable {
    case cancelled
    case cannotRead
}

final class TakeTrimAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.camenya.app.take-trim-analysis", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private let detector: TakeTrimDetector

    init(detector: TakeTrimDetector = TakeTrimDetector()) {
        self.detector = detector
    }

    func analyze(movieAt url: URL) async throws -> TakeTrimAnalysisOutput {
        setCancellationRequested(false)
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let mediaRange: CMTimeRange
        if let videoTrack = videoTracks.first {
            mediaRange = try await videoTrack.load(.timeRange)
        } else {
            mediaRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        }
        guard let audioTrack = audioTracks.first else {
            return TakeTrimAnalysisOutput(result: .noSuggestion(.missingAudio), envelope: [])
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try read(
                        track: audioTrack,
                        asset: asset,
                        mediaRange: mediaRange
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        setCancellationRequested(true)
    }

    private func read(
        track: AVAssetTrack,
        asset: AVAsset,
        mediaRange: CMTimeRange
    ) throws -> TakeTrimAnalysisOutput {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TakeTrimAnalyzerError.cannotRead }
        reader.add(output)
        reader.timeRange = mediaRange
        guard reader.startReading() else { throw TakeTrimAnalyzerError.cannotRead }

        var windows: [AudioEnergyWindow] = []
        while reader.status == .reading {
            if isCancellationRequested {
                reader.cancelReading()
                throw TakeTrimAnalyzerError.cancelled
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            windows.append(contentsOf: energyWindows(from: sample, mediaStart: mediaRange.start.seconds))
        }
        if isCancellationRequested { throw TakeTrimAnalyzerError.cancelled }
        guard reader.status == .completed else { throw TakeTrimAnalyzerError.cannotRead }
        return TakeTrimAnalysisOutput(
            result: detector.detect(windows: windows, mediaDuration: mediaRange.duration.seconds),
            envelope: makeEnvelope(from: windows, binCount: 160)
        )
    }

    private func energyWindows(from sample: CMSampleBuffer, mediaStart: TimeInterval) -> [AudioEnergyWindow] {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              stream.mSampleRate > 0,
              stream.mChannelsPerFrame > 0 else { return [] }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: stream.mChannelsPerFrame, mDataByteSize: 0, mData: nil)
        )
        var retainedBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBuffer
        )
        guard status == noErr, let data = list.mBuffers.mData else { return [] }

        let channels = Int(stream.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sample)
        let floatCount = min(Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size, frameCount * channels)
        guard floatCount > 0 else { return [] }
        let samples = data.assumingMemoryBound(to: Float.self)
        let framesPerWindow = max(1, Int((stream.mSampleRate * 0.02).rounded()))
        let rawPresentationTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let presentationTime = rawPresentationTime.isFinite ? rawPresentationTime - mediaStart : 0
        var result: [AudioEnergyWindow] = []
        var startFrame = 0
        while startFrame < frameCount {
            let endFrame = min(frameCount, startFrame + framesPerWindow)
            var sum: Double = 0
            var count = 0
            for frame in startFrame..<endFrame {
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    guard index < floatCount else { break }
                    let value = Double(samples[index])
                    sum += value * value
                    count += 1
                }
            }
            guard count > 0 else { break }
            let rms = sqrt(sum / Double(count))
            let decibels = Float(max(-100, 20 * log10(max(rms, 0.000_01))))
            result.append(AudioEnergyWindow(
                start: max(0, presentationTime + Double(startFrame) / stream.mSampleRate),
                duration: Double(endFrame - startFrame) / stream.mSampleRate,
                decibels: decibels
            ))
            startFrame = endFrame
        }
        return result
    }

    private func makeEnvelope(from windows: [AudioEnergyWindow], binCount: Int) -> [Float] {
        guard !windows.isEmpty else { return [] }
        let count = min(binCount, windows.count)
        return (0..<count).map { bin in
            let lower = bin * windows.count / count
            let upper = max(lower + 1, (bin + 1) * windows.count / count)
            let peak = windows[lower..<min(upper, windows.count)].map(\.decibels).max() ?? -100
            return min(1, max(0, (peak + 80) / 80))
        }
    }

    private var isCancellationRequested: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }

    private func setCancellationRequested(_ value: Bool) {
        cancellationLock.lock()
        cancellationRequested = value
        cancellationLock.unlock()
    }
}
