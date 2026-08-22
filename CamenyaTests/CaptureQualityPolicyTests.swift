import XCTest
@testable import Camenya

final class CaptureQualityPolicyTests: XCTestCase {
    func testSelectsStrongestSupportedStabilizationForTalkingHeadCapture() throws {
        let candidate = CaptureFormatCandidate(
            id: CaptureFormatID("front-1080"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.standard, .cinematic, .cinematicExtendedEnhanced],
            supportsSubjectFollowing: false
        )

        let selection = try XCTUnwrap(
            CaptureQualityPolicy.selectFormat(
                from: [candidate],
                prefersSubjectFollowing: false
            )
        )

        XCTAssertEqual(selection.formatID, candidate.id)
        XCTAssertEqual(selection.stabilizationMode, .cinematicExtendedEnhanced)
    }

    func testSubjectFollowingPreferenceSelectsCompatibleFrontFormat() throws {
        let cinematicOnly = CaptureFormatCandidate(
            id: CaptureFormatID("cinematic-only"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematicExtendedEnhanced],
            supportsSubjectFollowing: false
        )
        let followsSubject = CaptureFormatCandidate(
            id: CaptureFormatID("follows-subject"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematicExtended],
            supportsSubjectFollowing: true
        )

        let selection = try XCTUnwrap(
            CaptureQualityPolicy.selectFormat(
                from: [cinematicOnly, followsSubject],
                prefersSubjectFollowing: true
            )
        )

        XCTAssertEqual(selection.formatID, followsSubject.id)
        XCTAssertEqual(selection.stabilizationMode, .cinematicExtended)
    }

    func testUnsupportedPreferredModesFallBackToStandard() throws {
        let candidate = CaptureFormatCandidate(
            id: CaptureFormatID("standard-only"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.standard],
            supportsSubjectFollowing: false
        )

        let selection = try XCTUnwrap(
            CaptureQualityPolicy.selectFormat(
                from: [candidate],
                prefersSubjectFollowing: true
            )
        )

        XCTAssertEqual(selection.stabilizationMode, .standard)
    }

    func testStrongerStabilizationOutranksNominal1080pResolution() throws {
        let fourK = CaptureFormatCandidate(
            id: CaptureFormatID("4k"),
            width: 3_840,
            height: 2_160,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematicExtendedEnhanced],
            supportsSubjectFollowing: false
        )
        let fullHD = CaptureFormatCandidate(
            id: CaptureFormatID("1080p"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematic],
            supportsSubjectFollowing: false
        )

        let selection = try XCTUnwrap(
            CaptureQualityPolicy.selectFormat(
                from: [fourK, fullHD],
                prefersSubjectFollowing: false
            )
        )

        XCTAssertEqual(selection.formatID, fourK.id)
    }

    func testPrefersExact1080pWhenStabilizationAndCapabilitiesAreEqual() throws {
        let fourK = CaptureFormatCandidate(
            id: CaptureFormatID("4k"),
            width: 3_840,
            height: 2_160,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematic],
            supportsSubjectFollowing: false
        )
        let fullHD = CaptureFormatCandidate(
            id: CaptureFormatID("1080p"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematic],
            supportsSubjectFollowing: false
        )

        let selection = try XCTUnwrap(
            CaptureQualityPolicy.selectFormat(
                from: [fourK, fullHD],
                prefersSubjectFollowing: false
            )
        )

        XCTAssertEqual(selection.formatID, fullHD.id)
    }

    func testNeverUpscalesSubFullHDWhenA1080pFormatIsAvailable() throws {
        let stabilized720p = CaptureFormatCandidate(
            id: CaptureFormatID("720p-stabilized"),
            width: 1_280,
            height: 720,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematicExtendedEnhanced],
            supportsSubjectFollowing: true
        )
        let fullHD = CaptureFormatCandidate(
            id: CaptureFormatID("1080p"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematicExtended],
            supportsSubjectFollowing: true
        )

        let selection = try XCTUnwrap(CaptureQualityPolicy.selectFormat(
            from: [stabilized720p, fullHD],
            prefersSubjectFollowing: true
        ))

        XCTAssertEqual(selection.formatID, fullHD.id)
        XCTAssertEqual(selection.stabilizationMode, .cinematicExtended)
    }

    func testExposureDragClampsBiasToDeviceRange() {
        XCTAssertEqual(
            CaptureExposurePolicy.bias(
                from: 0,
                verticalTranslation: -1_000,
                supportedRange: -2 ... 2
            ),
            2
        )
        XCTAssertEqual(
            CaptureExposurePolicy.bias(
                from: 0,
                verticalTranslation: 1_000,
                supportedRange: -2 ... 2
            ),
            -2
        )
    }

    func testExposureAccessibilityStepHasNeutralDetent() {
        XCTAssertEqual(
            CaptureExposurePolicy.incrementedBias(from: -0.2, step: 0.25, supportedRange: -2 ... 2),
            0
        )
    }

    func testExposureDragSnapsToNeutralDetent() {
        XCTAssertEqual(
            CaptureExposurePolicy.bias(
                from: 0.2,
                verticalTranslation: 15,
                supportedRange: -2 ... 2
            ),
            0
        )
    }

    func testTalkingHeadPreferencesDefaultToAutomaticEnhancements() {
        XCTAssertTrue(CaptureQualityPreferences.default.followSubjectEnabled)
        XCTAssertTrue(CaptureQualityPreferences.default.lowLightAutoEnabled)
    }

    func testCapturePreferencesPersistOutsideProjectData() throws {
        let suiteName = "CaptureQualityPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CapturePreferenceStore(defaults: defaults)

        store.save(CaptureQualityPreferences(
            followSubjectEnabled: false,
            lowLightAutoEnabled: false
        ))

        XCTAssertEqual(
            store.load(),
            CaptureQualityPreferences(
                followSubjectEnabled: false,
                lowLightAutoEnabled: false
            )
        )
    }

    func testSystemPressureSkipsUnsupportedFallbackModes() {
        XCTAssertEqual(
            CaptureQualityPolicy.fallback(
                after: .cinematicExtendedEnhanced,
                supportedModes: [.cinematicExtendedEnhanced, .standard]
            ),
            .standard
        )
    }

    func testSDRBoundaryRejectsHDRonlyFormatEvenWhenItHasStrongerStabilization() throws {
        let hdrOnly = CaptureFormatCandidate(
            id: CaptureFormatID("hdr-only"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematicExtendedEnhanced],
            supportsSubjectFollowing: false,
            supportsSDR: false
        )
        let sdr = CaptureFormatCandidate(
            id: CaptureFormatID("sdr"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematic],
            supportsSubjectFollowing: false
        )

        let selection = try XCTUnwrap(CaptureQualityPolicy.selectFormat(
            from: [hdrOnly, sdr],
            prefersSubjectFollowing: false
        ))

        XCTAssertEqual(selection.formatID, sdr.id)
    }

    func testPrefersAutomaticImageQualityCapabilitiesWhenPrimaryQualityIsEqual() throws {
        let manual = CaptureFormatCandidate(
            id: CaptureFormatID("manual"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematic],
            supportsSubjectFollowing: false,
            automaticImageQualityCapabilityCount: 0
        )
        let automatic = CaptureFormatCandidate(
            id: CaptureFormatID("automatic"),
            width: 1_920,
            height: 1_080,
            supportsThirtyFPS: true,
            supportedStabilizationModes: [.cinematic],
            supportsSubjectFollowing: false,
            automaticImageQualityCapabilityCount: 4
        )

        let selection = try XCTUnwrap(CaptureQualityPolicy.selectFormat(
            from: [manual, automatic],
            prefersSubjectFollowing: false
        ))

        XCTAssertEqual(selection.formatID, automatic.id)
    }

    func testCooperativeFollowSubjectKeepsLatestUserIntent() {
        var coordinator = FollowSubjectPreferenceCoordinator(initialPreference: true)
        coordinator.appRequested(false)

        XCTAssertNil(coordinator.receivedSystemValue(true, isSupported: true))
        XCTAssertFalse(coordinator.preference)
        XCTAssertNil(coordinator.receivedSystemValue(false, isSupported: true))
        XCTAssertEqual(coordinator.receivedSystemValue(true, isSupported: true), true)
        XCTAssertTrue(coordinator.preference)
    }
}
