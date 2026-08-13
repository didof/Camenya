@preconcurrency import AVFoundation
import Foundation

struct CaptionAudioExtractor: Sendable {
    private let maximumTrackEndTolerance = CMTime(seconds: 0.25, preferredTimescale: 600)

    func extract(from movieURL: URL, range: TakeRange, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: movieURL)
        guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CaptionTranscriptionError.missingAudio
        }
        let originalRange = try await sourceAudio.load(.timeRange)
        let requestedStart = CMTimeAdd(
            originalRange.start,
            CMTime(seconds: range.start.seconds, preferredTimescale: 600)
        )
        let requestedEnd = CMTimeAdd(
            requestedStart,
            CMTime(seconds: range.duration, preferredTimescale: 600)
        )
        let availableEnd = CMTimeRangeGetEnd(originalRange)
        guard CMTimeCompare(requestedStart, originalRange.start) >= 0,
              CMTimeCompare(requestedStart, availableEnd) < 0 else {
            throw CaptionTranscriptionError.invalidSourceRange
        }
        let extractionEnd: CMTime
        if CMTimeCompare(requestedEnd, availableEnd) > 0 {
            let overrun = CMTimeSubtract(requestedEnd, availableEnd)
            guard CMTimeCompare(overrun, maximumTrackEndTolerance) <= 0 else {
                throw CaptionTranscriptionError.invalidSourceRange
            }
            extractionEnd = availableEnd
        } else {
            extractionEnd = requestedEnd
        }
        let extractionRange = CMTimeRange(start: requestedStart, end: extractionEnd)
        guard CMTimeCompare(extractionRange.duration, .zero) > 0,
              CMTimeRangeContainsTimeRange(originalRange, otherRange: extractionRange) else {
            throw CaptionTranscriptionError.invalidSourceRange
        }
        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CaptionTranscriptionError.missingAudio
        }
        try audioTrack.insertTimeRange(extractionRange, of: sourceAudio, at: .zero)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw CaptionTranscriptionError.missingAudio
        }
        do {
            try await exporter.export(to: outputURL, as: .m4a)
        } catch is CancellationError {
            throw CaptionTranscriptionError.cancelled
        } catch {
            throw CaptionTranscriptionError.recognitionFailed(
                "The Take audio couldn't be prepared for on-device captions."
            )
        }
    }
}
