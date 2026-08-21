import XCTest
@testable import Camenya

final class TakeThumbnailGeneratorTests: XCTestCase {
    func testInvalidMovieDoesNotLeaveAThumbnail() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try Data("not a movie".utf8).write(to: source)

        do {
            try await TakeThumbnailGenerator().generate(movieAt: source, destination: destination)
            XCTFail("Expected invalid media to fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testInFlightGenerationDoesNotRecreateADeletedOwnerDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.mov")
        let owner = root.appendingPathComponent("project/Takes/take", isDirectory: true)
        let destination = owner.appendingPathComponent("thumbnail.jpg")
        let gate = ThumbnailGenerationGate()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)

        let generation = Task {
            try await TakeThumbnailGenerator { _, _ in
                await gate.suspendUntilReleased()
                return Data("thumbnail".utf8)
            }.generate(movieAt: source, destination: destination)
        }

        await gate.waitUntilSuspended()
        try FileManager.default.removeItem(at: owner)
        await gate.release()

        do {
            try await generation.value
            XCTFail("Generation must fail after its owning directory has been deleted")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: owner.path))
        }
    }

    func testRequestedSourceTimeIsForwardedForProjectCoverGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.mov")
        let destination = root.appendingPathComponent("cover.jpg")
        let requestedTime = MediaTime(seconds: 3.25)
        let receivedTime = ThumbnailRequestedTime()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try await TakeThumbnailGenerator { _, time in
            await receivedTime.record(time)
            return Data("cover".utf8)
        }.generate(
            movieAt: source,
            destination: destination,
            sourceTime: requestedTime
        )

        let recordedTime = await receivedTime.value
        XCTAssertEqual(recordedTime, requestedTime)
        XCTAssertEqual(try Data(contentsOf: destination), Data("cover".utf8))
    }
}

private actor ThumbnailRequestedTime {
    private(set) var value: MediaTime?

    func record(_ time: MediaTime?) {
        value = time
    }
}

private actor ThumbnailGenerationGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        suspended = true
        suspensionWaiters.forEach { $0.resume() }
        suspensionWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
