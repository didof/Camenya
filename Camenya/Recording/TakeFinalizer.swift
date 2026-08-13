@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import OSLog

struct TakeFinalizer {
    private let logger = Logger(subsystem: "org.camenya.app", category: "Finalization")

    func finalize(_ manifest: TakeManifest, store: TakeManifestStore) async throws -> URL {
        let directory = store.takeDirectory(id: manifest.id)
        switch try FinalizationPlan.make(for: manifest, in: directory) {
        case let .direct(url):
            _ = try await SegmentValidator().validate(url)
            return url
        case let .composition(urls):
            return try await compose(
                urls: urls,
                outputURL: store.finalURL(takeID: manifest.id),
                orientation: manifest.orientation
            )
        }
    }

    private func compose(urls: [URL], outputURL: URL, orientation: TakeOrientation) async throws -> URL {
        logger.info("Composing \(urls.count) segments")
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FinalizationError.exportUnavailable
        }
        var compositionAudio: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var descriptions: [VideoSegmentDescription] = []

        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw FinalizationError.missingVideoTrack(url.lastPathComponent)
            }
            let sourceRange = CMTimeRange(start: .zero, duration: duration)
            try compositionVideo.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                if compositionAudio == nil {
                    compositionAudio = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                guard let compositionAudio else { throw FinalizationError.exportUnavailable }
                try compositionAudio.insertTimeRange(sourceRange, of: sourceAudio, at: cursor)
            }
            descriptions.append(VideoSegmentDescription(
                timeRange: CMTimeRange(start: cursor, duration: duration),
                naturalSize: try await sourceVideo.load(.naturalSize),
                transform: try await sourceVideo.load(.preferredTransform)
            ))
            cursor = CMTimeAdd(cursor, duration)
        }

        let equivalentTransforms = Set(descriptions.map { TransformKey($0.transform) }).count == 1
        if equivalentTransforms, let transform = descriptions.first?.transform {
            compositionVideo.preferredTransform = transform
        }

        let preset = equivalentTransforms ? AVAssetExportPresetPassthrough : AVAssetExportPreset1920x1080
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw FinalizationError.exportUnavailable
        }
        if !equivalentTransforms {
            exporter.videoComposition = normalizedVideoComposition(
                track: compositionVideo,
                descriptions: descriptions,
                orientation: orientation
            )
        }
        if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
        do {
            try await exporter.export(to: outputURL, as: .mov)
        } catch {
            throw FinalizationError.exportFailed(error.localizedDescription)
        }
        _ = try await SegmentValidator().validate(outputURL)
        logger.info("Composition completed")
        return outputURL
    }

    private func normalizedVideoComposition(
        track: AVMutableCompositionTrack,
        descriptions: [VideoSegmentDescription],
        orientation: TakeOrientation
    ) -> AVMutableVideoComposition {
        let canvas = orientation == .portrait
            ? CGSize(width: 1080, height: 1920)
            : CGSize(width: 1920, height: 1080)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = descriptions.map { description in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = description.timeRange
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(normalizedTransform(description.transform, naturalSize: description.naturalSize, canvas: canvas), at: description.timeRange.start)
            instruction.layerInstructions = [layer]
            return instruction
        }
        return videoComposition
    }

    private func normalizedTransform(_ transform: CGAffineTransform, naturalSize: CGSize, canvas: CGSize) -> CGAffineTransform {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        let scale = max(canvas.width / max(width, 1), canvas.height / max(height, 1))
        var result = transform.concatenating(CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY))
        result = result.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        result = result.concatenating(CGAffineTransform(
            translationX: (canvas.width - width * scale) / 2,
            y: (canvas.height - height * scale) / 2
        ))
        return result
    }
}

private struct VideoSegmentDescription {
    let timeRange: CMTimeRange
    let naturalSize: CGSize
    let transform: CGAffineTransform
}

private struct TransformKey: Hashable {
    let a: CGFloat
    let b: CGFloat
    let c: CGFloat
    let d: CGFloat
    let tx: CGFloat
    let ty: CGFloat

    init(_ transform: CGAffineTransform) {
        a = transform.a
        b = transform.b
        c = transform.c
        d = transform.d
        tx = transform.tx
        ty = transform.ty
    }
}
