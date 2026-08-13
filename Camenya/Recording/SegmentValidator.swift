import AVFoundation
import Foundation

struct SegmentValidator {
    private let minimumDuration: TimeInterval = 0.05

    func validate(_ url: URL) async throws -> TimeInterval {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FinalizationError.exportFailed("The recorded segment is missing.")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) > 0 else {
            throw FinalizationError.exportFailed("The recorded segment is empty.")
        }
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw FinalizationError.missingVideoTrack(url.lastPathComponent) }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw FinalizationError.missingAudioTrack(url.lastPathComponent) }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > minimumDuration else {
            throw FinalizationError.exportFailed("The recorded segment is too short to recover.")
        }
        return duration
    }
}
