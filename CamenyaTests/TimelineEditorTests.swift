import XCTest
@testable import Camenya

final class TimelineEditorTests: XCTestCase {
    func testCompletingFinalizedTakeCreatesDistinctFullRangeClip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        try Data("movie".utf8).write(to: source)
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: Date(timeIntervalSince1970: 100))
        let takeID = UUID()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let recoveryMarker = store.takeMovieURL(projectID: project.id, takeID: takeID)
            .deletingLastPathComponent()
            .appendingPathComponent("manifest.json")
        try FileManager.default.createDirectory(
            at: recoveryMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("recoverable".utf8).write(to: recoveryMarker)

        let completion = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: takeID,
                movieURL: source,
                orientation: .portrait,
                duration: 12,
                createdAt: Date(timeIntervalSince1970: 110)
            ),
            expectedRevision: .zero
        )

        XCTAssertEqual(completion.take.id, takeID)
        XCTAssertNotEqual(completion.clip.id.rawValue, takeID)
        XCTAssertEqual(completion.clip.takeID, takeID)
        XCTAssertEqual(completion.clip.availableRange, TakeRange(startSeconds: 0, endSeconds: 12))
        XCTAssertEqual(completion.clip.selection, TakeRange(startSeconds: 0, endSeconds: 12))
        XCTAssertEqual(completion.snapshot.revision, StorylineRevision(rawValue: 1))
        XCTAssertEqual(completion.snapshot.clips.map(\.id), [completion.clip.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryMarker.path))
        XCTAssertEqual(
            try Data(contentsOf: store.takeMovieURL(projectID: project.id, takeID: takeID)),
            Data("movie".utf8)
        )
    }

    func testRetryingCommittedTakeReturnsTheOriginalClipWithoutAdvancingRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        try Data("movie".utf8).write(to: source)
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let finalizedTake = FinalizedTake(
            id: UUID(),
            movieURL: source,
            orientation: .portrait,
            duration: 5,
            createdAt: Date(timeIntervalSince1970: 110)
        )

        let first = try await editor.completeFinalizedTake(
            finalizedTake,
            expectedRevision: .zero
        )
        let retried = try await editor.completeFinalizedTake(
            finalizedTake,
            expectedRevision: .zero
        )
        let reloaded = try await TimelineEditor(
            projectID: project.id,
            projectStore: store
        ).snapshot()

        XCTAssertEqual(retried.clip.id, first.clip.id)
        XCTAssertEqual(retried.snapshot.revision, StorylineRevision(rawValue: 1))
        XCTAssertEqual(retried.snapshot.clips.count, 1)
        XCTAssertEqual(reloaded, retried.snapshot)
    }

    func testProjectTimeMapsHardCutBoundaryToTheFollowingClip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let firstID = UUID()
        let secondID = UUID()

        _ = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: firstID,
                movieURL: try makeMovie(in: root),
                orientation: .landscapeLeft,
                duration: 3,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        let completion = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: secondID,
                movieURL: try makeMovie(in: root),
                orientation: .landscapeLeft,
                duration: 2,
                createdAt: Date(timeIntervalSince1970: 2)
            ),
            expectedRevision: StorylineRevision(rawValue: 1)
        )

        let withinFirst = completion.snapshot.position(at: ProjectTime(seconds: 1))
        let atCut = completion.snapshot.position(at: ProjectTime(seconds: 3))

        XCTAssertEqual(withinFirst?.takeID, firstID)
        XCTAssertEqual(withinFirst?.sourceTime, MediaTime(seconds: 1))
        XCTAssertEqual(atCut?.takeID, secondID)
        XCTAssertEqual(atCut?.sourceTime, MediaTime(seconds: 0))
        XCTAssertNil(completion.snapshot.position(at: ProjectTime(seconds: 5)))
        XCTAssertNil(completion.snapshot.position(at: ProjectTime(seconds: -0.1)))
        XCTAssertNil(completion.snapshot.position(at: ProjectTime(seconds: .nan)))
    }

    func testLoadingSchemaThreeManifestPersistsStablePrimaryStorylineWithoutChangingMedia() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let projectID = UUID()
        let first = ProjectTake(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            duration: 3
        )
        let second = ProjectTake(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2),
            duration: 2
        )
        let legacy = LegacyProjectManifest(
            schemaVersion: 3,
            id: projectID,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 2),
            name: "Legacy",
            format: .portrait,
            note: "",
            takes: [first, second],
            recoveryState: .clean,
            captionConfiguration: nil
        )
        let projectDirectory = store.projectDirectory(id: projectID)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(
            to: projectDirectory.appendingPathComponent("project.json")
        )
        for take in legacy.takes {
            let movie = store.takeMovieURL(projectID: projectID, takeID: take.id)
            try FileManager.default.createDirectory(
                at: movie.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(take.id.uuidString.utf8).write(to: movie)
        }

        let firstSnapshot = try await TimelineEditor(
            projectID: projectID,
            projectStore: store
        ).snapshot()
        let reloaded = try ProjectStore(projectsRoot: root).load(id: projectID)
        let secondSnapshot = try await TimelineEditor(
            projectID: projectID,
            projectStore: ProjectStore(projectsRoot: root)
        ).snapshot()

        XCTAssertEqual(reloaded.schemaVersion, ProjectManifest.currentSchemaVersion)
        XCTAssertEqual(firstSnapshot.revision, .zero)
        XCTAssertEqual(firstSnapshot.clips.map(\.takeID), [first.id, second.id])
        XCTAssertEqual(firstSnapshot.clips.map(\.selection), [
            TakeRange(startSeconds: 0, endSeconds: 3),
            TakeRange(startSeconds: 0, endSeconds: 2)
        ])
        XCTAssertEqual(firstSnapshot.clips.map(\.projectTimeRange), [
            ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 3)),
            ProjectTimeRange(start: ProjectTime(seconds: 3), end: ProjectTime(seconds: 5))
        ])
        XCTAssertEqual(secondSnapshot, firstSnapshot)
        for take in legacy.takes {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: store.takeMovieURL(projectID: projectID, takeID: take.id).path
            ))
        }
    }

    @MainActor
    func testPreviewAndExportAdaptersRemainOnTheSameImmutableSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let first = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 3,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        let sharedSnapshot = first.snapshot

        _ = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 2,
                createdAt: Date(timeIntervalSince1970: 2)
            ),
            expectedRevision: sharedSnapshot.revision
        )

        let previewSession = TimelinePlaybackSession(snapshot: sharedSnapshot)
        let exportPlan = try ProjectExportPlan(snapshot: sharedSnapshot)

        XCTAssertEqual(exportPlan.revision, sharedSnapshot.revision)
        XCTAssertEqual(previewSession.state.revision, sharedSnapshot.revision)
        XCTAssertEqual(previewSession.state.clips.map(\.id), sharedSnapshot.clips.map(\.id))
        XCTAssertEqual(exportPlan.urls, sharedSnapshot.clips.map(\.mediaURL))
        XCTAssertEqual(exportPlan.sources.map(\.selection), sharedSnapshot.clips.map(\.selection))
        XCTAssertEqual(exportPlan.sources.count, 1)
    }

    func testStaleCompletionCannotWriteMediaOrOverwriteNewerStoryline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let firstEditor = TimelineEditor(projectID: project.id, projectStore: store)
        let staleEditor = TimelineEditor(projectID: project.id, projectStore: store)
        let committedID = UUID()
        let staleID = UUID()
        let staleSource = try makeMovie(in: root)

        _ = try await firstEditor.completeFinalizedTake(
            FinalizedTake(
                id: committedID,
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 3,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )

        do {
            _ = try await staleEditor.completeFinalizedTake(
                FinalizedTake(
                    id: staleID,
                    movieURL: staleSource,
                    orientation: .portrait,
                    duration: 2,
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
                expectedRevision: .zero
            )
            XCTFail("Expected stale revision")
        } catch {
            XCTAssertEqual(
                error as? TimelineEditorError,
                .staleRevision(expected: .zero, actual: StorylineRevision(rawValue: 1))
            )
        }

        let snapshot = try await firstEditor.snapshot()
        XCTAssertEqual(snapshot.clips.map(\.takeID), [committedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleSource.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.takeMovieURL(projectID: project.id, takeID: staleID).path
        ))
    }

    func testRetryRemainsIdempotentAfterStorylineAdvances() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let original = FinalizedTake(
            id: UUID(),
            movieURL: try makeMovie(in: root),
            orientation: .portrait,
            duration: 3,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let first = try await editor.completeFinalizedTake(original, expectedRevision: .zero)
        _ = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 2,
                createdAt: Date(timeIntervalSince1970: 2)
            ),
            expectedRevision: first.snapshot.revision
        )

        let retried = try await editor.completeFinalizedTake(original, expectedRevision: .zero)

        XCTAssertEqual(retried.clip.id, first.clip.id)
        XCTAssertEqual(retried.snapshot.revision, StorylineRevision(rawValue: 2))
        XCTAssertEqual(retried.snapshot.clips.count, 2)
        XCTAssertEqual(Set(retried.snapshot.clips.map(\.takeID)).count, 2)
    }

    func testConcurrentCompletionsCannotBothReplaceTheSameRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let firstSource = try makeMovie(in: root)
        let secondSource = try makeMovie(in: root)
        let first = TimelineEditor(projectID: project.id, projectStore: store)
        let second = TimelineEditor(projectID: project.id, projectStore: store)
        let firstID = UUID()
        let secondID = UUID()
        let firstTask = Task {
            try await first.completeFinalizedTake(
                FinalizedTake(
                    id: firstID,
                    movieURL: firstSource,
                    orientation: .portrait,
                    duration: 2,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                expectedRevision: .zero
            )
        }
        let secondTask = Task {
            try await second.completeFinalizedTake(
                FinalizedTake(
                    id: secondID,
                    movieURL: secondSource,
                    orientation: .portrait,
                    duration: 2,
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
                expectedRevision: .zero
            )
        }

        var completions: [TakeCompletion] = []
        var staleFailureCount = 0
        for task in [firstTask, secondTask] {
            do {
                completions.append(try await task.value)
            } catch TimelineEditorError.staleRevision(expected: .zero, actual: StorylineRevision(rawValue: 1)) {
                staleFailureCount += 1
            }
        }

        let persisted = try await first.snapshot()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(staleFailureCount, 1)
        XCTAssertEqual(persisted.revision, StorylineRevision(rawValue: 1))
        XCTAssertEqual(persisted.clips.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSource.path))
    }

    private func makeMovie(in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory
            .appendingPathComponent("\(UUID().uuidString).mov")
        try Data("movie".utf8).write(to: url)
        return url
    }
}

private struct LegacyProjectManifest: Encodable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let modifiedAt: Date
    let name: String
    let format: ProjectFormat?
    let note: String
    let takes: [ProjectTake]
    let recoveryState: ProjectRecoveryState?
    let captionConfiguration: ProjectCaptionConfiguration?
}
