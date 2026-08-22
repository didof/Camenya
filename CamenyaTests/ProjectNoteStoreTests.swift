import XCTest
@testable import Camenya

@MainActor
final class ProjectNoteStoreTests: XCTestCase {
    func testReadingPositionSurvivesClosingAndReopeningAProjectNote() {
        let store = ProjectNoteStore(text: String(repeating: "line\n", count: 100))

        store.rememberNavigation(cursorUTF16Offset: 180, verticalScrollOffset: 640)
        store.text += "another line"

        XCTAssertEqual(
            store.navigationState(for: store.text),
            ProjectNoteNavigationState(cursorUTF16Offset: 180, verticalScrollOffset: 640)
        )
    }

    func testRestoredCursorIsClampedWhenTheNoteBecomesShorter() {
        let store = ProjectNoteStore(text: "A long project note")
        store.rememberNavigation(cursorUTF16Offset: 18, verticalScrollOffset: 300)

        store.text = "Short"

        XCTAssertEqual(store.navigationState(for: store.text).cursorUTF16Offset, 5)
        XCTAssertEqual(store.navigationState(for: store.text).verticalScrollOffset, 300)
    }
}
