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
