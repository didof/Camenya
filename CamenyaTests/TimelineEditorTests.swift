import XCTest
@testable import Camenya

final class TimelineEditorTests: XCTestCase {
    func testTimelineEditActivityAllowsOnlyOnePersistedMutationUntilFinish() {
        var activity = TimelineEditActivity()

        XCTAssertTrue(activity.begin())
        XCTAssertFalse(activity.begin())

        activity.finish()

        XCTAssertTrue(activity.begin())
    }

    func testTrimRulesRejectNudgesThatWouldCrossMinimumDuration() {
        let available = TakeRange(startSeconds: 0, endSeconds: 10)
        let selection = TakeRange(startSeconds: 2, endSeconds: 3.05)

        XCTAssertNil(TimelineTrimRules.nudgedSelection(
            selection: selection,
            availableRange: available,
            edge: .start,
            direction: .later
        ))
        XCTAssertNil(TimelineTrimRules.nudgedSelection(
            selection: selection,
            availableRange: available,
            edge: .end,
            direction: .earlier
        ))
        XCTAssertEqual(TimelineTrimRules.nudgedSelection(
            selection: selection,
            availableRange: available,
            edge: .start,
            direction: .earlier
        ), TakeRange(startSeconds: 1.9, endSeconds: 3.05))
    }

    func testTrimmingClipPersistsSelectionAndReturnsUpdatedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )

        let outcome = try await editor.perform(
            .trim(
                clipID: completed.clip.id,
                selection: TakeRange(startSeconds: 2, endSeconds: 8)
            ),
            expectedRevision: completed.snapshot.revision,
            modifiedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(outcome.snapshot.revision, StorylineRevision(rawValue: 2))
        XCTAssertEqual(outcome.snapshot.duration, ProjectTime(seconds: 6))
        XCTAssertEqual(outcome.snapshot.clips.first?.availableRange, TakeRange(startSeconds: 0, endSeconds: 10))
        XCTAssertEqual(outcome.snapshot.clips.first?.selection, TakeRange(startSeconds: 2, endSeconds: 8))
        XCTAssertEqual(outcome.project.primaryStoryline.clips.first?.selection, TakeRange(startSeconds: 2, endSeconds: 8))
        XCTAssertNil(outcome.project.takes.first?.trimDecision)
        XCTAssertEqual(try store.load(id: project.id), outcome.project)
    }

    func testResetTrimRestoresClipAvailableRangeRatherThanWholeTake() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        var seeded = try store.load(id: project.id)
        seeded.primaryStoryline.clips[0] = TimelineClip(
            id: completed.clip.id,
            takeID: completed.take.id,
            availableRange: TakeRange(startSeconds: 2, endSeconds: 9),
            selection: TakeRange(startSeconds: 3, endSeconds: 7)
        )
        seeded.primaryStoryline.revision = StorylineRevision(rawValue: 2)
        try store.persist(seeded, expectedRevision: completed.snapshot.revision)

        let outcome = try await editor.perform(
            .resetTrim(clipID: completed.clip.id),
            expectedRevision: StorylineRevision(rawValue: 2)
        )

        XCTAssertEqual(outcome.snapshot.clips.first?.availableRange, TakeRange(startSeconds: 2, endSeconds: 9))
        XCTAssertEqual(outcome.snapshot.clips.first?.selection, TakeRange(startSeconds: 2, endSeconds: 9))
        XCTAssertEqual(outcome.snapshot.duration, ProjectTime(seconds: 7))
    }

    func testTrimNudgesMoveOneEdgeByOneTenthAndCommitSeparately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        let trimmed = try await editor.perform(
            .trim(clipID: completed.clip.id, selection: TakeRange(startSeconds: 2, endSeconds: 8)),
            expectedRevision: completed.snapshot.revision
        )

        let nudgedStart = try await editor.perform(
            .nudgeTrim(clipID: completed.clip.id, edge: .start, direction: .later),
            expectedRevision: trimmed.snapshot.revision
        )
        let nudgedEnd = try await editor.perform(
            .nudgeTrim(clipID: completed.clip.id, edge: .end, direction: .earlier),
            expectedRevision: nudgedStart.snapshot.revision
        )

        XCTAssertEqual(nudgedStart.snapshot.clips.first?.selection, TakeRange(startSeconds: 2.1, endSeconds: 8))
        XCTAssertEqual(nudgedEnd.snapshot.clips.first?.selection, TakeRange(startSeconds: 2.1, endSeconds: 7.9))
        XCTAssertEqual(nudgedStart.snapshot.revision, StorylineRevision(rawValue: 3))
        XCTAssertEqual(nudgedEnd.snapshot.revision, StorylineRevision(rawValue: 4))
    }

    func testSnapshotAdaptsTakeSilenceSuggestionToEachClipAvailableRange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        _ = try store.recordTrimAnalysis(
            projectID: project.id,
            takeID: completed.take.id,
            result: .suggestion(TrimSuggestion(
                range: TakeRange(startSeconds: 2, endSeconds: 9),
                algorithmVersion: 1,
                envelopeFileName: nil
            ))
        )
        var seeded = try store.load(id: project.id)
        seeded.primaryStoryline.clips[0] = TimelineClip(
            id: completed.clip.id,
            takeID: completed.take.id,
            availableRange: TakeRange(startSeconds: 5, endSeconds: 10),
            selection: TakeRange(startSeconds: 5, endSeconds: 10)
        )
        seeded.primaryStoryline.revision = StorylineRevision(rawValue: 2)
        try store.persist(seeded, expectedRevision: completed.snapshot.revision)

        let snapshot = try await editor.snapshot()

        XCTAssertEqual(snapshot.clips.first?.trimSuggestion, TakeRange(startSeconds: 5, endSeconds: 9))
    }

    func testTrimRejectsSelectionShorterThanOneSecondWithoutAdvancingRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )

        do {
            _ = try await editor.perform(
                .trim(
                    clipID: completed.clip.id,
                    selection: TakeRange(startSeconds: 2, endSeconds: 2.9)
                ),
                expectedRevision: completed.snapshot.revision
            )
            XCTFail("Expected the short selection to be rejected")
        } catch {
            XCTAssertEqual(error as? TimelineEditorError, .invalidClip(completed.clip.id))
        }

        let persisted = try await editor.snapshot()
        XCTAssertEqual(persisted.revision, completed.snapshot.revision)
        XCTAssertEqual(persisted.clips.first?.selection, completed.clip.selection)
    }

    func testSplitAtomicallyReplacesClipAndPreservesImmediateOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )

        let outcome = try await editor.perform(
            .split(clipID: completed.clip.id, at: ProjectTime(seconds: 4)),
            expectedRevision: completed.snapshot.revision
        )

        XCTAssertEqual(outcome.snapshot.revision, StorylineRevision(rawValue: 2))
        XCTAssertEqual(outcome.snapshot.duration, completed.snapshot.duration)
        XCTAssertEqual(outcome.snapshot.clips.count, 2)
        XCTAssertEqual(outcome.snapshot.clips.map(\.takeID), [completed.take.id, completed.take.id])
        XCTAssertEqual(outcome.snapshot.clips.map(\.availableRange), [
            TakeRange(startSeconds: 0, endSeconds: 4),
            TakeRange(startSeconds: 4, endSeconds: 10)
        ])
        XCTAssertEqual(outcome.snapshot.clips.map(\.selection), [
            TakeRange(startSeconds: 0, endSeconds: 4),
            TakeRange(startSeconds: 4, endSeconds: 10)
        ])
        XCTAssertFalse(outcome.snapshot.clips.contains(where: { $0.id == completed.clip.id }))
        XCTAssertEqual(Set(outcome.snapshot.clips.map(\.id)).count, 2)
        XCTAssertEqual(
            outcome.focus,
            TimelineEditFocus(
                clipID: outcome.snapshot.clips[1].id,
                projectTime: ProjectTime(seconds: 4)
            )
        )
        XCTAssertEqual(try ProjectExportPlan(snapshot: outcome.snapshot).sources.map(\.selection), [
            TakeRange(startSeconds: 0, endSeconds: 4),
            TakeRange(startSeconds: 4, endSeconds: 10)
        ])
        XCTAssertEqual(try store.load(id: project.id), outcome.project)
    }

    func testSplitPartitionsAvailableRangeAroundSourceTimeForTrimmedClip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 20,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        let trimmed = try await editor.perform(
            .trim(
                clipID: completed.clip.id,
                selection: TakeRange(startSeconds: 2, endSeconds: 18)
            ),
            expectedRevision: completed.snapshot.revision
        )

        let outcome = try await editor.perform(
            .split(clipID: completed.clip.id, at: ProjectTime(seconds: 6)),
            expectedRevision: trimmed.snapshot.revision
        )

        XCTAssertEqual(outcome.snapshot.clips.map(\.availableRange), [
            TakeRange(startSeconds: 0, endSeconds: 8),
            TakeRange(startSeconds: 8, endSeconds: 20)
        ])
        XCTAssertEqual(outcome.snapshot.clips.map(\.selection), [
            TakeRange(startSeconds: 2, endSeconds: 8),
            TakeRange(startSeconds: 8, endSeconds: 18)
        ])
        XCTAssertEqual(outcome.snapshot.duration, ProjectTime(seconds: 16))
        XCTAssertEqual(outcome.focus?.projectTime, ProjectTime(seconds: 6))
        XCTAssertEqual(outcome.focus?.clipID, outcome.snapshot.clips[1].id)
    }

    func testSplitRejectsCutThatWouldCreateClipShorterThanMinimum() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )

        do {
            _ = try await editor.perform(
                .split(clipID: completed.clip.id, at: ProjectTime(seconds: 0.9)),
                expectedRevision: completed.snapshot.revision
            )
            XCTFail("Expected an edge-adjacent split to be rejected")
        } catch {
            XCTAssertEqual(error as? TimelineEditorError, .invalidClip(completed.clip.id))
        }

        let persisted = try await editor.snapshot()
        XCTAssertEqual(persisted.revision, completed.snapshot.revision)
        XCTAssertEqual(persisted.clips.map(\.id), [completed.clip.id])
    }

    func testSplitKeepsApprovedTakeCaptionsAvailableToBothAdjacentClips() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        let captions = TakeCaptionTrack(
            localeIdentifier: "en-US",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 10),
            recognizer: .speechRecognizerIOS18,
            reviewState: .approved,
            cues: [CaptionCue(
                range: TakeRange(startSeconds: 3, endSeconds: 7),
                recognizedText: "one continuous thought",
                text: "one continuous thought",
                confidence: 0.9,
                alternatives: [],
                timedSpans: []
            )]
        )
        var seeded = try store.load(id: project.id)
        seeded.captionConfiguration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower
        )
        seeded.takes[0].captions = captions
        try store.persist(seeded, expectedRevision: completed.snapshot.revision)

        let outcome = try await editor.perform(
            .split(clipID: completed.clip.id, at: ProjectTime(seconds: 4)),
            expectedRevision: completed.snapshot.revision
        )

        XCTAssertEqual(outcome.snapshot.clips.map(\.approvedCaptions), [captions, captions])
        let captionTimeline = ProjectCaptionExportTimeline.make(
            plan: try ProjectExportPlan(snapshot: outcome.snapshot)
        )
        XCTAssertEqual(captionTimeline?.cues.map(\.range), [
            TakeRange(startSeconds: 3, endSeconds: 4),
            TakeRange(startSeconds: 4, endSeconds: 7)
        ])
    }

    func testMoveClipAtomicallyReordersStorylineAndRecalculatesProjectTime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        var revision = StorylineRevision.zero
        var completions: [TakeCompletion] = []
        for (index, duration) in [2.0, 3.0, 4.0].enumerated() {
            let completion = try await editor.completeFinalizedTake(
                FinalizedTake(
                    id: UUID(),
                    movieURL: try makeMovie(in: root),
                    orientation: .portrait,
                    duration: duration,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
                ),
                expectedRevision: revision
            )
            completions.append(completion)
            revision = completion.snapshot.revision
        }

        let outcome = try await editor.perform(
            .move(clipID: completions[2].clip.id, toIndex: 0),
            expectedRevision: revision
        )

        XCTAssertEqual(outcome.snapshot.revision, StorylineRevision(rawValue: 4))
        XCTAssertEqual(outcome.snapshot.clips.map(\.id), [
            completions[2].clip.id,
            completions[0].clip.id,
            completions[1].clip.id
        ])
        XCTAssertEqual(outcome.snapshot.clips.map(\.projectTimeRange), [
            ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 4)),
            ProjectTimeRange(start: ProjectTime(seconds: 4), end: ProjectTime(seconds: 6)),
            ProjectTimeRange(start: ProjectTime(seconds: 6), end: ProjectTime(seconds: 9))
        ])
        XCTAssertEqual(
            outcome.focus,
            TimelineEditFocus(clipID: completions[2].clip.id, projectTime: .zero)
        )
        XCTAssertEqual(
            try ProjectExportPlan(snapshot: outcome.snapshot).sources.map(\.takeID),
            [completions[2].take.id, completions[0].take.id, completions[1].take.id]
        )
        XCTAssertEqual(
            outcome.project.takes.map(\.id),
            completions.map(\.take.id),
            "Reorder changes Clip placement, never immutable Take source order."
        )
        XCTAssertEqual(try store.load(id: project.id), outcome.project)
    }

    func testMoveRejectsSameOrOutOfBoundsDestinationWithoutAdvancingRevision() async throws {
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
                duration: 2,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        let second = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 3,
                createdAt: Date(timeIntervalSince1970: 2)
            ),
            expectedRevision: first.snapshot.revision
        )

        for destination in [1, 2, -1] {
            do {
                _ = try await editor.perform(
                    .move(clipID: second.clip.id, toIndex: destination),
                    expectedRevision: second.snapshot.revision
                )
                XCTFail("Expected destination \(destination) to be rejected")
            } catch {
                XCTAssertEqual(error as? TimelineEditorError, .invalidClip(second.clip.id))
            }
        }

        let persisted = try await editor.snapshot()
        XCTAssertEqual(persisted.revision, second.snapshot.revision)
        XCTAssertEqual(persisted.clips.map(\.id), [first.clip.id, second.clip.id])
    }

    func testRemoveAndRestorePersistExactClipWithoutDeletingTakeMedia() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        var seeded = try store.load(id: project.id)
        seeded.primaryStoryline.clips[0] = TimelineClip(
            id: completed.clip.id,
            takeID: completed.take.id,
            availableRange: TakeRange(startSeconds: 1, endSeconds: 9),
            selection: TakeRange(startSeconds: 2, endSeconds: 8),
            isMuted: true
        )
        try store.persist(seeded, expectedRevision: completed.snapshot.revision)

        let removed = try await editor.perform(
            .remove(clipID: completed.clip.id),
            expectedRevision: completed.snapshot.revision
        )

        XCTAssertTrue(removed.snapshot.clips.isEmpty)
        XCTAssertEqual(removed.snapshot.duration, .zero)
        XCTAssertEqual(removed.project.removedClips.count, 1)
        XCTAssertEqual(removed.project.removedClips[0].clip, seeded.primaryStoryline.clips[0])
        XCTAssertEqual(
            removed.project.removedClips[0].placement,
            TimelinePlacementContext(previousClipID: nil, nextClipID: nil, originalIndex: 0)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.takeMovieURL(projectID: project.id, takeID: completed.take.id).path
        ))

        let restored = try await editor.perform(
            .restore(clipID: completed.clip.id),
            expectedRevision: removed.snapshot.revision
        )

        XCTAssertEqual(restored.project.primaryStoryline.clips, [seeded.primaryStoryline.clips[0]])
        XCTAssertTrue(restored.project.removedClips.isEmpty)
        XCTAssertEqual(restored.snapshot.duration, ProjectTime(seconds: 6))
        XCTAssertEqual(
            restored.focus,
            TimelineEditFocus(clipID: completed.clip.id, projectTime: .zero)
        )
    }

    func testRestoreUsesOriginalNeighborsThenNearestValidPosition() {
        let first = TimelineClip(
            takeID: UUID(),
            availableRange: TakeRange(startSeconds: 0, endSeconds: 2),
            selection: TakeRange(startSeconds: 0, endSeconds: 2)
        )
        let second = TimelineClip(
            takeID: UUID(),
            availableRange: TakeRange(startSeconds: 0, endSeconds: 2),
            selection: TakeRange(startSeconds: 0, endSeconds: 2)
        )
        let third = TimelineClip(
            takeID: UUID(),
            availableRange: TakeRange(startSeconds: 0, endSeconds: 2),
            selection: TakeRange(startSeconds: 0, endSeconds: 2)
        )
        let context = TimelinePlacementContext(
            previousClipID: first.id,
            nextClipID: third.id,
            originalIndex: 1
        )

        XCTAssertEqual(
            TimelineRemovalRules.restorationIndex(
                placement: context,
                activeClips: [first, third]
            ),
            1
        )
        XCTAssertEqual(
            TimelineRemovalRules.restorationIndex(
                placement: context,
                activeClips: [third]
            ),
            0
        )
        XCTAssertEqual(
            TimelineRemovalRules.restorationIndex(
                placement: context,
                activeClips: [second]
            ),
            1
        )
    }

    func testUnusedTakeCanAddFullClipWhileRemovedClipRemainsRecoverable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 7,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        let removed = try await editor.perform(
            .remove(clipID: completed.clip.id),
            expectedRevision: completed.snapshot.revision
        )

        XCTAssertEqual(removed.project.unusedTakes.map(\.id), [completed.take.id])

        let added = try await editor.perform(
            .addFullTakeToStoryline(takeID: completed.take.id),
            expectedRevision: removed.snapshot.revision
        )

        XCTAssertEqual(added.snapshot.clips.count, 1)
        XCTAssertNotEqual(added.snapshot.clips[0].id, completed.clip.id)
        XCTAssertEqual(added.snapshot.clips[0].selection, TakeRange(startSeconds: 0, endSeconds: 7))
        XCTAssertEqual(added.project.removedClips.map(\.id), [completed.clip.id])
        XCTAssertTrue(added.project.unusedTakes.isEmpty)
    }

    func testRemovedClipMetadataMustBeDeletedBeforeUnusedTakeCanBeDeleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 4,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        let removed = try await editor.perform(
            .remove(clipID: completed.clip.id),
            expectedRevision: completed.snapshot.revision
        )

        XCTAssertThrowsError(try store.deleteTake(
            projectID: project.id,
            takeID: completed.take.id
        )) { error in
            XCTAssertEqual(error as? ProjectStoreError, .takeReferencedByStoryline(completed.take.id))
        }

        let discarded = try await editor.perform(
            .deleteRemovedClipPermanently(clipID: completed.clip.id),
            expectedRevision: removed.snapshot.revision
        )
        XCTAssertTrue(discarded.project.removedClips.isEmpty)
        XCTAssertEqual(discarded.project.unusedTakes.map(\.id), [completed.take.id])

        let deleted = try store.deleteTake(projectID: project.id, takeID: completed.take.id)
        XCTAssertTrue(deleted.takes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.takeMovieURL(projectID: project.id, takeID: completed.take.id).path
        ))
    }

    func testOrdinaryTrimThroughApprovedCueOmitsUnsafeCaptionUntilPhaseNineReview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject()
        let editor = TimelineEditor(projectID: project.id, projectStore: store)
        let completed = try await editor.completeFinalizedTake(
            FinalizedTake(
                id: UUID(),
                movieURL: try makeMovie(in: root),
                orientation: .portrait,
                duration: 10,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            expectedRevision: .zero
        )
        var seeded = try store.load(id: project.id)
        seeded.captionConfiguration = ProjectCaptionConfiguration(
            localeIdentifier: "en-US",
            placement: .lower
        )
        seeded.takes[0].captions = TakeCaptionTrack(
            localeIdentifier: "en-US",
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 10),
            recognizer: .speechRecognizerIOS18,
            reviewState: .approved,
            cues: [CaptionCue(
                range: TakeRange(startSeconds: 3, endSeconds: 7),
                recognizedText: "unsafe after trim",
                text: "unsafe after trim",
                confidence: 0.9,
                alternatives: [],
                timedSpans: []
            )]
        )
        try store.persist(seeded, expectedRevision: completed.snapshot.revision)

        let outcome = try await editor.perform(
            .trim(
                clipID: completed.clip.id,
                selection: TakeRange(startSeconds: 5, endSeconds: 10)
            ),
            expectedRevision: completed.snapshot.revision
        )

        XCTAssertNil(outcome.snapshot.clips[0].approvedCaptions)
        XCTAssertEqual(
            ProjectCaptionExportTimeline.make(plan: try ProjectExportPlan(snapshot: outcome.snapshot))?.cues,
            []
        )
    }

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
        XCTAssertEqual(previewSession.state.clips.map(\.thumbnailURL), [
            store.takeThumbnailURL(projectID: project.id, takeID: first.take.id)
        ])
        XCTAssertEqual(previewSession.state.clips.map(\.sourceCreatedAt), [first.take.createdAt])
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
