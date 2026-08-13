import XCTest
@testable import Camenya

final class AppErrorSettingsPolicyTests: XCTestCase {
    func testInvalidCaptionRangeDoesNotOfferSettings() {
        XCTAssertFalse(AppErrorSettingsPolicy.allowsOpeningSettings(
            for: CaptionTranscriptionError.invalidSourceRange.localizedDescription
        ))
    }

    func testPermissionFailuresOfferSettings() {
        XCTAssertTrue(AppErrorSettingsPolicy.allowsOpeningSettings(
            for: "Camera and microphone access are required before recording."
        ))
        XCTAssertTrue(AppErrorSettingsPolicy.allowsOpeningSettings(
            for: CaptionTranscriptionError.unavailable(.authorizationDenied).localizedDescription
        ))
    }
}
