@preconcurrency import AVFoundation
import Foundation
import UIKit

struct TakeThumbnailGenerator {
    typealias ThumbnailDataProvider = @Sendable (URL, MediaTime?) async throws -> Data

    private let thumbnailData: ThumbnailDataProvider

    init(thumbnailData: ThumbnailDataProvider? = nil) {
        self.thumbnailData = thumbnailData ?? { movieURL, sourceTime in
            try await TakeThumbnailGenerator.renderThumbnail(
                movieURL: movieURL,
                sourceTime: sourceTime
            )
        }
    }

    func generate(
        movieAt movieURL: URL,
        destination: URL,
        sourceTime: MediaTime? = nil
    ) async throws {
        let data = try await thumbnailData(movieURL, sourceTime)
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw TakeThumbnailError.ownerDeleted
        }

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func renderThumbnail(
        movieURL: URL,
        sourceTime: MediaTime?
    ) async throws -> Data {
        let asset = AVURLAsset(url: movieURL)
        let duration = try await asset.load(.duration)
        let defaultSeconds = max(0, min(0.35, duration.seconds * 0.1))
        let seconds = max(0, min(sourceTime?.seconds ?? defaultSeconds, duration.seconds))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)

        let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        guard let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.82) else {
            throw TakeThumbnailError.encodingFailed
        }
        return data
    }
}

enum TakeThumbnailError: Error {
    case encodingFailed
    case ownerDeleted
}
