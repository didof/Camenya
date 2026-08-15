import XCTest
@testable import Camenya

final class ProjectRowPresentationTests: XCTestCase {
    func testLabelIsProjectName() {
        let project = makeProject(name: "Launch Video")
        let presentation = makePresentation(project: project)

        XCTAssertEqual(presentation.accessibilityLabel, "Launch Video")
    }

    func testSingularTakeWording() {
        let project = makeProject(takes: [makeTake()])
        let presentation = makePresentation(project: project)

        XCTAssertTrue(presentation.accessibilityValue.contains("1 Take"))
        XCTAssertFalse(presentation.accessibilityValue.contains("1 Takes"))
    }

    func testPluralTakeWording() {
        let project = makeProject(takes: [makeTake(), makeTake()])
        let presentation = makePresentation(project: project)

        XCTAssertTrue(presentation.accessibilityValue.contains("2 Takes"))
    }

    func testEmptyProjectUsesNaturalWording() {
        let project = makeProject(takes: [])
        let presentation = makePresentation(project: project)

        XCTAssertTrue(presentation.accessibilityValue.contains("No Takes"))
        XCTAssertTrue(presentation.accessibilityValue.contains("00:00"))
        XCTAssertFalse(presentation.accessibilityValue.contains("Portrait"))
        XCTAssertFalse(presentation.accessibilityValue.contains("Landscape"))
    }

    func testOptionalFormatIsIncludedWhenKnown() {
        let project = makeProject(format: .portrait)
        let presentation = makePresentation(project: project)

        XCTAssertTrue(presentation.accessibilityValue.contains("Portrait"))
    }

    func testOptionalFormatIsOmittedWhenUnknown() {
        let project = makeProject(format: nil)
        let presentation = makePresentation(project: project)

        XCTAssertFalse(presentation.accessibilityValue.contains("Portrait"))
        XCTAssertFalse(presentation.accessibilityValue.contains("Landscape"))
    }

    func testHintDescribesOpenAction() {
        let presentation = makePresentation(project: makeProject())

        XCTAssertEqual(presentation.accessibilityHint, "Opens the Project")
    }

    private func makePresentation(project: ProjectManifest) -> ProjectRowPresentation {
        ProjectRowPresentation(
            project: project,
            storageBytes: 1_048_576,
            modifiedAtDescription: "Jan 1, 2026 at 9:00 AM",
            storageDescription: "1 MB"
        )
    }

    private func makeProject(
        name: String = "Demo",
        takes: [ProjectTake] = [makeTake()],
        format: ProjectFormat? = .landscape
    ) -> ProjectManifest {
        ProjectManifest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            takes: takes,
            format: format
        )
    }

    private func makeTake() -> ProjectTake {
        ProjectTake(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 3,
            movieFileName: "take.mov"
        )
    }
}
