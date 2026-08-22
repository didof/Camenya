@preconcurrency import AVFoundation
import Foundation
import UIKit

enum TimelineTrimFrameSampling {
    static func sourceTimes(in range: TakeRange, count: Int) -> [MediaTime] {
        guard count > 0,
              range.start.seconds.isFinite,
              range.end.seconds.isFinite,
              range.duration > 0 else { return [] }
        return (0..<count).map { index in
            let fraction = (Double(index) + 0.5) / Double(count)
            return MediaTime(seconds: range.start.seconds + range.duration * fraction)
        }
    }
}

enum TimelineFilmstripFrameSampling {
    static let maximumDecodedFrameCount = 64

    struct Metrics: Equatable, Sendable {
        let tileWidth: CGFloat
        let tileCount: Int
        let sampleCount: Int

        func sampleIndex(forTile tileIndex: Int) -> Int {
            guard tileCount > 0, sampleCount > 0 else { return 0 }
            let clampedTile = min(max(0, tileIndex), tileCount - 1)
            return min(sampleCount - 1, clampedTile * sampleCount / tileCount)
        }
    }

    static func metrics(
        width: CGFloat,
        height: CGFloat,
        frameAspectRatio: CGFloat
    ) -> Metrics {
        guard width.isFinite,
              height.isFinite,
              frameAspectRatio.isFinite,
              width > 0,
              height > 0,
              frameAspectRatio > 0 else {
            return Metrics(tileWidth: 1, tileCount: 1, sampleCount: 1)
        }
        let tileWidth = max(1, height * frameAspectRatio)
        let tileCount = max(1, Int(ceil(width / tileWidth)))
        return Metrics(
            tileWidth: tileWidth,
            tileCount: tileCount,
            sampleCount: min(tileCount, maximumDecodedFrameCount)
        )
    }
}

actor TimelineTrimFrameLoader {
    typealias FrameDataProvider = @Sendable (URL, MediaTime) async -> Data?

    private let frameDataProvider: FrameDataProvider?

    init(frameDataProvider: FrameDataProvider? = nil) {
        self.frameDataProvider = frameDataProvider
    }

    func frameData(
        movieURL: URL,
        availableRange: TakeRange,
        count: Int
    ) async -> [Data?] {
        let times = TimelineTrimFrameSampling.sourceTimes(in: availableRange, count: count)
        guard !times.isEmpty else { return [] }
        if let frameDataProvider {
            var output: [Data?] = []
            for time in times {
                guard !Task.isCancelled else { return [] }
                output.append(await frameDataProvider(movieURL, time))
            }
            return output
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)

        var output: [Data?] = []
        for time in times {
            guard !Task.isCancelled else { return [] }
            guard let result = try? await generator.image(
                at: CMTime(seconds: time.seconds, preferredTimescale: 600)
            ), let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.76) else {
                output.append(nil)
                continue
            }
            output.append(data)
        }
        return output
    }
}
