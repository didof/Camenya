import Foundation

enum TakeManifestStoreError: Error, LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable: "Application Support is unavailable."
        }
    }
}

struct TakeManifestStore: Sendable {
    let recordingsRoot: URL

    init(recordingsRoot: URL? = nil) {
        if let recordingsRoot {
            self.recordingsRoot = recordingsRoot
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.recordingsRoot = support.appendingPathComponent("Recordings", isDirectory: true)
        }
    }

    func createTake(orientation: TakeOrientation, createdAt: Date = Date()) throws -> TakeManifest {
        let manifest = TakeManifest(id: UUID(), createdAt: createdAt, orientation: orientation, status: .recording, segments: [])
        try FileManager.default.createDirectory(at: takeDirectory(id: manifest.id), withIntermediateDirectories: true)
        try save(manifest)
        return manifest
    }

    func save(_ manifest: TakeManifest) throws {
        try FileManager.default.createDirectory(at: takeDirectory(id: manifest.id), withIntermediateDirectories: true)
        var normalized = manifest
        normalized.segments = manifest.orderedSegments
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(normalized).write(to: manifestURL(id: manifest.id), options: .atomic)
    }

    func load(id: UUID) throws -> TakeManifest {
        let data = try Data(contentsOf: manifestURL(id: id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(TakeManifest.self, from: data)
        manifest.segments = manifest.orderedSegments
        return manifest
    }

    func unfinishedTakes() -> [TakeManifest] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? load(id: $0) }
            .filter { $0.status != .completed && !$0.segments.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func deleteTake(id: UUID) throws {
        let directory = takeDirectory(id: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func takeDirectory(id: UUID) -> URL {
        recordingsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func segmentURL(takeID: UUID, index: Int) -> URL {
        takeDirectory(id: takeID).appendingPathComponent(String(format: "segment-%03d.mov", index))
    }

    func finalURL(takeID: UUID) -> URL {
        takeDirectory(id: takeID).appendingPathComponent("final.mov")
    }

    private func manifestURL(id: UUID) -> URL {
        takeDirectory(id: id).appendingPathComponent("manifest.json")
    }
}
