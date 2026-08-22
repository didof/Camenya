@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import OSLog

struct ProjectExportSource: Equatable, Sendable {
    let takeID: UUID
    let url: URL
    let selection: TakeRange?
    let duration: TimeInterval
    let isMuted: Bool

    init(
        takeID: UUID,
        url: URL,
        selection: TakeRange?,
        duration: TimeInterval,
        isMuted: Bool = false
    ) {
        self.takeID = takeID
        self.url = url
        self.selection = selection
        self.duration = duration
        self.isMuted = isMuted
    }
}

struct ProjectExportPlan: Equatable, Sendable {
    let sources: [ProjectExportSource]
    let format: ProjectFormat
    let captionConfiguration: ProjectCaptionConfiguration?
    let captionTimeline: ProjectCaptionExportTimeline?
    let finishingTimeline: ProjectFinishingTimeline?
    let revision: StorylineRevision

    var urls: [URL] { sources.map(\.url) }

    init(
        sources: [ProjectExportSource],
        format: ProjectFormat,
        captionConfiguration: ProjectCaptionConfiguration?,
        captionTimeline: ProjectCaptionExportTimeline? = nil,
        finishingTimeline: ProjectFinishingTimeline? = nil,
        revision: StorylineRevision = .zero
    ) {
        self.sources = sources
        self.format = format
        self.captionConfiguration = captionConfiguration
        self.captionTimeline = captionTimeline
        self.finishingTimeline = finishingTimeline
        self.revision = revision
    }

    init(snapshot: ExportSnapshot) throws {
        guard !snapshot.clips.isEmpty else { throw ProjectExportError.emptyTimeline }
        guard let format = snapshot.format else { throw ProjectExportError.missingFormat }
        sources = snapshot.clips.map { clip in
            ProjectExportSource(
                takeID: clip.takeID,
                url: clip.mediaURL,
                selection: clip.selection,
                duration: clip.selection.duration,
                isMuted: clip.isMuted
            )
        }
        self.format = format
        captionConfiguration = snapshot.captionConfiguration
        captionTimeline = snapshot.captionTimeline
        finishingTimeline = snapshot.finishingTimeline
        revision = snapshot.revision
    }

}

enum ProjectExportError: Error, LocalizedError, Equatable {
    case emptyTimeline
    case missingFormat
    case missingVideoTrack(String)
    case missingAudioTrack(String)
    case invalidTakeRange(UUID)
    case exportUnavailable
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: "A Project needs at least one Storyline Clip before export."
        case .missingFormat: "The Project format is unavailable."
        case let .missingVideoTrack(name): "\(name) has no video track."
        case let .missingAudioTrack(name): "\(name) has no audio track for an unmuted Storyline Clip."
        case .invalidTakeRange: "An approved Take selection is outside its original media. Reset it and try again."
        case .exportUnavailable: "Project export is unavailable."
        case let .exportFailed(message): message
        case .cancelled: "Project export was cancelled."
        }
    }
}

@MainActor
final class ProjectExporter {
    private let logger = Logger(subsystem: "org.camenya.app", category: "ProjectExport")
    private var activeExporter: AVAssetExportSession?
    private var cancellationRequested = false
    private(set) var isActive = false

    var progress: Double {
        Double(activeExporter?.progress ?? 0)
    }

    func export(plan: ProjectExportPlan, to outputURL: URL) async throws -> URL {
        cancellationRequested = false
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ProjectExportError.exportUnavailable
        }
        var compositionAudio: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var descriptions: [ProjectVideoDescription] = []

        for source in plan.sources {
            try checkCancellation()
            let url = source.url
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw ProjectExportError.missingVideoTrack(url.lastPathComponent)
            }
            let originalVideoRange = try await sourceVideo.load(.timeRange)
            let videoRange: CMTimeRange
            if let selection = source.selection {
                let relativeStart = CMTime(seconds: selection.start.seconds, preferredTimescale: 600)
                let selectedDuration = CMTime(seconds: selection.duration, preferredTimescale: 600)
                let candidate = CMTimeRange(
                    start: CMTimeAdd(originalVideoRange.start, relativeStart),
                    duration: selectedDuration
                )
                guard CMTimeRangeContainsTimeRange(originalVideoRange, otherRange: candidate) else {
                    throw ProjectExportError.invalidTakeRange(source.takeID)
                }
                videoRange = candidate
            } else {
                videoRange = originalVideoRange
            }
            let duration = videoRange.duration
            try compositionVideo.insertTimeRange(videoRange, of: sourceVideo, at: cursor)
            if !source.isMuted,
               let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await sourceAudio.load(.timeRange)
                let sharedRange = CMTimeRangeGetIntersection(videoRange, otherRange: audioRange)
                if sharedRange.isValid, !sharedRange.isEmpty {
                    if compositionAudio == nil {
                        compositionAudio = composition.addMutableTrack(
                            withMediaType: .audio,
                            preferredTrackID: kCMPersistentTrackID_Invalid
                        )
                    }
                    guard let compositionAudio else { throw ProjectExportError.exportUnavailable }
                    let offset = CMTimeSubtract(sharedRange.start, videoRange.start)
                    try compositionAudio.insertTimeRange(
                        sharedRange,
                        of: sourceAudio,
                        at: CMTimeAdd(cursor, offset)
                    )
                }
            }
            descriptions.append(ProjectVideoDescription(
                timeRange: CMTimeRange(start: cursor, duration: duration),
                naturalSize: try await sourceVideo.load(.naturalSize),
                transform: try await sourceVideo.load(.preferredTransform)
            ))
            cursor = CMTimeAdd(cursor, duration)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw ProjectExportError.exportUnavailable
        }
        exporter.videoComposition = normalizedVideoComposition(
            track: compositionVideo,
            descriptions: descriptions,
            format: plan.format,
            captions: plan.captionTimeline,
            finishing: plan.finishingTimeline
        )
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        activeExporter = exporter
        isActive = true
        defer {
            activeExporter = nil
            isActive = false
        }
        logger.info("Exporting Project with \(plan.sources.count) Takes")
        do {
            try checkCancellation()
            try await exporter.export(to: outputURL, as: .mov)
            try checkCancellation()
            _ = try await ProjectExportValidator().validate(
                outputURL,
                requiresAudio: plan.sources.contains(where: { !$0.isMuted })
            )
            logger.info("Project export completed")
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            if cancellationRequested || error is CancellationError {
                throw ProjectExportError.cancelled
            }
            if let projectError = error as? ProjectExportError { throw projectError }
            let underlying = error as NSError
            throw ProjectExportError.exportFailed(
                "\(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)] \(underlying.userInfo)"
            )
        }
    }

    func cancel() {
        cancellationRequested = true
        activeExporter?.cancelExport()
    }

    private func checkCancellation() throws {
        if cancellationRequested || Task.isCancelled { throw ProjectExportError.cancelled }
    }

    private func normalizedVideoComposition(
        track: AVMutableCompositionTrack,
        descriptions: [ProjectVideoDescription],
        format: ProjectFormat,
        captions: ProjectCaptionExportTimeline?,
        finishing: ProjectFinishingTimeline?
    ) -> AVMutableVideoComposition {
        let canvas = format == .portrait
            ? CGSize(width: 1080, height: 1920)
            : CGSize(width: 1920, height: 1080)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = descriptions.map { description in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = description.timeRange
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(
                normalizedTransform(description.transform, naturalSize: description.naturalSize, canvas: canvas),
                at: description.timeRange.start
            )
            instruction.layerInstructions = [layer]
            return instruction
        }
        if let finishing,
           !finishing.textOverlays.isEmpty || finishing.captions?.cues.isEmpty == false {
            ProjectFinishingRenderer().install(
                timeline: finishing,
                canvas: canvas,
                videoComposition: videoComposition
            )
        } else if let captions, !captions.cues.isEmpty {
            CaptionBurnInRenderer().install(
                timeline: captions,
                canvas: canvas,
                videoComposition: videoComposition
            )
        }
        return videoComposition
    }

    private func normalizedTransform(
        _ transform: CGAffineTransform,
        naturalSize: CGSize,
        canvas: CGSize
    ) -> CGAffineTransform {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        let scale = max(canvas.width / max(width, 1), canvas.height / max(height, 1))
        var result = transform.concatenating(CGAffineTransform(
            translationX: -transformed.minX,
            y: -transformed.minY
        ))
        result = result.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        result = result.concatenating(CGAffineTransform(
            translationX: (canvas.width - width * scale) / 2,
            y: (canvas.height - height * scale) / 2
        ))
        return result
    }
}

struct ProjectExportValidator {
    private let minimumDuration: TimeInterval = 0.05

    func validate(_ url: URL, requiresAudio: Bool) async throws -> TimeInterval {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectExportError.exportFailed("The Project export is missing.")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) > 0 else {
            throw ProjectExportError.exportFailed("The Project export is empty.")
        }
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProjectExportError.missingVideoTrack(url.lastPathComponent)
        }
        if requiresAudio,
           try await asset.loadTracks(withMediaType: .audio).isEmpty {
            throw ProjectExportError.missingAudioTrack(url.lastPathComponent)
        }
        let duration = try await videoTrack.load(.timeRange).duration.seconds
        guard duration.isFinite, duration > minimumDuration else {
            throw ProjectExportError.exportFailed("The Project export is too short to recover.")
        }
        return duration
    }
}

private struct ProjectVideoDescription {
    let timeRange: CMTimeRange
    let naturalSize: CGSize
    let transform: CGAffineTransform
}
