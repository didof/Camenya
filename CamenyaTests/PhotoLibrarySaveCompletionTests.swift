import XCTest
@testable import Camenya

final class PhotoLibrarySaveCompletionTests: XCTestCase {
    func testSuccessfulEmptyTransactionIsRejected() {
        XCTAssertThrowsError(
            try PhotoLibrarySaveCompletion.validate(
                assetRequestCreated: false,
                transactionSucceeded: true,
                error: nil
            )
        ) { error in
            XCTAssertEqual(error as? PhotoLibrarySaveError, .creationRequestFailed)
        }
    }

    func testCreatedAssetAndSuccessfulTransactionAreAccepted() throws {
        XCTAssertNoThrow(
            try PhotoLibrarySaveCompletion.validate(
                assetRequestCreated: true,
                transactionSucceeded: true,
                error: nil
            )
        )
    }
}
