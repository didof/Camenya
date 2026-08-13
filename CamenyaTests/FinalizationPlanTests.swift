import XCTest
@testable import Camenya

final class FinalizationPlanTests: XCTestCase {
    func testOneSegmentUsesDirectPlan() throws {
        let take = TakeManifest.fixture(segmentIndices: [0])
        let plan = try FinalizationPlan.make(for: take, in: URL(fileURLWithPath: "/take"))
        XCTAssertEqual(plan, .direct(URL(fileURLWithPath: "/take/segment-000.mov")))
    }

    func testManySegmentsUseCompositionInIndexOrder() throws {
        let take = TakeManifest.fixture(segmentIndices: [2, 0, 1])
        let plan = try FinalizationPlan.make(for: take, in: URL(fileURLWithPath: "/take"))
        XCTAssertEqual(plan, .composition([0, 1, 2].map { URL(fileURLWithPath: String(format: "/take/segment-%03d.mov", $0)) }))
    }
}

private extension TakeManifest {
    static func fixture(segmentIndices: [Int]) -> TakeManifest {
        TakeManifest(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), orientation: .portrait, status: .recording, segments: segmentIndices.map {
            Segment(index: $0, fileName: String(format: "segment-%03d.mov", $0), cameraPosition: .front, createdAt: Date(timeIntervalSince1970: TimeInterval($0)), duration: 1)
        })
    }
}
