@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog

enum CameraControllerError: Error, LocalizedError {
    case cameraUnavailable(CameraPosition)
    case microphoneUnavailable
    case cannotAddInput
    case cannotAddOutput
    case sessionNotReady
    case outputFileAlreadyExists

    var errorDescription: String? {
        switch self {
        case let .cameraUnavailable(position): "The \(position.rawValue) camera is unavailable."
        case .microphoneUnavailable: "The microphone is unavailable."
        case .cannotAddInput: "The selected capture input could not be added."
        case .cannotAddOutput: "The movie output could not be added."
        case .sessionNotReady: "The camera is not ready."
        case .outputFileAlreadyExists: "The next recording file already exists."
        }
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
    let session = AVCaptureSession()

    var onRecordingStarted: (@MainActor @Sendable () -> Void)?
    var onRecordingFinished: (@MainActor @Sendable (URL, Error?) -> Void)?
    var onInterrupted: (@MainActor @Sendable (String) -> Void)?
    var onInterruptionEnded: (@MainActor @Sendable () -> Void)?
    var onRuntimeError: (@MainActor @Sendable (Error) -> Void)?

    private let logger = Logger(subsystem: "org.camenya.app", category: "Camera")
    private let sessionQueue = DispatchQueue(label: "org.camenya.app.capture-session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var systemPressureObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private(set) var selectedCamera: CameraPosition = .front
    private var configured = false

    var recordedDuration: TimeInterval {
        let seconds = movieOutput.recordedDuration.seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    override init() {
        super.init()
        observeSession()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func configure(completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        sessionQueue.async {
            do {
                if !self.configured { try self.configureSession() }
                if !self.session.isRunning { self.session.startRunning() }
                self.configured = true
                self.logger.info("Capture session configured with front camera")
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
                self.session.commitConfiguration()
                self.logger.info("Selected \(target.rawValue, privacy: .public) camera")
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
            if connection.isVideoRotationAngleSupported(rotationAngle) { connection.videoRotationAngle = rotationAngle }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            if self.movieOutput.availableVideoCodecTypes.contains(.h264) {
                self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
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

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
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
    }

    private func makeVideoInput(position: CameraPosition) throws -> AVCaptureDeviceInput {
        let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition) else {
            throw CameraControllerError.cameraUnavailable(position)
        }
        try configureThirtyFPS(device)
        return try AVCaptureDeviceInput(device: device)
    }

    private func configureThirtyFPS(_ device: AVCaptureDevice) throws {
        let target = device.formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == 1920 && dimensions.height == 1080 &&
                format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        guard let target else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = target
        let duration = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
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
            case .serious, .critical, .shutdown:
                DispatchQueue.main.async {
                    self.onInterrupted?("Serious system pressure (\(state.level.rawValue))")
                }
            default:
                break
            }
        }
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
