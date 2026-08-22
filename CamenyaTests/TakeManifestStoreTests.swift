import XCTest
@testable import Camenya

final class TakeManifestStoreTests: XCTestCase {
    func testDraftWithoutCompletedSegmentsIsNotOfferedForRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TakeManifestStore(recordingsRoot: root)

        _ = try store.createTake(orientation: .portrait)

        XCTAssertTrue(store.unfinishedTakes().isEmpty)
    }

    func testManifestRoundTripPreservesDeterministicSegmentOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TakeManifestStore(recordingsRoot: root)
        var manifest = try store.createTake(orientation: .portrait, createdAt: Date(timeIntervalSince1970: 123))
        manifest.segments = [
            Segment(index: 1, fileName: "segment-001.mov", cameraPosition: .rear, createdAt: Date(timeIntervalSince1970: 125), duration: 8),
            Segment(index: 0, fileName: "segment-000.mov", cameraPosition: .front, createdAt: Date(timeIntervalSince1970: 124), duration: 12)
        ]
        try store.save(manifest)
        let loaded = try store.load(id: manifest.id)
        XCTAssertEqual(loaded.segments.map(\.index), [0, 1])
        XCTAssertEqual(loaded.approximateDuration, 20, accuracy: 0.001)
        XCTAssertEqual(store.unfinishedTakes().map(\.id), [manifest.id])
        try store.deleteTake(id: manifest.id)
        XCTAssertTrue(store.unfinishedTakes().isEmpty)
    }
}
