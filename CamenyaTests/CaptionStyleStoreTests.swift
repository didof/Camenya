import XCTest
@testable import Camenya

final class CaptionStyleStoreTests: XCTestCase {
    func testSavedCustomStylePersistsAcrossProjectsAndSameNameUpdatesInPlace() throws {
        let suiteName = "CaptionStyleStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CaptionStyleStore(defaults: defaults)
        var firstCustomization = CaptionStyleCustomization()
        firstCustomization.fontDesign = .rounded
        firstCustomization.accentColor = .cyan

        let first = store.save(name: "Creator", customization: firstCustomization)

        XCTAssertEqual(store.load(), [first])
        var updatedCustomization = firstCustomization
        updatedCustomization.background = .shadow
        let updated = CaptionStyleStore(defaults: defaults).save(
            name: " creator ",
            customization: updatedCustomization
        )

        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.name, "creator")
        XCTAssertEqual(store.load(), [updated])
        XCTAssertEqual(store.load().first?.customization.background, .shadow)

        store.delete(id: updated.id)
        XCTAssertTrue(store.load().isEmpty)
    }
}
