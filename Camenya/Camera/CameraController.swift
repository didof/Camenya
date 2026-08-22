@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog

enum CameraControllerError: Error, LocalizedError {
    case cameraUnavailable(CameraPosition)
    case microphoneUnavailable
    case cannotAddInput
    case cannotAddOutput
    case noCompatibleSDRFormat(CameraPosition)
    case sessionNotReady
    case outputFileAlreadyExists

    var errorDescription: String? {
        switch self {
        case let .cameraUnavailable(position): "The \(position.rawValue) camera is unavailable."
        case .microphoneUnavailable: "The microphone is unavailable."
        case .cannotAddInput: "The selected capture input could not be added."
        case .cannotAddOutput: "The movie output could not be added."
        case let .noCompatibleSDRFormat(position): "The \(position.rawValue) camera has no compatible SDR recording format."
        case .sessionNotReady: "The camera is not ready."
        case .outputFileAlreadyExists: "The next recording file already exists."
        }
    }
}

enum CaptureRecordingOutputPolicy {
    static func settings(
        availableVideoCodecTypes: [AVVideoCodecType]
    ) -> [String: Any]? {
        let codec: AVVideoCodecType
        if availableVideoCodecTypes.contains(.hevc) {
            codec = .hevc
        } else if availableVideoCodecTypes.contains(.h264) {
            codec = .h264
        } else {
            return nil
        }
        return [AVVideoCodecKey: codec]
    }
}

struct CameraPermissions {
    static func requestRequiredAccess() async -> Bool {
        let camera = await request(.video)
        guard camera else { return false }
        return await request(.audio)
    }

    private static func request(_ mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { continuation.resume(returning: $0) }
            }
        default: false
        }
    }
}

/// AVFoundation objects are non-Sendable but are confined to `sessionQueue`.
/// The unchecked conformance is localized here rather than leaking unsafe annotations through the app.
final class CameraController: NSObject, @unchecked Sendable {
    private static let centerStageEnabledKeyPath = "centerStageEnabled"

    let session = AVCaptureSession()

    var onRecordingStarted: (@MainActor @Sendable () -> Void)?
    var onRecordingFinished: (@MainActor @Sendable (URL, Error?) -> Void)?
    var onInterrupted: (@MainActor @Sendable (String) -> Void)?
    var onInterruptionEnded: (@MainActor @Sendable () -> Void)?
    var onRuntimeError: (@MainActor @Sendable (Error) -> Void)?
    var onCapabilitiesChanged: (@MainActor @Sendable (CaptureCapabilities) -> Void)?

    private let logger = Logger(subsystem: "org.camenya.app", category: "Camera")
    private let sessionQueue = DispatchQueue(label: "org.camenya.app.capture-session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var systemPressureObservation: NSKeyValueObservation?
    private var lowLightObservation: NSKeyValueObservation?
    private var centerStageObservation: NSKeyValueObservation?
    private var stabilizationObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private(set) var selectedCamera: CameraPosition = .front
    private var configured = false
    private var qualityPreferences = CaptureQualityPreferences.default
    private var requestedStabilizationMode: CaptureStabilizationMode = .off
    private var supportedStabilizationModes: Set<CaptureStabilizationMode> = [.off]

    var recordedDuration: TimeInterval {
        let seconds = movieOutput.recordedDuration.seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    override init() {
        super.init()
        AVCaptureDevice.self.addObserver(
            self,
            forKeyPath: Self.centerStageEnabledKeyPath,
            options: [.initial, .new],
            context: nil
        )
        observeSession()
    }

    deinit {
        AVCaptureDevice.self.removeObserver(self, forKeyPath: Self.centerStageEnabledKeyPath)
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == Self.centerStageEnabledKeyPath else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        sessionQueue.async { self.publishCapabilities() }
    }

    func configure(
        qualityPreferences: CaptureQualityPreferences = .default,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        sessionQueue.async {
            do {
                self.qualityPreferences = qualityPreferences
                if !self.configured { try self.configureSession() }
                else { try self.applyQualityPreferencesToActiveDevice() }
                self.configurePreviewStabilization()
                if !self.session.isRunning { self.session.startRunning() }
                self.configured = true
                self.logger.info("Capture session configured with front camera")
                self.publishCapabilities()
                DispatchQueue.main.async {
                    self.refreshRotationCoordinator()
                    completion(.success(()))
                }
            } catch {
                self.logger.error("Capture configuration failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func startSession(completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        sessionQueue.async {
            guard self.configured else {
                if let completion { DispatchQueue.main.async { completion(false) } }
                return
            }
            if !self.session.isRunning { self.session.startRunning() }
            let isUsable = self.session.isRunning && !self.session.isInterrupted
            self.publishCapabilities()
            if let completion { DispatchQueue.main.async { completion(isUsable) } }
        }
    }

    func stopSession(completion: (@MainActor @Sendable () -> Void)? = nil) {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    @MainActor
    func attachPreview(to layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        refreshRotationCoordinator()
        sessionQueue.async { self.configurePreviewStabilization() }
    }

    @MainActor
    func frozenCaptureRotationAngle() -> CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
    }

    func switchCamera(completion: @escaping @MainActor @Sendable (Result<CameraPosition, Error>) -> Void) {
        sessionQueue.async {
            let previousInput = self.videoInput
            let target = self.selectedCamera.toggled
            do {
                let newInput = try self.makeVideoInput(position: target)
                self.session.beginConfiguration()
                if let previousInput { self.session.removeInput(previousInput) }
                guard self.session.canAddInput(newInput) else {
                    if let previousInput, self.session.canAddInput(previousInput) { self.session.addInput(previousInput) }
                    self.session.commitConfiguration()
                    throw CameraControllerError.cannotAddInput
                }
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.selectedCamera = target
                self.observeSystemPressure(on: newInput.device)
                self.observeQualityState(on: newInput.device)
                self.configureRecordingStabilization()
                self.session.commitConfiguration()
                self.configurePreviewStabilization()
                self.logger.info("Selected \(target.rawValue, privacy: .public) camera")
                self.publishCapabilities()
                DispatchQueue.main.async {
                    self.refreshRotationCoordinator()
                    completion(.success(target))
                }
            } catch {
                self.logger.error("Camera switch failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func startRecording(to url: URL, rotationAngle: CGFloat) {
        sessionQueue.async {
            guard self.configured, self.session.isRunning, !self.movieOutput.isRecording else {
                DispatchQueue.main.async { self.onRecordingFinished?(url, CameraControllerError.sessionNotReady) }
                return
            }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async { self.onRecordingFinished?(url, CameraControllerError.outputFileAlreadyExists) }
                return
            }
            guard let connection = self.movieOutput.connection(with: .video) else {
                DispatchQueue.main.async { self.onRecordingFinished?(url, CameraControllerError.sessionNotReady) }
                return
            }
            self.applyRequestedStabilization(to: connection)
            if connection.isVideoRotationAngleSupported(rotationAngle) { connection.videoRotationAngle = rotationAngle }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            if let settings = CaptureRecordingOutputPolicy.settings(
                availableVideoCodecTypes: self.movieOutput.availableVideoCodecTypes
            ) {
                self.movieOutput.setOutputSettings(settings, for: connection)
            }
            self.logger.info("Starting segment at \(url.lastPathComponent, privacy: .public)")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async {
            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    func setQualityPreferences(_ preferences: CaptureQualityPreferences) {
        sessionQueue.async {
            self.qualityPreferences = preferences
            do {
                try self.applyQualityPreferencesToActiveDevice()
                self.publishCapabilities()
            } catch {
                self.logger.warning("Capture preference update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func focusAndExpose(atPreviewPoint previewPoint: CGPoint) {
        guard let previewLayer else { return }
        let layerPoint = CGPoint(
            x: previewPoint.x * previewLayer.bounds.width,
            y: previewPoint.y * previewLayer.bounds.height
        )
        focusAndExpose(atDevicePoint: previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
    }

    private func focusAndExpose(atDevicePoint devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .continuousAutoExposure
                }
            } catch {
                self.logger.warning("Point focus and exposure failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setExposureBias(_ bias: Float) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped) { [weak self] _ in
                    self?.sessionQueue.async { self?.publishCapabilities() }
                }
                device.unlockForConfiguration()
            } catch {
                self.logger.warning("Exposure bias update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }

        let videoInput = try makeVideoInput(position: .front)
        guard session.canAddInput(videoInput) else { throw CameraControllerError.cannotAddInput }
        session.addInput(videoInput)
        self.videoInput = videoInput
        observeSystemPressure(on: videoInput.device)

        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw CameraControllerError.microphoneUnavailable }
        let audioInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(audioInput) else { throw CameraControllerError.cannotAddInput }
        session.addInput(audioInput)
        self.audioInput = audioInput

        guard session.canAddOutput(movieOutput) else { throw CameraControllerError.cannotAddOutput }
        session.addOutput(movieOutput)
        movieOutput.movieFragmentInterval = .invalid
        configureRecordingStabilization()
        observeQualityState(on: videoInput.device)
    }

    private func makeVideoInput(position: CameraPosition) throws -> AVCaptureDeviceInput {
        let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        let deviceTypes: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInUltraWideCamera, .builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: avPosition
        ).devices
        guard !devices.isEmpty else {
            throw CameraControllerError.cameraUnavailable(position)
        }

        let options = formatOptions(for: devices)
        guard let selection = CaptureQualityPolicy.selectFormat(
            from: options.map(\.candidate),
            prefersSubjectFollowing: position == .front
        ), let option = options.first(where: { $0.candidate.id == selection.formatID }) else {
            throw CameraControllerError.noCompatibleSDRFormat(position)
        }

        requestedStabilizationMode = selection.stabilizationMode
        supportedStabilizationModes = option.candidate.supportedStabilizationModes.union([.off])
        try configureDevice(option, position: position)
        return try AVCaptureDeviceInput(device: option.device)
    }

    private struct DeviceFormatOption {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
        let candidate: CaptureFormatCandidate
    }

    private func formatOptions(for devices: [AVCaptureDevice]) -> [DeviceFormatOption] {
        devices.enumerated().flatMap { deviceIndex, device in
            device.formats.enumerated().map { formatIndex, format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let supportsThirtyFPS = format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                }
                let modes = Set(CaptureStabilizationMode.allCases.filter { mode in
                    guard let avMode = avStabilizationMode(for: mode) else { return false }
                    return format.isVideoStabilizationModeSupported(avMode)
                })
                let centerStageFrameRateSupportsThirty = format.videoFrameRateRangeForCenterStage.map {
                    $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                } ?? true
                return DeviceFormatOption(
                    device: device,
                    format: format,
                    candidate: CaptureFormatCandidate(
                        id: CaptureFormatID("\(deviceIndex)-\(formatIndex)"),
                        width: dimensions.width,
                        height: dimensions.height,
                        supportsThirtyFPS: supportsThirtyFPS,
                        supportedStabilizationModes: modes,
                        supportsSubjectFollowing: format.isCenterStageSupported && centerStageFrameRateSupportsThirty,
                        supportsSDR: format.supportedColorSpaces.contains(.sRGB),
                        automaticImageQualityCapabilityCount: automaticImageQualityCapabilityCount(
                            for: device,
                            format: format
                        )
                    )
                )
            }
        }
    }

    private func automaticImageQualityCapabilityCount(
        for device: AVCaptureDevice,
        format: AVCaptureDevice.Format
    ) -> Int {
        let formatSupportsDistortionCorrection = abs(
            format.geometricDistortionCorrectedVideoFieldOfView - format.videoFieldOfView
        ) > 0.01
        return [
            device.isFocusModeSupported(.continuousAutoFocus),
            device.isExposureModeSupported(.continuousAutoExposure),
            device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
            formatSupportsDistortionCorrection
        ].filter { $0 }.count
    }

    private func configureDevice(
        _ option: DeviceFormatOption,
        position: CameraPosition
    ) throws {
        let device = option.device
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = option.format
        device.activeColorSpace = .sRGB
        let duration = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        configureAutomaticImageQualityLocked(on: device, position: position)
    }

    private func configureAutomaticImageQualityLocked(
        on device: AVCaptureDevice,
        position: CameraPosition
    ) {
        if device.activeFormat.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = true
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = true
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isGeometricDistortionCorrectionSupported {
            device.isGeometricDistortionCorrectionEnabled = true
        }
        device.automaticallyAdjustsVideoHDREnabled = false
        device.isVideoHDREnabled = false
        device.isGlobalToneMappingEnabled = false
        device.setExposureTargetBias(0)
        applyQualityPreferencesLocked(
            on: device,
            position: position,
            acceptCurrentSystemSubjectPreference: configured && selectedCamera == .rear
        )
        verifyAutomaticImageQualityLocked(on: device)
    }

    private func applyQualityPreferencesToActiveDevice() throws {
        guard let device = videoInput?.device else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        applyQualityPreferencesLocked(
            on: device,
            position: selectedCamera,
            acceptCurrentSystemSubjectPreference: false
        )
    }

    private func applyQualityPreferencesLocked(
        on device: AVCaptureDevice,
        position: CameraPosition,
        acceptCurrentSystemSubjectPreference: Bool
    ) {
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = qualityPreferences.lowLightAutoEnabled
        }
        AVCaptureDevice.centerStageControlMode = .cooperative
        if position == .front, device.activeFormat.isCenterStageSupported {
            if acceptCurrentSystemSubjectPreference {
                qualityPreferences.followSubjectEnabled = AVCaptureDevice.isCenterStageEnabled
            } else {
                AVCaptureDevice.isCenterStageEnabled = qualityPreferences.followSubjectEnabled
            }
        }
    }

    private func verifyAutomaticImageQualityLocked(on device: AVCaptureDevice) {
        let focusApplied = !device.isFocusModeSupported(.continuousAutoFocus)
            || (device.focusMode == .continuousAutoFocus
                && device.automaticallyAdjustsFaceDrivenAutoFocusEnabled)
        let exposureApplied = !device.isExposureModeSupported(.continuousAutoExposure)
            || (device.exposureMode == .continuousAutoExposure
                && device.automaticallyAdjustsFaceDrivenAutoExposureEnabled)
        let whiteBalanceApplied = !device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
            || device.whiteBalanceMode == .continuousAutoWhiteBalance
        let distortionCorrectionApplied = !device.isGeometricDistortionCorrectionSupported
            || device.isGeometricDistortionCorrectionEnabled

        guard focusApplied,
              exposureApplied,
              whiteBalanceApplied,
              distortionCorrectionApplied else {
            logger.warning("Automatic talking-head image quality could not be fully applied")
            return
        }
        logger.info("Automatic talking-head image quality verified")
    }

    private func configureRecordingStabilization() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        applyRequestedStabilization(to: connection)
        stabilizationObservation = connection.observe(
            \.activeVideoStabilizationMode,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            self?.sessionQueue.async { self?.publishCapabilities() }
        }
    }

    private func configurePreviewStabilization() {
        guard let device = videoInput?.device,
              let connection = previewLayer?.connection else { return }
        if device.activeFormat.isVideoStabilizationModeSupported(.previewOptimized) {
            connection.preferredVideoStabilizationMode = .previewOptimized
        }
    }

    private func applyRequestedStabilization(to connection: AVCaptureConnection) {
        guard let mode = avStabilizationMode(for: requestedStabilizationMode),
              connection.isVideoStabilizationSupported else { return }
        connection.preferredVideoStabilizationMode = mode
    }

    private func avStabilizationMode(
        for mode: CaptureStabilizationMode
    ) -> AVCaptureVideoStabilizationMode? {
        switch mode {
        case .off: .off
        case .standard: .standard
        case .cinematic: .cinematic
        case .cinematicExtended: .cinematicExtended
        case .cinematicExtendedEnhanced: .cinematicExtendedEnhanced
        }
    }

    private func captureStabilizationMode(
        for mode: AVCaptureVideoStabilizationMode
    ) -> CaptureStabilizationMode {
        switch mode {
        case .standard: .standard
        case .cinematic: .cinematic
        case .cinematicExtended: .cinematicExtended
        case .cinematicExtendedEnhanced: .cinematicExtendedEnhanced
        default: .off
        }
    }

    private func observeQualityState(on device: AVCaptureDevice) {
        lowLightObservation = device.observe(
            \.isLowLightBoostEnabled,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            self?.sessionQueue.async { self?.publishCapabilities() }
        }
        centerStageObservation = device.observe(
            \.isCenterStageActive,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            self?.sessionQueue.async { self?.publishCapabilities() }
        }
    }

    private func publishCapabilities() {
        guard let device = videoInput?.device else { return }
        let connection = movieOutput.connection(with: .video)
        let supportsSubjectFollowing = selectedCamera == .front && device.activeFormat.isCenterStageSupported
        let capabilities = CaptureCapabilities(
            supportsSubjectFollowing: supportsSubjectFollowing,
            isSubjectFollowingEnabled: supportsSubjectFollowing && AVCaptureDevice.isCenterStageEnabled,
            supportsLowLightBoost: device.isLowLightBoostSupported,
            isLowLightBoostActive: device.isLowLightBoostEnabled,
            activeStabilizationMode: connection.map {
                captureStabilizationMode(for: $0.activeVideoStabilizationMode)
            } ?? .off,
            minimumExposureBias: device.minExposureTargetBias,
            maximumExposureBias: device.maxExposureTargetBias,
            exposureBias: device.exposureTargetBias
        )
        logger.info("Capture quality active; stabilization mode \(capabilities.activeStabilizationMode.rawValue, privacy: .public)")
        DispatchQueue.main.async { self.onCapabilitiesChanged?(capabilities) }
    }

    @MainActor
    private func refreshRotationCoordinator() {
        guard let device = videoInput?.device else { return }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        previewRotationObservation = rotationCoordinator?.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let self else { return }
            let angle = change.newValue ?? 0
            let mirrored = self.selectedCamera == .front
            self.applyPreviewRotation(angle: angle, mirrored: mirrored)
        }
    }

    private func applyPreviewRotation(angle: CGFloat, mirrored: Bool) {
        sessionQueue.async {
            guard let connection = self.previewLayer?.connection else { return }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = mirrored }
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.stringValue ?? "unknown"
            DispatchQueue.main.async { self?.onInterrupted?(reason) }
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.onInterruptionEnded?() }
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error else { return }
            DispatchQueue.main.async { self?.onRuntimeError?(error) }
        })
    }

    private func observeSystemPressure(on device: AVCaptureDevice) {
        systemPressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] _, change in
            guard let self, let state = change.newValue else { return }
            switch state.level {
            case .serious, .critical:
                self.sessionQueue.async { self.reduceQualityForSystemPressure() }
            case .shutdown:
                DispatchQueue.main.async {
                    self.onInterrupted?("Serious system pressure (\(state.level.rawValue))")
                }
            default:
                break
            }
        }
    }

    private func reduceQualityForSystemPressure() {
        let fallback = CaptureQualityPolicy.fallback(
            after: requestedStabilizationMode,
            supportedModes: supportedStabilizationModes
        )
        guard fallback != requestedStabilizationMode else { return }
        requestedStabilizationMode = fallback
        configureRecordingStabilization()
        logger.warning("Reduced stabilization to preserve capture continuity under system pressure")
        publishCapabilities()
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        logger.info("Segment recording confirmed")
        DispatchQueue.main.async { self.onRecordingStarted?() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        logger.info("Segment finished at \(outputFileURL.lastPathComponent, privacy: .public)")
        let effectiveError: Error?
        if let cocoaError = error as NSError?, cocoaError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true {
            effectiveError = nil
        } else {
            effectiveError = error
        }
        DispatchQueue.main.async { self.onRecordingFinished?(outputFileURL, effectiveError) }
    }
}
