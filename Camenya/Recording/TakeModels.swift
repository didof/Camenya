import Foundation

enum CameraPosition: String, Codable, Equatable, Sendable {
    case front
    case rear

    var toggled: CameraPosition { self == .front ? .rear : .front }
}

enum TakeOrientation: String, Codable, Equatable, Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight
}

enum TakeStatus: String, Codable, Equatable, Sendable {
    case recording
    case paused
    case interrupted
    case finalizing
    case readyToSave
    case completed
    case failed
}

struct Segment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let index: Int
    let fileName: String
    let cameraPosition: CameraPosition
    let createdAt: Date
    let duration: TimeInterval

    init(id: UUID = UUID(), index: Int, fileName: String, cameraPosition: CameraPosition, createdAt: Date, duration: TimeInterval) {
        self.id = id
        self.index = index
        self.fileName = fileName
        self.cameraPosition = cameraPosition
        self.createdAt = createdAt
        self.duration = duration
    }
}

struct TakeManifest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let orientation: TakeOrientation
    var status: TakeStatus
    var segments: [Segment]

    var approximateDuration: TimeInterval {
        segments.reduce(0) { $0 + max(0, $1.duration) }
    }

    var orderedSegments: [Segment] {
        segments.sorted { $0.index < $1.index }
    }
}
