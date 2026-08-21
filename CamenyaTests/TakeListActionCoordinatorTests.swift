import XCTest
@testable import Camenya

final class TakeListActionCoordinatorTests: XCTestCase {
    func testExportRunsOnlyAfterTheTakeSheetHasDismissed() {
        var coordinator = TakeListActionCoordinator()

        coordinator.request(.exportProject)

        XCTAssertNil(coordinator.consumeNextAction(sheetIsPresented: true))
        XCTAssertEqual(
            coordinator.consumeNextAction(sheetIsPresented: false),
            .exportProject
        )
        XCTAssertNil(coordinator.consumeNextAction(sheetIsPresented: false))
    }

    func testLatestRequestedActionReplacesAnUnperformedAction() {
        var coordinator = TakeListActionCoordinator()
        coordinator.request(.playProject)

        coordinator.request(.analyzeEdges)

        XCTAssertEqual(
            coordinator.consumeNextAction(sheetIsPresented: false),
            .analyzeEdges
        )
    }

    func testPerTakeSilenceTrimRetainsTheRequestedTake() {
        let takeID = UUID()
        var coordinator = TakeListActionCoordinator()

        coordinator.request(.manageEdges(takeID: takeID))

        XCTAssertEqual(
            coordinator.consumeNextAction(sheetIsPresented: false),
            .manageEdges(takeID: takeID)
        )
    }

}
