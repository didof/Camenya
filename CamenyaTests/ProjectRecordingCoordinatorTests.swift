import XCTest
@testable import Camenya

final class ProjectRecordingCoordinatorTests: XCTestCase {
    func testCompletedRecordingBecomesADurableProjectTake() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectStore = ProjectStore(projectsRoot: root)
        let project = try projectStore.createProject(createdAt: Date(timeIntervalSince1970: 100))
        let takeStore = projectStore.takeManifestStore(projectID: project.id)
        var take = try takeStore.createTake(orientation: .portrait, createdAt: Date(timeIntervalSince1970: 110))
        let segmentURL = takeStore.segmentURL(takeID: take.id, index: 0)
        try Data("movie".utf8).write(to: segmentURL)
        take.segments = [Segment(index: 0, fileName: segmentURL.lastPathComponent, cameraPosition: .front, createdAt: take.createdAt, duration: 12)]
        take.status = .readyToSave
        try takeStore.save(take)

        let coordinator = ProjectRecordingCoordinator(projectID: project.id, projectStore: projectStore)
        let updated = try coordinator.complete(take: take, finalizedMovieAt: segmentURL, completedAt: Date(timeIntervalSince1970: 120))

        XCTAssertEqual(updated.takes.map(\.id), [take.id])
        XCTAssertEqual(try Data(contentsOf: projectStore.takeMovieURL(projectID: project.id, takeID: take.id)), Data("movie".utf8))
        XCTAssertTrue(projectStore.unfinishedTakes(projectID: project.id).isEmpty)
    }
}
