import Foundation

struct CaptureQualityPreferences: Equatable, Sendable {
    var followSubjectEnabled: Bool
    var lowLightAutoEnabled: Bool

    static let `default` = CaptureQualityPreferences(
        followSubjectEnabled: true,
        lowLightAutoEnabled: true
    )
}

struct CapturePreferenceStore {
    private enum Key {
        static let followSubject = "capture.follow-subject"
        static let lowLightAuto = "capture.low-light-auto"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CaptureQualityPreferences {
        CaptureQualityPreferences(
            followSubjectEnabled: defaults.object(forKey: Key.followSubject) as? Bool
                ?? CaptureQualityPreferences.default.followSubjectEnabled,
            lowLightAutoEnabled: defaults.object(forKey: Key.lowLightAuto) as? Bool
                ?? CaptureQualityPreferences.default.lowLightAutoEnabled
        )
    }

    func save(_ preferences: CaptureQualityPreferences) {
        defaults.set(preferences.followSubjectEnabled, forKey: Key.followSubject)
        defaults.set(preferences.lowLightAutoEnabled, forKey: Key.lowLightAuto)
    }
}

enum CaptureStabilizationMode: Int, CaseIterable, Hashable, Sendable {
    case off
    case standard
    case cinematic
    case cinematicExtended
    case cinematicExtendedEnhanced
}

struct CaptureCapabilities: Equatable, Sendable {
    var supportsSubjectFollowing: Bool
    var isSubjectFollowingEnabled: Bool
    var supportsLowLightBoost: Bool
    var isLowLightBoostActive: Bool
    var activeStabilizationMode: CaptureStabilizationMode
    var minimumExposureBias: Float
    var maximumExposureBias: Float
    var exposureBias: Float

    var exposureBiasRange: ClosedRange<Float> {
        minimumExposureBias ... maximumExposureBias
    }

    static let unavailable = CaptureCapabilities(
        supportsSubjectFollowing: false,
        isSubjectFollowingEnabled: false,
        supportsLowLightBoost: false,
        isLowLightBoostActive: false,
        activeStabilizationMode: .off,
        minimumExposureBias: 0,
        maximumExposureBias: 0,
        exposureBias: 0
    )
}

struct CaptureFormatID: Equatable, Hashable, Comparable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static func < (lhs: CaptureFormatID, rhs: CaptureFormatID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct CaptureFormatCandidate: Equatable, Sendable {
    let id: CaptureFormatID
    let width: Int32
    let height: Int32
    let supportsThirtyFPS: Bool
    let supportedStabilizationModes: Set<CaptureStabilizationMode>
    let supportsSubjectFollowing: Bool
    let supportsSDR: Bool
    let automaticImageQualityCapabilityCount: Int

    init(
        id: CaptureFormatID,
        width: Int32,
        height: Int32,
        supportsThirtyFPS: Bool,
        supportedStabilizationModes: Set<CaptureStabilizationMode>,
        supportsSubjectFollowing: Bool,
        supportsSDR: Bool = true,
        automaticImageQualityCapabilityCount: Int = 0
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.supportsThirtyFPS = supportsThirtyFPS
        self.supportedStabilizationModes = supportedStabilizationModes
        self.supportsSubjectFollowing = supportsSubjectFollowing
        self.supportsSDR = supportsSDR
        self.automaticImageQualityCapabilityCount = automaticImageQualityCapabilityCount
    }

    var strongestStabilizationMode: CaptureStabilizationMode {
        supportedStabilizationModes.max(by: { $0.rawValue < $1.rawValue }) ?? .off
    }

    var isFullHD: Bool {
        max(width, height) == 1_920 && min(width, height) == 1_080
    }

    var isFullHDOrBetter: Bool {
        max(width, height) >= 1_920 && min(width, height) >= 1_080
    }
}

struct CaptureQualitySelection: Equatable, Sendable {
    let formatID: CaptureFormatID
    let stabilizationMode: CaptureStabilizationMode
}

enum CaptureQualityPolicy {
    static func fallback(
        after mode: CaptureStabilizationMode,
        supportedModes: Set<CaptureStabilizationMode>
    ) -> CaptureStabilizationMode {
        supportedModes
            .filter { $0.rawValue < mode.rawValue }
            .max(by: { $0.rawValue < $1.rawValue })
            ?? .off
    }

    static func selectFormat(
        from candidates: [CaptureFormatCandidate],
        prefersSubjectFollowing: Bool
    ) -> CaptureQualitySelection? {
        let thirtyFPS = candidates.filter { $0.supportsThirtyFPS && $0.supportsSDR }
        guard !thirtyFPS.isEmpty else { return nil }

        let fullHDOrBetter = thirtyFPS.filter(\.isFullHDOrBetter)
        let resolutionPool = fullHDOrBetter.isEmpty ? thirtyFPS : fullHDOrBetter

        let subjectFollowing = resolutionPool.filter(\.supportsSubjectFollowing)
        let capabilityPool = prefersSubjectFollowing && !subjectFollowing.isEmpty
            ? subjectFollowing
            : resolutionPool

        guard let selected = capabilityPool.sorted(by: isPreferred).first else { return nil }
        return CaptureQualitySelection(
            formatID: selected.id,
            stabilizationMode: selected.strongestStabilizationMode
        )
    }

    private static func isPreferred(
        _ lhs: CaptureFormatCandidate,
        _ rhs: CaptureFormatCandidate
    ) -> Bool {
        if lhs.strongestStabilizationMode != rhs.strongestStabilizationMode {
            return lhs.strongestStabilizationMode.rawValue > rhs.strongestStabilizationMode.rawValue
        }
        if lhs.automaticImageQualityCapabilityCount != rhs.automaticImageQualityCapabilityCount {
            return lhs.automaticImageQualityCapabilityCount > rhs.automaticImageQualityCapabilityCount
        }
        if lhs.isFullHD != rhs.isFullHD {
            return lhs.isFullHD
        }
        if lhs.supportsSubjectFollowing != rhs.supportsSubjectFollowing {
            return lhs.supportsSubjectFollowing
        }
        return lhs.id < rhs.id
    }
}

enum CaptureExposurePolicy {
    private static let neutralDetentRadius: Float = 0.1

    static func bias(
        from initialBias: Float,
        verticalTranslation: Double,
        supportedRange: ClosedRange<Float>
    ) -> Float {
        let proposed = initialBias - Float(verticalTranslation * 0.01)
        return normalized(proposed, supportedRange: supportedRange)
    }

    static func incrementedBias(
        from currentBias: Float,
        step: Float,
        supportedRange: ClosedRange<Float>
    ) -> Float {
        let proposed = currentBias + step
        if currentBias < 0, proposed > 0 { return 0 }
        if currentBias > 0, proposed < 0 { return 0 }
        return normalized(proposed, supportedRange: supportedRange)
    }

    private static func normalized(
        _ proposed: Float,
        supportedRange: ClosedRange<Float>
    ) -> Float {
        if abs(proposed) <= neutralDetentRadius { return 0 }
        return min(max(proposed, supportedRange.lowerBound), supportedRange.upperBound)
    }
}

struct FollowSubjectPreferenceCoordinator: Equatable, Sendable {
    private(set) var preference: Bool
    private var appUpdatePending = false

    init(initialPreference: Bool) {
        preference = initialPreference
    }

    mutating func appRequested(_ enabled: Bool) {
        preference = enabled
        appUpdatePending = true
    }

    mutating func receivedSystemValue(_ enabled: Bool, isSupported: Bool) -> Bool? {
        guard isSupported else { return nil }
        if appUpdatePending {
            if enabled == preference { appUpdatePending = false }
            return nil
        }
        guard enabled != preference else { return nil }
        preference = enabled
        return enabled
    }
}
