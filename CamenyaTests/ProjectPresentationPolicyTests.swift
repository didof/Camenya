import XCTest
@testable import Camenya

final class ProjectPresentationPolicyTests: XCTestCase {
    func testProjectMediaEditFailureRetriesTheExactFailedEdit() {
        let edit = TimelineEdit.addFullTakeToStoryline(takeID: UUID())
        let failure = ProjectMediaEditFailure(edit: edit)

        XCTAssertEqual(failure.retryEdit, edit)
    }

    func testLibraryCoverFollowsLeadingStorylineClipRatherThanTakeOrder() throws {
        let firstTake = ProjectTake(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            duration: 4,
            thumbnailFileName: "first.jpg"
        )
        let leadingTake = ProjectTake(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 2),
            duration: 6,
            thumbnailFileName: "leading.jpg"
        )
        let leadingClip = TimelineClip(
            takeID: leadingTake.id,
            availableRange: TakeRange(startSeconds: 0, endSeconds: 6),
            selection: TakeRange(startSeconds: 1, endSeconds: 5)
        )
        let project = ProjectManifest(
            createdAt: .distantPast,
            modifiedAt: .distantPast,
            name: "Project",
            takes: [firstTake, leadingTake],
            primaryStoryline: PrimaryStoryline(clips: [leadingClip])
        )

        XCTAssertEqual(ProjectPresentationPolicy.coverTake(in: project)?.id, leadingTake.id)
        XCTAssertEqual(ProjectPresentationPolicy.coverTake(in: project)?.thumbnailFileName, "leading.jpg")
        let coverSource = try XCTUnwrap(ProjectPresentationPolicy.coverSource(in: project))
        XCTAssertEqual(coverSource.sourceTime.seconds, 1, accuracy: 0.001)
    }

    func testEmptyStorylineUsesNeutralLibraryPlaceholder() {
        let project = ProjectManifest(
            createdAt: .distantPast,
            modifiedAt: .distantPast,
            name: "Empty"
        )

        XCTAssertNil(ProjectPresentationPolicy.coverTake(in: project))
    }

    func testNewProjectEntersCaptureAndExistingProjectEntersWorkspace() {
        XCTAssertEqual(ProjectPresentationPolicy.initialDestination(newlyCreated: true), .capture)
        XCTAssertEqual(ProjectPresentationPolicy.initialDestination(newlyCreated: false), .workspace)
    }

    func testOnlyContentlessAutomaticallyNamedProjectIsDiscardable() {
        let automatic = ProjectManifest(
            createdAt: .distantPast,
            modifiedAt: .distantPast,
            name: "Automatic",
            isAutomaticallyNamed: true
        )

        XCTAssertTrue(ProjectPresentationPolicy.shouldDiscardDraft(
            automatic,
            hasRecoverableMedia: false
        ))

        var withNote = automatic
        withNote.note = "Keep this cue"
        XCTAssertFalse(ProjectPresentationPolicy.shouldDiscardDraft(
            withNote,
            hasRecoverableMedia: false
        ))

        var renamed = automatic
        renamed.isAutomaticallyNamed = false
        XCTAssertFalse(ProjectPresentationPolicy.shouldDiscardDraft(
            renamed,
            hasRecoverableMedia: false
        ))

        XCTAssertFalse(ProjectPresentationPolicy.shouldDiscardDraft(
            automatic,
            hasRecoverableMedia: true
        ))
    }

    func testRemovedClipReferenceKeepsTakeOutOfUnusedMedia() throws {
        let take = ProjectTake(
            id: UUID(),
            createdAt: .distantPast,
            duration: 4
        )
        let clip = TimelineClip(
            takeID: take.id,
            availableRange: TakeRange(startSeconds: 0, endSeconds: 4),
            selection: TakeRange(startSeconds: 1, endSeconds: 3)
        )
        let project = ProjectManifest(
            createdAt: .distantPast,
            modifiedAt: .distantPast,
            name: "Project",
            takes: [take],
            primaryStoryline: PrimaryStoryline(),
            removedClips: [RemovedTimelineClip(
                clip: clip,
                placement: TimelinePlacementContext(
                    previousClipID: nil,
                    nextClipID: nil,
                    originalIndex: 0
                )
            )]
        )

        XCTAssertTrue(project.unusedTakes.isEmpty)
        XCTAssertEqual(project.usedTakes.map(\.id), [take.id])
        XCTAssertTrue(ProjectPresentationPolicy.canAddFullTakeToStoryline(
            takeID: take.id,
            in: project
        ))

        var withActiveClip = project
        withActiveClip.primaryStoryline.clips = [clip]
        XCTAssertFalse(ProjectPresentationPolicy.canAddFullTakeToStoryline(
            takeID: take.id,
            in: withActiveClip
        ))
        XCTAssertFalse(ProjectPresentationPolicy.canAddFullTakeToStoryline(
            takeID: UUID(),
            in: project
        ))
    }

    func testWorkspacePlaybackAndChromePoliciesExposeRecoveryAndTemporaryControls() {
        XCTAssertEqual(
            ProjectPresentationPolicy.viewerPrimaryAction(isPreparationFailed: true),
            .retryPreparation
        )
        XCTAssertEqual(
            ProjectPresentationPolicy.viewerPrimaryAction(isPreparationFailed: false),
            .togglePlayback
        )
        XCTAssertFalse(ProjectPresentationPolicy.shouldHideViewerControls(
            isPlaying: true,
            revealStartedAt: 10,
            now: 11.9
        ))
        XCTAssertTrue(ProjectPresentationPolicy.shouldHideViewerControls(
            isPlaying: true,
            revealStartedAt: 10,
            now: 12
        ))
    }

    func testClipPreparationCountIncludesTakeAndProjectedCaptionIssues() {
        let takeID = UUID()
        let clip = TimelineClip(
            takeID: takeID,
            availableRange: TakeRange(startSeconds: 0, endSeconds: 4),
            selection: TakeRange(startSeconds: 0, endSeconds: 4)
        )
        let issue = CaptionTimelineIssue(
            takeID: takeID,
            cueID: UUID(),
            fragments: [CaptionTimelineFragment(
                clipID: clip.id,
                sourceRange: TakeRange(startSeconds: 1, endSeconds: 2)
            )],
            reason: .boundaryCut
        )

        XCTAssertEqual(ProjectPresentationPolicy.preparationIssueCount(
            for: clip,
            trimReviewTakeIDs: [takeID],
            captionReviewTakeIDs: [takeID],
            captionTimelineIssues: [issue]
        ), 3)
    }

    @MainActor
    func testLibraryLaunchPrunesOnlyContentlessAutomaticDrafts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let discarded = try store.createProject(createdAt: Date(timeIntervalSince1970: 1))
        let preserved = try store.createProject(createdAt: Date(timeIntervalSince1970: 2))
        _ = try store.updateNote(projectID: preserved.id, text: "Next line")
        let library = ProjectLibraryModel(store: store)

        library.load()

        XCTAssertEqual(library.projects.map(\.id), [preserved.id])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.projectDirectory(id: discarded.id).path
        ))
    }

    @MainActor
    func testLibraryNeverPrunesAutomaticDraftWithCorruptRecoverableTakeManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(projectsRoot: root)
        let project = try store.createProject(createdAt: .distantPast)
        let takeStore = store.takeManifestStore(projectID: project.id)
        let take = try takeStore.createTake(orientation: .portrait)
        try Data("not valid json".utf8).write(
            to: takeStore.takeDirectory(id: take.id).appendingPathComponent("manifest.json")
        )
        try Data("recoverable segment".utf8).write(
            to: takeStore.segmentURL(takeID: take.id, index: 0)
        )
        let library = ProjectLibraryModel(store: store)

        library.load()

        XCTAssertEqual(library.projects.map(\.id), [project.id])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: takeStore.segmentURL(takeID: take.id, index: 0).path
        ))
    }
}
