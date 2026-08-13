import Foundation

enum FinalizationPlan: Equatable, Sendable {
    case direct(URL)
    case composition([URL])

    static func make(for manifest: TakeManifest, in directory: URL) throws -> FinalizationPlan {
        let URLs = manifest.orderedSegments.map { directory.appendingPathComponent($0.fileName) }
        guard let first = URLs.first else { throw FinalizationError.noValidSegments }
        return URLs.count == 1 ? .direct(first) : .composition(URLs)
    }
}

enum FinalizationError: Error, LocalizedError {
    case noValidSegments
    case missingVideoTrack(String)
    case missingAudioTrack(String)
    case exportUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noValidSegments: "No valid recorded segments were found."
        case let .missingVideoTrack(file): "The segment \(file) has no video track."
        case let .missingAudioTrack(file): "The segment \(file) has no audio track."
        case .exportUnavailable: "A compatible video export is unavailable."
        case let .exportFailed(reason): "Video finalization failed: \(reason)"
        }
    }
}
