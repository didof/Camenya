import XCTest
@testable import Camenya

final class StoragePreflightTests: XCTestCase {
    func testExportRequiresRoomForTheOutputAndAConservativeReserve() {
        let sourceBytes: Int64 = 900 * 1_024 * 1_024

        let required = StoragePreflight.exportRequiredBytes(sourceBytes: sourceBytes)

        XCTAssertEqual(required, sourceBytes + StoragePreflight.outputReserveBytes)
        XCTAssertFalse(StoragePreflight.hasCapacity(requiredBytes: required, availableBytes: required - 1))
        XCTAssertTrue(StoragePreflight.hasCapacity(requiredBytes: required, availableBytes: required))
    }
}
