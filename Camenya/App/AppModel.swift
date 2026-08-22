import AVFoundation
import Foundation
import OSLog
import SwiftUI

struct ShareableProjectExport: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

enum ProjectExportVariantEligibility {
    static func canExportWithCaptions(
        project: ProjectManifest,
        snapshot: ExportSnapshot
    ) -> Bool {
        project.projectCaptionTrack?.reviewState == .approved
            && project.projectCaptionTrack?.isGenerationComplete == true
            && snapshot.captionTimeline != nil
    }
}

struct FinishVideoDependencies: Sendable {
    let export: (@Sendable (ProjectExportPlan, URL) async throws -> URL)?
    let validate: @Sendable (URL, Bool) async throws -> TimeInterval
    let saveToPhotos: @Sendable (URL) async throws -> Void
    let commitPictureLock: @Sendable (
        ProjectStore,
        UUID,
        StorylineRevision
    ) async throws -> ProjectManifest

    init(
        export: (@Sendable (ProjectExportPlan, URL) async throws -> URL)? = nil,
        validate: @escaping @Sendable (URL, Bool) async throws -> TimeInterval = { url, requiresAudio in
            try await ProjectExportValidator().validate(url, requiresAudio: requiresAudio)
        },
        saveToPhotos: @escaping @Sendable (URL) async throws -> Void = { url in
            try await PhotoLibrarySaver().saveVideo(at: url)
        },
        commitPictureLock: @escaping @Sendable (
            ProjectStore,
            UUID,
            StorylineRevision
        ) async throws -> ProjectManifest = { store, projectID, revision in
            try store.commitPictureLockAfterCleanMaster(
                projectID: projectID,
                expectedRevision: revision
            )
        }
    ) {
        self.export = export
        self.validate = validate
        self.saveToPhotos = saveToPhotos
        self.commitPictureLock = commitPictureLock
    }

    static let live = FinishVideoDependencies()
}

import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var project: ProjectManifest {
        didSet {
            refreshExportSnapshot()
            refreshProjectCaptionWaveform()
        }
    }
    @Published private(set) var exportSnapshot: ExportSnapshot?
    @Published private(set) var phase: RecorderPhase = .configuring
    @Published private(set) var selectedCamera: CameraPosition = .front
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published private(set) var recoverableTakes: [TakeManifest] = []
    @Published private(set) var isInterrupted = false
    @Published private(set) var cameraOperationalState: CameraOperationalState = .configuring
    @Published private(set) var captureCapabilities: CaptureCapabilities = .unavailable
    @Published private(set) var captureQualityPreferences: CaptureQualityPreferences
    @Published private(set) var isExportingProject = false
    @Published private(set) var projectExportCanCancel = false
    @Published private(set) var isEditingTimeline = false
    @Published private(set) var projectExportStatus: String?
    @Published private(set) var completedTakeForReview: ProjectTake?
    @Published private(set) var projectExportProgress: Double = 0
    @Published private(set) var shareableProjectExport: ShareableProjectExport?
    @Published private(set) var projectExportErrorMessage: String?
    @Published private(set) var cleanMasterPhotosSaveNeedsResolution = false
    @Published private(set) var isAnalyzingTrim = false
    @Published private(set) var trimAnalysisProgress: Double = 0
    @Published private(set) var trimAnalysisStatus: String?
    @Published private(set) var trimAnalysisSummary: String?
    @Published private(set) var trimReviewTakeIDs: [UUID] = []
    @Published private var trimWaveformCache: [UUID: [Float]] = [:]
    @Published private var trimWaveformLoadingTakeIDs: Set<UUID> = []
    @Published private var trimWaveformErrors: [UUID: String] = [:]
    @Published private(set) var isTranscribingCaptions = false
    @Published private(set) var captionTranscriptionProgress: Double = 0
    @Published private(set) var captionTranscriptionStatus: String?
    @Published private(set) var captionGenerationErrorMessage: String?
    @Published private(set) var projectCaptionWaveform: [Float] = []
    @Published private(set) var canRetryProjectNoteSave = false
    @Published private(set) var projectNoteSaveErrorMessage: String?
    @Published private(set) var isCapturePermissionDenied = false

    let cameraController = CameraController()
    let projectNote: ProjectNoteStore

    var captureReady: Bool { cameraOperationalState.isReady }
    var isRestoringCaptureSession: Bool { cameraOperationalState.isRestoring }
    var cameraRecoveryMessage: String? { cameraOperationalState.recoveryMessage }
    var hasFailedProjectExportRetry: Bool { failedProjectExportAction != nil }

    private var workspaceMediaOperationsAreAvailable: Bool {
        phase == .idle || (phase == .configuring && !configurationStarted)
    }

    private let logger = Logger(subsystem: "org.camenya.app", category: "AppModel")
    private let projectStore: ProjectStore
    private let store: TakeManifestStore
    private let timelineEditor: TimelineEditor
    private let finalizer = TakeFinalizer()
    private let validator = SegmentValidator()
    private let projectExporter = ProjectExporter()
    private let thumbnailGenerator = TakeThumbnailGenerator()
    private let trimAnalyzer = TakeTrimAnalyzer()
    private let captionTranscriber: CaptionTranscriber
    private let onProjectChanged: @MainActor (ProjectManifest) -> Void
    private let capturePreferenceStore: CapturePreferenceStore
    private let trimAnalysisProvider: @Sendable (URL) async throws -> TakeTrimAnalysisOutput
    private let finishVideoDependencies: FinishVideoDependencies
    private var machine = RecorderStateMachine()
    private var cameraLifecyclePolicy = CameraLifecyclePolicy()
    private var logicalTimer = LogicalRecordingTimer()
    private var currentTake: TakeManifest?
    private var finalMovieURL: URL?
    private var frozenRotationAngle: CGFloat = 90
    private var activeSegmentIndex: Int?
    private var activeSegmentCamera: CameraPosition?
    private var timer: Timer?
    private var pendingInterruption = false
    private var configurationStarted = false
    private var cameraConfigurationCompleted = false
    private var currentScenePhase: ScenePhase = .active
    private var followSubjectPreferenceCoordinator: FollowSubjectPreferenceCoordinator
    private var projectExportTask: Task<Void, Never>?
    private var projectExportProgressTimer: Timer?
    private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]
    private var trimAnalysisTask: Task<Void, Never>?
    private var captionTranscriptionTask: Task<Void, Never>?
    private var exportSnapshotTask: Task<Void, Never>?
    private var projectCaptionWaveformTask: Task<Void, Never>?
    private var exportSnapshotRequestID = 0
    private var projectCaptionWaveformRequestID = 0
    private var projectCaptionGenerationID = 0
    private var timelineEditActivity = TimelineEditActivity()
    private var failedProjectExportAction: FailedProjectExportAction?

    private enum FailedProjectExportAction {
        case finishVideo
        case encode(includeCaptions: Bool)
        case finalizeStagedFile(URL, includeCaptions: Bool)
        case sharePendingFile
    }

    init(
        project: ProjectManifest,
        projectStore: ProjectStore,
        capturePreferenceStore: CapturePreferenceStore = CapturePreferenceStore(),
        trimAnalysisProvider: @escaping @Sendable (URL) async throws -> TakeTrimAnalysisOutput = { url in
            try await TakeTrimAnalyzer().analyze(movieAt: url)
        },
        finishVideoDependencies: FinishVideoDependencies = .live,
        captionTranscriber: CaptionTranscriber = CaptionTranscriber(
            recognizer: CaptionRecognizerFactory.make()
        ),
        onProjectChanged: @escaping @MainActor (ProjectManifest) -> Void = { _ in }
    ) {
        let captureQualityPreferences = capturePreferenceStore.load()
        self.project = project
        self.exportSnapshot = nil
        self.projectStore = projectStore
        self.capturePreferenceStore = capturePreferenceStore
        self.trimAnalysisProvider = trimAnalysisProvider
        self.finishVideoDependencies = finishVideoDependencies
        self.captionTranscriber = captionTranscriber
        self.captureQualityPreferences = captureQualityPreferences
        self.followSubjectPreferenceCoordinator = FollowSubjectPreferenceCoordinator(
            initialPreference: captureQualityPreferences.followSubjectEnabled
        )
        self.store = projectStore.takeManifestStore(projectID: project.id)
        self.timelineEditor = TimelineEditor(projectID: project.id, projectStore: projectStore)
        self.onProjectChanged = onProjectChanged
        self.projectNote = ProjectNoteStore(text: project.note)
        self.trimReviewTakeIDs = project.takes.compactMap { take in
            guard take.trimDecision == nil else { return nil }
            switch take.trimAnalysis {
            case .suggestion, .noSuggestion:
                let envelope = try? projectStore.trimEnvelope(projectID: project.id, takeID: take.id)
                return envelope?.isEmpty == false ? take.id : nil
            case .failed, nil:
                return nil
            }
        }
        let projectID = project.id
        cameraController.onRecordingStarted = { [weak self] in self?.recordingDidStart() }
        cameraController.onRecordingFinished = { [weak self] url, error in self?.recordingDidFinish(url: url, error: error) }
        cameraController.onInterrupted = { [weak self] reason in self?.handleCaptureInterruption(reason: reason) }
        cameraController.onInterruptionEnded = { [weak self] in self?.captureInterruptionDidEnd() }
        cameraController.onRuntimeError = { [weak self] error in self?.handleRuntimeError(error) }
        cameraController.onCapabilitiesChanged = { [weak self] capabilities in
            self?.captureCapabilitiesDidChange(capabilities)
        }
        projectNote.setOnChange { [weak self] text in
            self?.persistProjectNote(text, projectID: projectID)
        }
        refreshExportSnapshot()
        refreshProjectCaptionWaveform()
        if let staged = projectStore.recoverableStagedExport(projectID: project.id) {
            projectExportErrorMessage = staged.isCommitted
                ? "A finished video is safe in this Project. Retry sharing it."
                : "A finished video is safe in this Project. Retry finalizing it."
            failedProjectExportAction = staged.isCommitted
                ? .sharePendingFile
                : .finalizeStagedFile(
                    staged.url,
                    includeCaptions: staged.includeCaptions
                )
        } else if projectStore.pendingExportNeedsHandoff(projectID: project.id) {
            projectExportErrorMessage = "A finished video is safe in this Project. Retry sharing it."
            failedProjectExportAction = .sharePendingFile
        } else if let cleanMaster = projectStore.recoverableCleanMaster(projectID: project.id) {
            if cleanMaster.photosSaveStartedAt != nil, cleanMaster.savedToPhotosAt == nil {
                presentAmbiguousCleanMasterPhotosSave()
            } else {
                projectExportErrorMessage = "The Clean Master is safe in this Project. Retry Finish Video."
                failedProjectExportAction = .finishVideo
            }
        }
    }

    func configure() {
        guard !configurationStarted else { return }
        configurationStarted = true
        recoverableTakes = projectStore.unfinishedTakes(projectID: project.id)
        Task {
            guard await CameraPermissions.requestRequiredAccess() else {
                self.configurationStarted = false
                self.isCapturePermissionDenied = true
                machine = RecorderStateMachine(initialPhase: .idle)
                publishPhase()
                cameraOperationalState = .unavailable("Camera and microphone access are required.")
                return
            }
            self.isCapturePermissionDenied = false
            cameraController.configure(qualityPreferences: captureQualityPreferences) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    do {
                        self.cameraConfigurationCompleted = true
                        if self.currentScenePhase == .active {
                            let attempt = self.cameraLifecyclePolicy.applicationBecameActive()
                            _ = self.cameraLifecyclePolicy.restorationCompleted(attempt, isUsable: true)
                            self.cameraOperationalState = .ready
                        } else {
                            self.cameraOperationalState = .suspended
                            self.cameraController.stopSession()
                        }
                        try self.machine.apply(.sessionConfigured)
                        self.publishPhase()
                    } catch {
                        self.logger.error("Session transition failed: \(error.localizedDescription, privacy: .public)")
                        self.fail("The camera could not be prepared.")
                    }
                case let .failure(error):
                    self.logger.error("Camera configuration failed: \(error.localizedDescription, privacy: .public)")
                    self.configurationStarted = false
                    self.machine = RecorderStateMachine(initialPhase: .idle)
                    self.publishPhase()
                    self.presentPersistentCameraFailure("Camera is unavailable.")
                }
            }
        }
    }

    func enterCapture() {
        guard project.pictureLock == nil else {
            errorMessage = "Unlock the video before recording a new Take."
            return
        }
        recoverableTakes = projectStore.unfinishedTakes(projectID: project.id)
        if cameraConfigurationCompleted {
            restartCaptureSession()
        } else {
            configure()
        }
    }

    func leaveCapture(completion: @escaping @MainActor @Sendable () -> Void) {
        guard canLeaveProject else { return }
        cameraController.stopSession(completion: completion)
    }

    func renameProject(to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            project = try projectStore.renameProject(id: project.id, name: name)
            onProjectChanged(project)
        } catch {
            errorMessage = "The Project couldn't be renamed."
        }
    }

    func retryProjectNoteSave() {
        guard canRetryProjectNoteSave else { return }
        persistProjectNote(projectNote.text, projectID: project.id)
    }

    func record() {
        guard project.pictureLock == nil else {
            errorMessage = "Unlock the video before recording a new Take."
            return
        }
        guard !isEditingTimeline else {
            errorMessage = "Wait for the Storyline edit to finish before recording."
            return
        }
        guard !isExportingProject else {
            errorMessage = "Wait for Project Export to finish before recording."
            return
        }
        guard !isRestoringCaptureSession, cameraRecoveryMessage == nil else { return }
        guard captureReady else {
            errorMessage = "Camera and microphone access are required before recording."
            return
        }
        guard hasStorageCapacity(requiredBytes: StoragePreflight.recordingRequiredBytes) else {
            errorMessage = storageErrorMessage(action: "Recording", requiredBytes: StoragePreflight.recordingRequiredBytes)
            return
        }
        do {
            let orientation = currentOrientation()
            if let format = project.format, format != ProjectFormat(orientation: orientation) {
                errorMessage = "Rotate your iPhone to match this Project's \(format.rawValue) format."
                return
            }
            let take = try store.createTake(orientation: orientation)
            currentTake = take
            logicalTimer.reset()
            elapsed = 0
            frozenRotationAngle = cameraController.frozenCaptureRotationAngle()
            try machine.apply(.recordRequested)
            setIdleTimerDisabled(true)
            publishPhase()
            startNextSegment()
        } catch {
            logger.error("Take creation failed: \(error.localizedDescription, privacy: .public)")
            fail("Couldn't start a new Take. Check available storage and try again.")
        }
    }

    func pause() {
        do {
            elapsed = logicalTimer.elapsed(activeSegmentDuration: cameraController.recordedDuration)
            try machine.apply(.pauseRequested)
            stopTimer()
            publishPhase()
            cameraController.stopRecording()
        } catch {
            logger.error("Pause rejected: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Pause isn't available right now."
        }
    }

    func resume() {
        do {
            try machine.apply(.resumeRequested)
            publishPhase()
            startNextSegment()
        } catch {
            logger.error("Resume rejected: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Resume isn't available right now."
        }
    }

    func stop() {
        do {
            let prior = machine.phase
            if prior == .recording {
                elapsed = logicalTimer.elapsed(activeSegmentDuration: cameraController.recordedDuration)
                stopTimer()
            }
            try machine.apply(.stopRequested)
            publishPhase()
            if prior == .recording {
                cameraController.stopRecording()
            } else {
                haptic(.medium)
                beginFinalization()
            }
        } catch {
            logger.error("Stop rejected: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Stop isn't available right now."
        }
    }

    func flip() {
        guard !isExportingProject else {
            errorMessage = "Wait for Project Export to finish before switching cameras."
            return
        }
        guard captureReady else {
            errorMessage = "Camera access is required."
            return
        }
        do {
            try machine.apply(.flipRequested)
            publishPhase()
            cameraController.switchCamera { [weak self] result in
                guard let self else { return }
                do {
                    switch result {
                    case let .success(position):
                        self.selectedCamera = position
                        try self.machine.apply(.cameraSwitchCompleted)
                        self.haptic(.light)
                    case let .failure(error):
                        try self.machine.apply(.cameraSwitchFailed)
                        self.logger.error("Camera switch failed: \(error.localizedDescription, privacy: .public)")
                        self.errorMessage = "Camera unavailable. Your recorded segments are safe."
                    }
                    self.publishPhase()
                } catch {
                    self.logger.error("Camera switch transition failed: \(error.localizedDescription, privacy: .public)")
                    self.fail("The camera switch could not be completed. Your recorded segments are safe.")
                }
            }
        } catch {
            logger.error("Flip rejected: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Flip isn't available right now."
        }
    }

    func retrySave() {
        guard machine.phase == .storingTake, let finalMovieURL else { return }
        errorMessage = nil
        storeFinalTake(finalMovieURL)
    }

    func recover(_ take: TakeManifest) {
        currentTake = take
        logicalTimer.reset()
        take.orderedSegments.forEach { logicalTimer.completeSegment(duration: $0.duration) }
        elapsed = logicalTimer.completedDuration
        machine = RecorderStateMachine(initialPhase: .finalizing)
        setIdleTimerDisabled(true)
        publishPhase()
        beginFinalization()
    }

    func discardRecovery(_ take: TakeManifest) {
        do {
            try store.deleteTake(id: take.id)
            recoverableTakes = projectStore.unfinishedTakes(projectID: project.id)
        } catch {
            logger.error("Recovery discard failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "The unfinished Take couldn't be discarded."
        }
    }

    func continueInterruptedTake() {
        guard machine.phase == .paused else { return }
        guard captureReady, !isRestoringCaptureSession else {
            retryCameraRecovery()
            return
        }
        isInterrupted = false
        pendingInterruption = false
        currentTake?.status = .paused
        persistCurrentTake()
        resume()
    }

    func retryCameraRecovery() {
        if cameraConfigurationCompleted {
            restartCaptureSession()
        } else {
            cameraOperationalState = .restoring
            configure()
        }
    }

    func setFollowSubjectEnabled(_ enabled: Bool) {
        followSubjectPreferenceCoordinator.appRequested(enabled)
        captureQualityPreferences.followSubjectEnabled = enabled
        persistCaptureQualityPreferences()
    }

    func setLowLightAutoEnabled(_ enabled: Bool) {
        captureQualityPreferences.lowLightAutoEnabled = enabled
        persistCaptureQualityPreferences()
    }

    func focusAndExpose(atPreviewPoint previewPoint: CGPoint) {
        cameraController.focusAndExpose(atPreviewPoint: previewPoint)
    }

    func setExposureBias(_ bias: Float) {
        cameraController.setExposureBias(bias)
    }

    func exposureBias(
        from initialBias: Float,
        verticalTranslation: Double
    ) -> Float {
        CaptureExposurePolicy.bias(
            from: initialBias,
            verticalTranslation: verticalTranslation,
            supportedRange: captureCapabilities.exposureBiasRange
        )
    }

    func adjustExposureBias(by step: Float) {
        setExposureBias(CaptureExposurePolicy.incrementedBias(
            from: captureCapabilities.exposureBias,
            step: step,
            supportedRange: captureCapabilities.exposureBiasRange
        ))
    }

    func discardCurrentTake() {
        guard machine.phase == .paused, let take = currentTake else { return }
        do {
            try store.deleteTake(id: take.id)
            resetToIdle()
        } catch {
            logger.error("Take discard failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "The Take couldn't be discarded."
        }
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        currentScenePhase = scenePhase
        switch scenePhase {
        case .inactive:
            cameraLifecyclePolicy.applicationBecameInactive()
            if cameraConfigurationCompleted { cameraOperationalState = .suspended }
        case .active:
            resumeProjectCaptionGeneration()
            if isCapturePermissionDenied {
                configure()
                return
            }
            restartCaptureSession()
        case .background:
            cameraLifecyclePolicy.applicationEnteredBackground()
            if cameraConfigurationCompleted { cameraOperationalState = .suspended }
            if cameraLifecyclePolicy.takeDispositionForBackground(activity: lifecycleTakeActivity) == .interruptTake {
                interruptActiveTake(reason: "Application entered the background")
            }
            if isExportingProject { cancelProjectExport() }
            if isAnalyzingTrim { cancelTrimAnalysis() }
            if isTranscribingCaptions { suspendProjectCaptionGeneration() }
            cameraController.stopSession()
        default:
            break
        }
    }

    func handleWorkspaceScenePhase(_ scenePhase: ScenePhase) {
        currentScenePhase = scenePhase
        switch scenePhase {
        case .active:
            resumeProjectCaptionGeneration()
        case .background:
            if isTranscribingCaptions { suspendProjectCaptionGeneration() }
        default:
            break
        }
    }

    func leaveProject(completion: @escaping @MainActor @Sendable () -> Void) {
        guard canLeaveProject else { return }
        let tasks = Array(thumbnailTasks.values)
        tasks.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        Task {
            for task in tasks { await task.value }
            cameraController.stopSession(completion: completion)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func movieURL(for take: ProjectTake) -> URL {
        projectStore.takeMovieURL(projectID: project.id, takeID: take.id)
    }

    func thumbnailURL(for take: ProjectTake) -> URL {
        projectStore.takeThumbnailURL(projectID: project.id, takeID: take.id)
    }

    var timelinePlaybackSnapshot: ExportSnapshot? { exportSnapshot }

    func performTimelineEdit(
        _ edit: TimelineEdit,
        expectedRevision: StorylineRevision
    ) async throws -> TimelineEditOutcome {
        guard workspaceMediaOperationsAreAvailable, !isExportingProject else {
            throw TimelineEditorError.editingUnavailable
        }
        guard timelineEditActivity.begin() else {
            throw TimelineEditorError.editingUnavailable
        }
        isEditingTimeline = true
        defer {
            timelineEditActivity.finish()
            isEditingTimeline = false
        }
        let outcome = try await timelineEditor.perform(
            edit,
            expectedRevision: expectedRevision
        )
        project = outcome.project
        exportSnapshot = outcome.snapshot
        onProjectChanged(outcome.project)
        return outcome
    }

    func deleteUnusedTakePermanently(_ takeID: UUID) async throws {
        guard workspaceMediaOperationsAreAvailable, !isExportingProject else {
            throw TimelineEditorError.editingUnavailable
        }
        guard timelineEditActivity.begin() else {
            throw TimelineEditorError.editingUnavailable
        }
        isEditingTimeline = true
        defer {
            timelineEditActivity.finish()
            isEditingTimeline = false
        }
        let updated = try projectStore.deleteTake(projectID: project.id, takeID: takeID)
        trimReviewTakeIDs.removeAll { $0 == takeID }
        project = updated
        onProjectChanged(updated)
    }

    func restoreTimelineSessionState(
        _ state: TimelineSessionState,
        expectedRevision: StorylineRevision,
        focusClipID: TimelineClip.ID?
    ) async throws -> TimelineEditOutcome {
        guard workspaceMediaOperationsAreAvailable, !isExportingProject else {
            throw TimelineEditorError.editingUnavailable
        }
        guard timelineEditActivity.begin() else {
            throw TimelineEditorError.editingUnavailable
        }
        isEditingTimeline = true
        defer {
            timelineEditActivity.finish()
            isEditingTimeline = false
        }
        let outcome = try await timelineEditor.restoreSessionState(
            state,
            expectedRevision: expectedRevision,
            focusClipID: focusClipID
        )
        project = outcome.project
        exportSnapshot = outcome.snapshot
        onProjectChanged(outcome.project)
        return outcome
    }

    var trimReviewTakes: [ProjectTake] {
        trimReviewTakeIDs.compactMap { id in project.takes.first(where: { $0.id == id }) }
    }

    var captionConfiguration: ProjectCaptionConfiguration? {
        project.captionConfiguration
    }

    var isPictureLocked: Bool { project.pictureLock != nil }

    var hasPhotosConfirmedPictureLock: Bool { project.hasPhotosConfirmedPictureLock }

    var projectCaptionTrack: ProjectCaptionTrack? { project.projectCaptionTrack }

    var projectTextOverlays: [ProjectTextOverlay] { project.projectTextOverlays }

    @discardableResult
    func saveProjectTextOverlays(_ overlays: [ProjectTextOverlay]) -> Bool {
        guard !isExportingProject,
              !isTranscribingCaptions,
              project.hasPhotosConfirmedPictureLock,
              let pictureLock = project.pictureLock else { return false }
        do {
            let updated = try projectStore.replaceProjectTextOverlays(
                projectID: project.id,
                pictureLockID: pictureLock.id,
                overlays: overlays
            )
            project = updated
            onProjectChanged(updated)
            return true
        } catch {
            logger.error("Text overlay save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func dismissCaptionGenerationError() {
        captionGenerationErrorMessage = nil
    }

    var hasCompletedProjectCaptions: Bool {
        project.hasPhotosConfirmedPictureLock
            && project.projectCaptionTrack?.reviewState == .approved
            && project.projectCaptionTrack?.isGenerationComplete == true
    }

    var projectCaptionGenerationProgress: Double {
        guard let track = project.projectCaptionTrack, !track.regions.isEmpty else { return 0 }
        return Double(track.completedRegions.count) / Double(track.regions.count)
    }

    var isReadyForPictureLock: Bool {
        project.isReadyForCleanMasterCommit
    }

    var needsStorylineCheck: Bool {
        project.pictureLock == nil
            && !project.primaryStoryline.clips.isEmpty
            && project.checkedStorylineRevision != project.primaryStoryline.revision
    }

    @discardableResult
    func markStorylineChecked() -> Bool {
        do {
            let updated = try projectStore.markStorylineChecked(projectID: project.id)
            project = updated
            onProjectChanged(updated)
            return true
        } catch {
            logger.error("Storyline check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func createProjectCaptions(configuration: ProjectCaptionConfiguration) -> Bool {
        guard workspaceMediaOperationsAreAvailable,
              !isExportingProject,
              !isAnalyzingTrim,
              !isEditingTimeline else { return false }
        do {
            let updated = try projectStore.createProjectCaptionTrack(
                projectID: project.id,
                configuration: configuration
            )
            project = updated
            onProjectChanged(updated)
            captionGenerationErrorMessage = nil
            resumeProjectCaptionGeneration()
            return true
        } catch {
            captionGenerationErrorMessage = "Captions couldn't be started. The video is unchanged."
            logger.error("Project caption lock failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func finishVideo() {
        if let cleanMaster = projectStore.recoverableCleanMaster(projectID: project.id),
           cleanMaster.photosSaveStartedAt != nil,
           cleanMaster.savedToPhotosAt == nil {
            presentAmbiguousCleanMasterPhotosSave()
            return
        }
        guard workspaceMediaOperationsAreAvailable,
              !isExportingProject,
              !isAnalyzingTrim,
              !isEditingTimeline,
              !isTranscribingCaptions,
              (project.pictureLock == nil || project.needsCleanMasterUpgrade),
              isReadyForPictureLock else { return }
        projectExportErrorMessage = nil
        failedProjectExportAction = nil
        cleanMasterPhotosSaveNeedsResolution = false
        isExportingProject = true
        projectExportCanCancel = true
        projectExportStatus = "Creating Clean Master…"
        projectExportProgress = 0
        setIdleTimerDisabled(true)
        projectExportProgressTimer?.invalidate()
        projectExportProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isExportingProject else { return }
                self.projectExportProgress = self.projectExporter.progress
            }
        }
        projectExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await timelineEditor.snapshot()
                try Task.checkCancellation()
                let revision = fresh.revision
                let cleanSnapshot = ExportSnapshot(
                    projectID: fresh.projectID,
                    revision: revision,
                    format: fresh.format,
                    captionConfiguration: nil,
                    captionTimeline: nil,
                    finishingTimeline: nil,
                    clips: fresh.clips,
                    duration: fresh.duration
                )
                let outputURL = projectStore.cleanMasterURL(
                    projectID: project.id,
                    revision: revision
                )
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    projectExportStatus = "Checking Clean Master…"
                    do {
                        _ = try await validateCleanMaster(
                            at: outputURL,
                            expectedDuration: fresh.duration.seconds,
                            requiresAudio: fresh.clips.contains { !$0.isMuted }
                        )
                    } catch {
                        projectStore.invalidateCleanMasterRecovery(
                            projectID: project.id,
                            removeMedia: true
                        )
                        projectExportStatus = "Rebuilding Clean Master…"
                        _ = try await exportCleanMaster(
                            plan: try ProjectExportPlan(snapshot: cleanSnapshot),
                            to: outputURL
                        )
                    }
                } else {
                    _ = try await exportCleanMaster(
                        plan: try ProjectExportPlan(snapshot: cleanSnapshot),
                        to: outputURL
                    )
                }
                let validatedDuration = try await validateCleanMaster(
                    at: outputURL,
                    expectedDuration: fresh.duration.seconds,
                    requiresAudio: fresh.clips.contains { !$0.isMuted }
                )
                let recoverable = try projectStore.recordValidatedCleanMaster(
                    projectID: project.id,
                    expectedRevision: revision,
                    cleanMasterURL: outputURL,
                    duration: validatedDuration
                )
                if recoverable.savedToPhotosAt == nil {
                    try Task.checkCancellation()
                    projectExportStatus = "Saving Clean Master to Photos…"
                    projectExportCanCancel = false
                    _ = try projectStore.recordCleanMasterPhotosSaveStarted(
                        projectID: project.id,
                        expectedRevision: revision
                    )
                    do {
                        try await finishVideoDependencies.saveToPhotos(outputURL)
                    } catch {
                        _ = try? projectStore.recordCleanMasterPhotosSaveFailed(
                            projectID: project.id,
                            expectedRevision: revision
                        )
                        throw error
                    }
                    // Persist the external side effect immediately. From here through Picture
                    // Lock commit there is intentionally no cancellation point, so normal Retry
                    // resumes at lock persistence instead of creating another Photos asset.
                    _ = try projectStore.recordCleanMasterSavedToPhotos(
                        projectID: project.id,
                        expectedRevision: revision
                    )
                }
                let updated = try await finishVideoDependencies.commitPictureLock(
                    projectStore,
                    project.id,
                    revision
                )
                project = updated
                onProjectChanged(updated)
                cleanMasterPhotosSaveNeedsResolution = false
                finishProjectExport()
                resumeProjectCaptionGeneration()
                haptic(.success)
            } catch is CancellationError {
                finishProjectExport()
            } catch let error as ProjectExportError where error == .cancelled {
                finishProjectExport()
            } catch {
                finishProjectExport()
                projectExportErrorMessage = "Finish Video couldn't complete. Every Take and the current Storyline are unchanged."
                failedProjectExportAction = .finishVideo
                logger.error("Finish Video failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func exportCleanMaster(plan: ProjectExportPlan, to url: URL) async throws -> URL {
        if let export = finishVideoDependencies.export {
            return try await export(plan, url)
        }
        return try await projectExporter.export(plan: plan, to: url)
    }

    private func validateCleanMaster(
        at url: URL,
        expectedDuration: TimeInterval,
        requiresAudio: Bool
    ) async throws -> TimeInterval {
        let actualDuration = try await finishVideoDependencies.validate(url, requiresAudio)
        guard CleanMasterDurationPolicy.accepts(
            actual: actualDuration,
            expected: expectedDuration
        ) else {
            throw ProjectExportError.exportFailed("Clean Master duration does not match the Storyline")
        }
        return actualDuration
    }

    func resumeProjectCaptionGeneration() {
        guard currentScenePhase == .active,
              project.hasPhotosConfirmedPictureLock,
              workspaceMediaOperationsAreAvailable,
              !isExportingProject,
              !isAnalyzingTrim,
              !isTranscribingCaptions,
              let track = project.projectCaptionTrack,
              track.reviewState != .approved,
              !track.pendingRegions.isEmpty else { return }
        let pending = track.pendingRegions
        let totalCount = track.regions.count
        projectCaptionGenerationID += 1
        let requestID = projectCaptionGenerationID
        isTranscribingCaptions = true
        captionGenerationErrorMessage = nil
        captionTranscriptionProgress = projectCaptionGenerationProgress
        captionTranscriptionStatus = "Creating Captions…"
        setIdleTimerDisabled(true)
        captionTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                for region in pending {
                    try Task.checkCancellation()
                    guard requestID == projectCaptionGenerationID else { return }
                    guard let take = project.takes.first(where: { $0.id == region.takeID }) else {
                        throw ProjectStoreError.takeNotFound(region.takeID)
                    }
                    captionTranscriptionStatus = "Creating Captions · \(region.localeIdentifier)"
                    let draft = try await captionTranscriber.transcribe(
                        movieAt: movieURL(for: take),
                        sourceRange: region.sourceRange,
                        localeIdentifier: region.localeIdentifier
                    )
                    try Task.checkCancellation()
                    let updated = try projectStore.recordProjectCaptionRegion(
                        projectID: project.id,
                        regionID: region.id,
                        draft: draft
                    )
                    project = updated
                    onProjectChanged(updated)
                    let completed = updated.projectCaptionTrack?.completedRegions.count ?? 0
                    captionTranscriptionProgress = Double(completed) / Double(max(1, totalCount))
                }
                finishProjectCaptionGeneration(requestID: requestID)
            } catch is CancellationError {
                guard requestID == projectCaptionGenerationID else { return }
                finishProjectCaptionGeneration(requestID: requestID)
                resumeProjectCaptionGeneration()
            } catch let error as CaptionTranscriptionError where error == .cancelled {
                guard requestID == projectCaptionGenerationID else { return }
                finishProjectCaptionGeneration(requestID: requestID)
                resumeProjectCaptionGeneration()
            } catch {
                guard requestID == projectCaptionGenerationID else { return }
                finishProjectCaptionGeneration(requestID: requestID)
                captionGenerationErrorMessage = error.localizedDescription
                logger.error("Project caption generation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @discardableResult
    func cancelProjectCaptionGeneration() -> Bool {
        guard project.hasPhotosConfirmedPictureLock, !isExportingProject else { return false }
        projectCaptionGenerationID += 1
        captionTranscriptionTask?.cancel()
        do {
            let updated = try projectStore.cancelProjectCaptionGeneration(projectID: project.id)
            project = updated
            onProjectChanged(updated)
            captionGenerationErrorMessage = nil
            finishProjectCaptionGeneration()
            return true
        } catch {
            finishProjectCaptionGeneration()
            captionGenerationErrorMessage = "Caption generation couldn't be cancelled. Retry."
            return false
        }
    }

    @discardableResult
    func regenerateProjectCaptions(
        projectLanguage: String,
        takeLanguageOverrides: [UUID: String]
    ) -> Bool {
        guard !isExportingProject else { return false }
        projectCaptionGenerationID += 1
        captionTranscriptionTask?.cancel()
        let current = captionConfiguration
            ?? ProjectCaptionConfiguration(localeIdentifier: projectLanguage, placement: .lower)
        let configuration = ProjectCaptionConfiguration(
            localeIdentifier: projectLanguage,
            placement: current.placement,
            style: current.style,
            density: current.density,
            customization: current.customization
        )
        do {
            let updated = try projectStore.regenerateProjectCaptions(
                projectID: project.id,
                configuration: configuration,
                takeLanguageOverrides: takeLanguageOverrides
            )
            project = updated
            onProjectChanged(updated)
            captionGenerationErrorMessage = nil
            finishProjectCaptionGeneration()
            resumeProjectCaptionGeneration()
            return true
        } catch {
            finishProjectCaptionGeneration()
            captionGenerationErrorMessage = "Caption languages couldn't be changed. Retry."
            return false
        }
    }

    @discardableResult
    func saveProjectCaptionCues(_ cues: [CaptionCue]) -> Bool {
        guard !isExportingProject else { return false }
        do {
            let updated = try projectStore.saveProjectCaptionCues(
                projectID: project.id,
                cues: cues
            )
            project = updated
            onProjectChanged(updated)
            captionGenerationErrorMessage = nil
            return true
        } catch {
            captionGenerationErrorMessage = "Caption changes couldn't be saved. Retry."
            return false
        }
    }

    @discardableResult
    func completeProjectCaptionReview() -> Bool {
        guard !isExportingProject else { return false }
        do {
            let updated = try projectStore.approveProjectCaptionTrack(projectID: project.id)
            project = updated
            onProjectChanged(updated)
            captionGenerationErrorMessage = nil
            return true
        } catch ProjectStoreError.incompleteProjectCaptions {
            captionGenerationErrorMessage = "Finish creating captions before completing review."
            return false
        } catch {
            captionGenerationErrorMessage = "Fix empty or overlapping captions before completing review."
            return false
        }
    }

    @discardableResult
    func updateProjectCaptionConfiguration(
        _ configuration: ProjectCaptionConfiguration,
        reflowedCues: [CaptionCue]? = nil
    ) -> Bool {
        guard !isExportingProject else { return false }
        do {
            let resolvedReflowedCues: [CaptionCue]?
            if let reflowedCues {
                resolvedReflowedCues = reflowedCues
            } else if configuration.density != project.captionConfiguration?.density,
               let cues = project.projectCaptionTrack?.cues {
                resolvedReflowedCues = CaptionPresentationComposer.compose(
                    CaptionDensityReflow.apply(
                        configuration.density,
                        to: cues,
                        regions: project.projectCaptionTrack?.regions ?? [],
                        configuration: configuration,
                        format: project.format ?? .portrait
                    ),
                    configuration: configuration,
                    format: project.format ?? .portrait
                )
            } else {
                resolvedReflowedCues = nil
            }
            let updated = try projectStore.updateProjectCaptionPresentation(
                projectID: project.id,
                configuration: configuration,
                reflowedCues: resolvedReflowedCues
            )
            project = updated
            onProjectChanged(updated)
            captionGenerationErrorMessage = nil
            return true
        } catch {
            captionGenerationErrorMessage = "Caption style couldn't be saved. Retry."
            return false
        }
    }

    @discardableResult
    func setSpokenLanguage(for takeID: UUID, localeIdentifier: String?) -> Bool {
        guard !isExportingProject else { return false }
        do {
            let updated = try projectStore.setTakeSpokenLanguage(
                projectID: project.id,
                takeID: takeID,
                localeIdentifier: localeIdentifier
            )
            project = updated
            onProjectChanged(updated)
            return true
        } catch {
            logger.error("Spoken language persistence failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func unlockPictureLock() -> Bool {
        guard !isExportingProject else { return false }
        projectCaptionGenerationID += 1
        captionTranscriptionTask?.cancel()
        do {
            let updated = try projectStore.unlockPictureLock(projectID: project.id)
            let captionlessSnapshot = exportSnapshot.map { snapshot in
                ExportSnapshot(
                    projectID: snapshot.projectID,
                    revision: updated.primaryStoryline.revision,
                    format: snapshot.format,
                    captionConfiguration: updated.captionConfiguration,
                    captionTimeline: nil,
                    clips: snapshot.clips,
                    duration: snapshot.duration
                )
            }
            project = updated
            if let captionlessSnapshot { exportSnapshot = captionlessSnapshot }
            onProjectChanged(updated)
            captionGenerationErrorMessage = nil
            finishProjectCaptionGeneration()
            return true
        } catch {
            finishProjectCaptionGeneration()
            captionGenerationErrorMessage = "The video couldn't be unlocked. Retry."
            return false
        }
    }

    var hasTakesNeedingEdgeAnalysis: Bool {
        project.takes.contains { take in
            guard take.trimDecision == nil else { return false }
            switch take.trimAnalysis {
            case nil, .failed: return true
            case .suggestion, .noSuggestion: return trimEnvelope(for: take).isEmpty
            }
        }
    }

    func trimEnvelope(for take: ProjectTake) -> [Float] {
        if let cached = trimWaveformCache[take.id], !cached.isEmpty { return cached }
        return (try? projectStore.trimEnvelope(projectID: project.id, takeID: take.id)) ?? []
    }

    func isPreparingTrimWaveform(for takeID: UUID) -> Bool {
        trimWaveformLoadingTakeIDs.contains(takeID)
    }

    func trimWaveformError(for takeID: UUID) -> String? {
        trimWaveformErrors[takeID]
    }

    func prepareTrimWaveform(takeID: UUID) async {
        guard let take = project.takes.first(where: { $0.id == takeID }) else { return }
        guard trimEnvelope(for: take).isEmpty else {
            trimWaveformErrors[takeID] = nil
            return
        }
        guard !trimWaveformLoadingTakeIDs.contains(takeID) else { return }

        trimWaveformLoadingTakeIDs.insert(takeID)
        trimWaveformErrors[takeID] = nil
        defer { trimWaveformLoadingTakeIDs.remove(takeID) }

        let expectedStorylineRevision = project.primaryStoryline.revision
        do {
            let output = try await trimAnalysisProvider(movieURL(for: take))
            try Task.checkCancellation()
            guard !output.envelope.isEmpty else {
                trimWaveformErrors[takeID] = "No audio waveform is available for this Clip."
                return
            }

            // Publish the reduced samples first so Trim stays useful even if the
            // Storyline changes before the optional on-disk cache is committed.
            trimWaveformCache[takeID] = output.envelope
            do {
                let updated = try projectStore.recordTrimAnalysis(
                    projectID: project.id,
                    takeID: takeID,
                    result: output.result,
                    envelope: output.envelope,
                    expectedStorylineRevision: expectedStorylineRevision
                )
                project = updated
                onProjectChanged(updated)
            } catch {
                logger.info("Trim waveform cache was not persisted: \(error.localizedDescription, privacy: .public)")
            }
        } catch is CancellationError {
            return
        } catch {
            logger.warning("Trim waveform preparation failed: \(error.localizedDescription, privacy: .public)")
            trimWaveformErrors[takeID] = "The waveform couldn't be built."
        }
    }

    func storageBytes(for take: ProjectTake) -> Int64 {
        projectStore.storageBytes(projectID: project.id, takeID: take.id)
    }

    func consumeCompletedTakeForReview() {
        completedTakeForReview = nil
    }

    func prepareTrimReview(takeID: UUID) -> Bool {
        guard let take = project.takes.first(where: { $0.id == takeID }) else { return false }
        if project.primaryStoryline.clips.contains(where: {
            $0.takeID == takeID && $0.selection != $0.availableRange
        }) {
            return true
        }
        let hasWaveform = !trimEnvelope(for: take).isEmpty
        switch take.trimAnalysis {
        case .suggestion, .noSuggestion:
            if hasWaveform {
                trimReviewTakeIDs = [takeID]
                return true
            }
            cleanUpEdges(takeID: takeID)
            return false
        case .failed, nil:
            cleanUpEdges(takeID: takeID)
            return false
        }
    }

    func cleanUpEdges(takeID: UUID? = nil) {
        guard phase == .idle, !isExportingProject, !isAnalyzingTrim else { return }
        let eligible = project.takes.filter { take in
            if let takeID, take.id != takeID { return false }
            guard take.trimDecision == nil else { return false }
            switch take.trimAnalysis {
            case nil, .failed: return true
            case .suggestion, .noSuggestion: return trimEnvelope(for: take).isEmpty
            }
        }
        guard !eligible.isEmpty else {
            trimAnalysisSummary = "All eligible Takes already have current edge-analysis results."
            return
        }
        isAnalyzingTrim = true
        let expectedStorylineRevision = project.primaryStoryline.revision
        trimAnalysisProgress = 0
        trimAnalysisStatus = "Preparing edge cleanup…"
        trimAnalysisSummary = nil
        trimReviewTakeIDs = []
        setIdleTimerDisabled(true)
        trimAnalysisTask = Task { [weak self] in
            guard let self else { return }
            var reviewable: [UUID] = []
            var suggestionCount = 0
            var unchangedCount = 0
            var failureCount = 0
            for (offset, take) in eligible.enumerated() {
                if Task.isCancelled { break }
                trimAnalysisStatus = "Analyzing Take \(offset + 1) of \(eligible.count)…"
                do {
                    let output = try await trimAnalyzer.analyze(movieAt: movieURL(for: take))
                    try Task.checkCancellation()
                    let updated = try projectStore.recordTrimAnalysis(
                        projectID: project.id,
                        takeID: take.id,
                        result: output.result,
                        envelope: output.envelope.isEmpty ? nil : output.envelope,
                        expectedStorylineRevision: expectedStorylineRevision
                    )
                    project = updated
                    onProjectChanged(updated)
                    switch output.result {
                    case .suggestion:
                        suggestionCount += 1
                        if !output.envelope.isEmpty { reviewable.append(take.id) }
                    case .noSuggestion:
                        unchangedCount += 1
                        if !output.envelope.isEmpty { reviewable.append(take.id) }
                    case .failed: failureCount += 1
                    }
                } catch let error as TakeTrimAnalyzerError where error == .cancelled {
                    break
                } catch is CancellationError {
                    break
                } catch {
                    if let updated = try? projectStore.recordTrimAnalysis(
                        projectID: project.id,
                        takeID: take.id,
                        result: .failed(.decodingFailed),
                        expectedStorylineRevision: expectedStorylineRevision
                    ) {
                        project = updated
                        onProjectChanged(updated)
                    }
                    failureCount += 1
                    logger.warning("Take trim analysis failed: \(error.localizedDescription, privacy: .public)")
                }
                trimAnalysisProgress = Double(offset + 1) / Double(eligible.count)
            }
            trimReviewTakeIDs = reviewable
            if Task.isCancelled {
                trimAnalysisSummary = "Edge analysis stopped. Completed results were kept."
            } else {
                var parts = ["\(suggestionCount) suggested", "\(unchangedCount) unchanged"]
                if failureCount > 0 { parts.append("\(failureCount) failed") }
                trimAnalysisSummary = parts.joined(separator: " · ")
            }
            if let refreshedSnapshot = try? await timelineEditor.snapshot() {
                exportSnapshot = refreshedSnapshot
            }
            finishTrimAnalysis()
        }
    }

    func cancelTrimAnalysis() {
        guard isAnalyzingTrim else { return }
        trimAnalyzer.cancel()
        trimAnalysisTask?.cancel()
    }

    func useTrimSelection(takeID: UUID, range: TakeRange) {
        updateTrimDecision(takeID: takeID, decision: .useSelection(range))
    }

    func keepOriginal(takeID: UUID) {
        updateTrimDecision(takeID: takeID, decision: .keepOriginal)
    }

    func resetTrim(takeID: UUID) {
        guard phase == .idle, !isExportingProject, !isAnalyzingTrim else { return }
        do {
            let updated = try projectStore.resetTrim(projectID: project.id, takeID: takeID)
            project = updated
            trimReviewTakeIDs.removeAll { $0 == takeID }
            onProjectChanged(updated)
        } catch {
            errorMessage = "The Take cleanup couldn't be reset."
        }
    }

    var canManageTakes: Bool {
        phase == .idle
            && !isExportingProject
            && !isEditingTimeline
            && !isAnalyzingTrim
            && !isTranscribingCaptions
            && project.pictureLock == nil
    }

    var canExportProject: Bool {
        workspaceMediaOperationsAreAvailable
            && !isExportingProject
            && !isTranscribingCaptions
            && !isEditingTimeline
            && !isAnalyzingTrim
            && !project.primaryStoryline.clips.isEmpty
            && project.hasPhotosConfirmedPictureLock
    }

    func exportProject(includeCaptions: Bool = true) {
        guard canExportProject else {
            projectExportErrorMessage = !project.hasPhotosConfirmedPictureLock
                ? "Finish Video before exporting the Project."
                : "Finish the current operation before exporting."
            failedProjectExportAction = nil
            return
        }
        guard !includeCaptions || hasCompletedProjectCaptions else {
            projectExportErrorMessage = "Complete Caption Review before exporting with captions."
            failedProjectExportAction = nil
            return
        }
        if projectStore.pendingExportMatches(
            projectID: project.id,
            includeCaptions: includeCaptions
        ) {
            retryProjectExportShare()
            return
        }
        let sourceBytes = project.takes.reduce(Int64(0)) { $0 + storageBytes(for: $1) }
        let requiredBytes = StoragePreflight.exportRequiredBytes(sourceBytes: sourceBytes)
        guard hasStorageCapacity(requiredBytes: requiredBytes) else {
            projectExportErrorMessage = storageErrorMessage(
                action: "Export",
                requiredBytes: requiredBytes
            )
            failedProjectExportAction = .encode(includeCaptions: includeCaptions)
            return
        }
        projectExportErrorMessage = nil
        failedProjectExportAction = nil
        isExportingProject = true
        projectExportCanCancel = true
        projectExportStatus = "Preparing Export…"
        projectExportProgress = 0
        setIdleTimerDisabled(true)
        projectExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let freshSnapshot = try await timelineEditor.snapshot()
                try Task.checkCancellation()
                guard !freshSnapshot.clips.isEmpty else {
                    throw TimelineEditorError.corruptPrimaryStoryline
                }
                let selectedSnapshot = includeCaptions
                    ? freshSnapshot
                    : ExportSnapshot(
                        projectID: freshSnapshot.projectID,
                        revision: freshSnapshot.revision,
                        format: freshSnapshot.format,
                        captionConfiguration: freshSnapshot.captionConfiguration,
                        captionTimeline: nil,
                        finishingTimeline: freshSnapshot.finishingTimeline.map {
                            ProjectFinishingTimeline(
                                pictureLockID: $0.pictureLockID,
                                duration: $0.duration,
                                textOverlays: $0.textOverlays,
                                captions: nil
                            )
                        },
                        clips: freshSnapshot.clips,
                        duration: freshSnapshot.duration
                    )
                guard !includeCaptions || ProjectExportVariantEligibility.canExportWithCaptions(
                    project: project,
                    snapshot: selectedSnapshot
                ) else {
                    throw ProjectStoreError.invalidProjectCaptionTrack
                }
                beginProjectExport(
                    plan: try ProjectExportPlan(snapshot: selectedSnapshot),
                    includeCaptions: includeCaptions
                )
            } catch is CancellationError {
                finishProjectExport()
            } catch {
                finishProjectExport()
                projectExportErrorMessage = "The Project couldn't be prepared for export."
                failedProjectExportAction = .encode(includeCaptions: includeCaptions)
            }
        }
    }

    func reportInvalidTrimRange() {
        errorMessage = "A saved Take selection is invalid. Reset its edge cleanup and try again."
    }

    func retryProjectExportShare() {
        let url = projectStore.pendingExportURL(projectID: project.id)
        guard !isExportingProject, !isTranscribingCaptions else { return }
        let includeCaptions: Bool
        if projectStore.pendingExportMatches(projectID: project.id, includeCaptions: true) {
            includeCaptions = true
        } else if projectStore.pendingExportMatches(projectID: project.id, includeCaptions: false) {
            includeCaptions = false
        } else {
            projectExportErrorMessage = "The prepared export no longer matches this Project. Export it again."
            failedProjectExportAction = nil
            return
        }
        projectExportErrorMessage = nil
        failedProjectExportAction = nil
        isExportingProject = true
        projectExportCanCancel = true
        projectExportStatus = "Checking Finished Video…"
        projectExportProgress = 0
        setIdleTimerDisabled(true)
        projectExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ProjectExportValidator().validate(
                    url,
                    requiresAudio: project.primaryStoryline.clips.contains { !$0.isMuted }
                )
                try Task.checkCancellation()
                guard projectStore.pendingExportMatches(
                    projectID: project.id,
                    includeCaptions: includeCaptions
                ) else {
                    finishProjectExport()
                    projectExportErrorMessage = "The prepared export no longer matches this Project. Export it again."
                    failedProjectExportAction = .encode(includeCaptions: includeCaptions)
                    return
                }
                finishProjectExport()
                shareableProjectExport = ShareableProjectExport(url: url)
            } catch is CancellationError {
                finishProjectExport()
            } catch {
                finishProjectExport()
                projectStore.invalidateExportRecoveryMetadata(projectID: project.id)
                projectExportErrorMessage = "The prepared export is no longer usable. Export the Project again."
                failedProjectExportAction = .encode(includeCaptions: includeCaptions)
            }
        }
    }

    func retryFailedProjectExport() {
        guard let failedProjectExportAction, !isExportingProject else { return }
        switch failedProjectExportAction {
        case .finishVideo:
            finishVideo()
        case let .encode(includeCaptions):
            exportProject(includeCaptions: includeCaptions)
        case let .finalizeStagedFile(url, includeCaptions):
            finalizeStagedProjectExport(url, includeCaptions: includeCaptions)
        case .sharePendingFile:
            retryProjectExportShare()
        }
    }

    func confirmCleanMasterIsSavedToPhotos() {
        guard !isExportingProject,
              let recoverable = projectStore.recoverableCleanMaster(projectID: project.id),
              let startedAt = recoverable.photosSaveStartedAt,
              recoverable.savedToPhotosAt == nil else { return }
        do {
            _ = try projectStore.recordCleanMasterSavedToPhotos(
                projectID: project.id,
                expectedRevision: recoverable.storylineRevision,
                savedAt: startedAt
            )
            cleanMasterPhotosSaveNeedsResolution = false
            finishVideo()
        } catch {
            presentAmbiguousCleanMasterPhotosSave()
            logger.error("Clean Master Photos confirmation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveCleanMasterToPhotosAgain() {
        guard !isExportingProject,
              let recoverable = projectStore.recoverableCleanMaster(projectID: project.id),
              recoverable.photosSaveStartedAt != nil,
              recoverable.savedToPhotosAt == nil else { return }
        do {
            _ = try projectStore.recordCleanMasterPhotosSaveFailed(
                projectID: project.id,
                expectedRevision: recoverable.storylineRevision
            )
            cleanMasterPhotosSaveNeedsResolution = false
            finishVideo()
        } catch {
            presentAmbiguousCleanMasterPhotosSave()
            logger.error("Clean Master Photos retry reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dismissProjectExportError() {
        projectExportErrorMessage = nil
        failedProjectExportAction = nil
        cleanMasterPhotosSaveNeedsResolution = false
    }

    private func presentAmbiguousCleanMasterPhotosSave() {
        projectExportErrorMessage = "The Photos save may have finished. Check Photos, then confirm it or choose Save Again."
        failedProjectExportAction = nil
        cleanMasterPhotosSaveNeedsResolution = true
    }

    func projectExportSharingFinished(completed: Bool) {
        shareableProjectExport = nil
        guard completed else { return }
        completeProjectExportShare()
    }

    func cancelProjectExport() {
        guard isExportingProject, projectExportCanCancel else { return }
        if projectExporter.isActive { projectExporter.cancel() }
        projectExportTask?.cancel()
    }

    var formattedElapsed: String {
        RecordingDurationFormatter.clock(elapsed)
    }

    var canRetrySave: Bool { phase == .storingTake && finalMovieURL != nil && errorMessage != nil }

    var canRetryProjectExportShare: Bool {
        !isExportingProject
            && (
                projectStore.pendingExportMatches(projectID: project.id, includeCaptions: true)
                    || projectStore.pendingExportMatches(projectID: project.id, includeCaptions: false)
            )
    }

    var canOpenSettingsForCurrentError: Bool {
        AppErrorSettingsPolicy.allowsOpeningSettings(for: errorMessage)
    }

    var canLeaveProject: Bool {
        (phase == .idle || !configurationStarted)
            && !isExportingProject
            && !isEditingTimeline
            && !isAnalyzingTrim
            && (!isTranscribingCaptions || project.pictureLock != nil)
    }

    var preparationItemCount: Int {
        needsStorylineCheck ? 1 : 0
    }

    func preparationIssueCount(for _: TimelinePlaybackSession.FilmstripClip) -> Int {
        0
    }

    private func suspendProjectCaptionGeneration() {
        captionTranscriptionTask?.cancel()
    }

    private func finishProjectCaptionGeneration() {
        isTranscribingCaptions = false
        captionTranscriptionProgress = projectCaptionGenerationProgress
        captionTranscriptionStatus = nil
        captionTranscriptionTask = nil
        setIdleTimerDisabled(false)
    }

    private func finishProjectCaptionGeneration(requestID: Int) {
        guard requestID == projectCaptionGenerationID else { return }
        finishProjectCaptionGeneration()
    }

    private func updateTrimDecision(takeID: UUID, decision: TrimReviewDecision) {
        guard phase == .idle, !isExportingProject, !isAnalyzingTrim else { return }
        do {
            let updated = try projectStore.setTrimDecision(
                projectID: project.id,
                takeID: takeID,
                decision: decision
            )
            project = updated
            trimReviewTakeIDs.removeAll { $0 == takeID }
            onProjectChanged(updated)
        } catch {
            errorMessage = "That selection couldn't be saved. Keep at least one second."
        }
    }

    private func finishTrimAnalysis() {
        isAnalyzingTrim = false
        trimAnalysisProgress = 0
        trimAnalysisStatus = nil
        trimAnalysisTask = nil
        setIdleTimerDisabled(false)
    }

    private func startNextSegment() {
        guard let take = currentTake else {
            fail("No active Take exists.")
            return
        }
        var index = (take.segments.map(\.index).max() ?? -1) + 1
        var url = store.segmentURL(takeID: take.id, index: index)
        while FileManager.default.fileExists(atPath: url.path) {
            index += 1
            url = store.segmentURL(takeID: take.id, index: index)
        }
        activeSegmentIndex = index
        activeSegmentCamera = selectedCamera
        cameraController.startRecording(to: url, rotationAngle: frozenRotationAngle)
    }

    private func recordingDidStart() {
        do {
            try machine.apply(.segmentStarted)
            currentTake?.status = .recording
            persistCurrentTake()
            publishPhase()
            startTimer()
            haptic(.rigid)
            if pendingInterruption { pause() }
        } catch {
            logger.error("Recording start transition failed: \(error.localizedDescription, privacy: .public)")
            fail("Recording couldn't start. No completed Segments were removed.")
        }
    }

    private func recordingDidFinish(url: URL, error: Error?) {
        var endingPhase = machine.phase
        if endingPhase == .recording {
            pendingInterruption = true
            stopTimer()
            do {
                try machine.apply(.pauseRequested)
                endingPhase = machine.phase
                publishPhase()
            } catch {
                logger.error("Unexpected recording stop transition failed: \(error.localizedDescription, privacy: .public)")
                fail("Recording stopped unexpectedly. Existing recorded segments are safe.")
                return
            }
        }
        Task {
            do {
                if let error { throw error }
                let duration = try await validator.validate(url)
                guard var take = currentTake,
                      let index = activeSegmentIndex,
                      let camera = activeSegmentCamera else {
                    throw FinalizationError.exportFailed("Segment metadata is unavailable.")
                }
                take.segments.append(Segment(
                    index: index,
                    fileName: url.lastPathComponent,
                    cameraPosition: camera,
                    createdAt: Date(),
                    duration: duration
                ))
                take.segments = take.orderedSegments
                currentTake = take
                logicalTimer.completeSegment(duration: duration)
                logger.info("Segment \(index) duration: \(duration, privacy: .public) seconds")
                elapsed = logicalTimer.completedDuration
                activeSegmentIndex = nil
                activeSegmentCamera = nil

                if endingPhase == .stoppingForPause {
                    try machine.apply(.segmentFinished)
                    currentTake?.status = pendingInterruption ? .interrupted : .paused
                    isInterrupted = pendingInterruption
                    persistCurrentTake()
                    publishPhase()
                    haptic(.soft)
                } else if endingPhase == .stopping {
                    try machine.apply(.segmentFinished)
                    persistCurrentTake()
                    publishPhase()
                    haptic(.medium)
                    beginFinalization()
                } else {
                    throw InvalidRecorderTransition(phase: endingPhase, event: .segmentFinished)
                }
            } catch {
                logger.error("Segment completion failed: \(error.localizedDescription, privacy: .public)")
                if isDiskFull(error) {
                    fail("Not enough storage to continue recording. Existing recorded segments are safe.")
                } else {
                    fail("The Segment could not be completed. Existing recorded segments are safe.")
                }
            }
        }
    }

    private func beginFinalization() {
        guard var take = currentTake else {
            fail("No Take is available to finish.")
            return
        }
        let sourceBytes = take.segments.reduce(Int64(0)) { total, segment in
            let url = store.takeDirectory(id: take.id).appendingPathComponent(segment.fileName)
            let size = (try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]))
            return total + Int64(size?.fileAllocatedSize ?? size?.fileSize ?? 0)
        }
        let requiredBytes = StoragePreflight.finalizationRequiredBytes(sourceBytes: sourceBytes)
        guard hasStorageCapacity(requiredBytes: requiredBytes) else {
            fail(storageErrorMessage(action: "Take finalization", requiredBytes: requiredBytes))
            return
        }
        take.status = .finalizing
        currentTake = take
        persistCurrentTake()
        Task {
            do {
                let url = try await finalizer.finalize(take, store: store)
                finalMovieURL = url
                try machine.apply(.finalizationSucceeded)
                currentTake?.status = .readyToSave
                persistCurrentTake()
                publishPhase()
                storeFinalTake(url)
            } catch {
                logger.error("Finalization failed: \(error.localizedDescription, privacy: .public)")
                fail("Couldn't finish the video. Your recorded segments are safe.")
            }
        }
    }

    private func storeFinalTake(_ url: URL) {
        Task {
            do {
                guard let currentTake else { throw FinalizationError.exportFailed("Take metadata is unavailable.") }
                let takeID = currentTake.id
                let playableDuration = try await validator.validate(url)
                let completion = try await timelineEditor.completeFinalizedTake(
                    FinalizedTake(
                        id: takeID,
                        movieURL: url,
                        orientation: currentTake.orientation,
                        duration: playableDuration,
                        createdAt: currentTake.createdAt
                    ),
                    expectedRevision: project.primaryStoryline.revision
                )
                project = completion.project
                exportSnapshot = completion.snapshot
                onProjectChanged(completion.project)
                completedTakeForReview = completion.take
                try machine.apply(.takeStored)
                haptic(.success)
                resetToIdle()
                generateThumbnail(for: takeID)
            } catch {
                logger.error("Project Take save failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = "Couldn't add the Take to this Project. Your recording has been kept."
            }
        }
    }

    private func refreshExportSnapshot() {
        exportSnapshotRequestID += 1
        let requestID = exportSnapshotRequestID
        exportSnapshotTask?.cancel()
        exportSnapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await timelineEditor.snapshot()
                try Task.checkCancellation()
                guard requestID == exportSnapshotRequestID else { return }
                exportSnapshot = snapshot
            } catch is CancellationError {
                return
            } catch {
                guard requestID == exportSnapshotRequestID else { return }
                exportSnapshot = nil
                logger.error("Export Snapshot refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func refreshProjectCaptionWaveform() {
        projectCaptionWaveformRequestID += 1
        let requestID = projectCaptionWaveformRequestID
        projectCaptionWaveformTask?.cancel()
        guard let lock = project.pictureLock else {
            projectCaptionWaveform = []
            projectCaptionWaveformTask = nil
            return
        }
        let projectID = project.id
        let takes = project.takes
        let store = projectStore
        projectCaptionWaveformTask = Task { [weak self] in
            let waveform = await Task.detached(priority: .utility) {
                let envelopes = Dictionary(uniqueKeysWithValues: takes.map { take in
                    (
                        take.id,
                        (try? store.trimEnvelope(projectID: projectID, takeID: take.id)) ?? []
                    )
                })
                return ProjectCaptionWaveformBuilder.make(
                    lock: lock,
                    takes: takes,
                    envelopes: envelopes
                )
            }.value
            guard !Task.isCancelled,
                  let self,
                  requestID == projectCaptionWaveformRequestID else { return }
            projectCaptionWaveform = waveform
            projectCaptionWaveformTask = nil
        }
    }

    private func generateThumbnail(for takeID: UUID) {
        let movieURL = projectStore.takeMovieURL(projectID: project.id, takeID: takeID)
        let thumbnailURL = projectStore.takeThumbnailURL(projectID: project.id, takeID: takeID)
        thumbnailTasks[takeID]?.cancel()
        thumbnailTasks[takeID] = Task { [weak self] in
            guard let self else { return }
            defer { thumbnailTasks[takeID] = nil }
            do {
                try await thumbnailGenerator.generate(movieAt: movieURL, destination: thumbnailURL)
                try Task.checkCancellation()
                let updated = try projectStore.setThumbnail(projectID: project.id, takeID: takeID)
                project = updated
                onProjectChanged(updated)
            } catch {
                logger.warning("Thumbnail generation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func beginProjectExport(plan: ProjectExportPlan, includeCaptions: Bool) {
        projectExportErrorMessage = nil
        failedProjectExportAction = nil
        projectExportStatus = "Combining Takes…"
        projectExportProgress = 0
        projectExportProgressTimer?.invalidate()
        projectExportProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isExportingProject else { return }
                self.projectExportProgress = self.projectExporter.progress
            }
        }
        setIdleTimerDisabled(true)
        let outputURL = projectStore.pendingExportWorkingURL(projectID: project.id)
        let pendingURL = projectStore.pendingExportURL(projectID: project.id)
        projectExportTask = Task { [weak self] in
            guard let self else { return }
            var committedNewExport = false
            var stagedExportReady = false
            var stagedExportURL = outputURL
            do {
                let workingURL = try await projectExporter.export(plan: plan, to: outputURL)
                stagedExportURL = try projectStore.markValidatedStagedExportCompleted(
                    projectID: project.id,
                    stagedURL: workingURL,
                    includeCaptions: includeCaptions
                )
                stagedExportReady = true
                try projectStore.recordStagedExportDescriptor(
                    projectID: project.id,
                    stagedURL: stagedExportURL,
                    includeCaptions: includeCaptions
                )
                try Task.checkCancellation()
                let url = try projectStore.commitPendingExport(
                    projectID: project.id,
                    stagedURL: stagedExportURL
                )
                committedNewExport = true
                let updated = try projectStore.setPendingExportState(projectID: project.id, pending: true)
                try projectStore.recordPendingExportDescriptor(
                    projectID: project.id,
                    includeCaptions: includeCaptions
                )
                try projectStore.clearStagedExportRequest(projectID: project.id)
                project = updated
                onProjectChanged(updated)
                finishProjectExport()
                shareableProjectExport = ShareableProjectExport(url: url)
                haptic(.success)
            } catch let error as ProjectExportError where error == .cancelled {
                finishProjectExport()
            } catch is CancellationError {
                finishProjectExport()
            } catch {
                let exportIsReady = committedNewExport
                    && FileManager.default.fileExists(atPath: pendingURL.path)
                finishProjectExport()
                projectExportErrorMessage = exportIsReady
                    ? "The finished video is safe in this Project. Retry sharing it."
                    : (stagedExportReady && FileManager.default.fileExists(atPath: stagedExportURL.path)
                        ? "The finished video is safe in this Project. Retry finalizing it."
                        : "The Project couldn't be combined. Every Take is still safe.")
                if exportIsReady {
                    failedProjectExportAction = .sharePendingFile
                } else if stagedExportReady,
                          FileManager.default.fileExists(atPath: stagedExportURL.path) {
                    failedProjectExportAction = .finalizeStagedFile(
                        stagedExportURL,
                        includeCaptions: includeCaptions
                    )
                } else {
                    failedProjectExportAction = .encode(includeCaptions: includeCaptions)
                }
                logger.error("Project export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func finalizeStagedProjectExport(
        _ stagedURL: URL,
        includeCaptions: Bool
    ) {
        guard !isExportingProject,
              !isTranscribingCaptions,
              let recovery = projectStore.recoverableStagedExport(projectID: project.id),
              !recovery.isCommitted,
              recovery.includeCaptions == includeCaptions,
              recovery.url.standardizedFileURL == stagedURL.standardizedFileURL else {
            projectExportErrorMessage = "The prepared export no longer matches this Project. Export it again."
            failedProjectExportAction = nil
            return
        }
        projectExportErrorMessage = nil
        failedProjectExportAction = nil
        isExportingProject = true
        projectExportCanCancel = true
        projectExportStatus = "Checking Finished Video…"
        projectExportProgress = 0
        setIdleTimerDisabled(true)
        projectExportTask = Task { [weak self] in
            guard let self else { return }
            var validated = false
            do {
                _ = try await ProjectExportValidator().validate(
                    stagedURL,
                    requiresAudio: project.primaryStoryline.clips.contains { !$0.isMuted }
                )
                validated = true
                try Task.checkCancellation()
                try projectStore.recordStagedExportDescriptor(
                    projectID: project.id,
                    stagedURL: stagedURL,
                    includeCaptions: includeCaptions
                )
                let url = try projectStore.commitPendingExport(
                    projectID: project.id,
                    stagedURL: stagedURL
                )
                let updated = try projectStore.setPendingExportState(projectID: project.id, pending: true)
                try projectStore.recordPendingExportDescriptor(
                    projectID: project.id,
                    includeCaptions: includeCaptions
                )
                try projectStore.clearStagedExportRequest(projectID: project.id)
                project = updated
                onProjectChanged(updated)
                finishProjectExport()
                shareableProjectExport = ShareableProjectExport(url: url)
                haptic(.success)
            } catch is CancellationError {
                finishProjectExport()
            } catch {
                let pendingURL = projectStore.pendingExportURL(projectID: project.id)
                let committed = FileManager.default.fileExists(atPath: pendingURL.path)
                    && !FileManager.default.fileExists(atPath: stagedURL.path)
                finishProjectExport()
                if !validated {
                    projectStore.quarantineInvalidStagedExport(
                        projectID: project.id,
                        stagedURL: stagedURL
                    )
                    failedProjectExportAction = .encode(includeCaptions: includeCaptions)
                    projectExportErrorMessage = "The prepared export is no longer usable. Export the Project again."
                } else if committed {
                    failedProjectExportAction = .sharePendingFile
                    projectExportErrorMessage = "The finished video is safe in this Project. Retry sharing it."
                } else if projectStore.recoverableStagedExport(projectID: project.id) != nil {
                    failedProjectExportAction = .finalizeStagedFile(
                        stagedURL,
                        includeCaptions: includeCaptions
                    )
                    projectExportErrorMessage = "The finished video is safe in this Project. Retry finalizing it."
                } else {
                    failedProjectExportAction = .encode(includeCaptions: includeCaptions)
                    projectExportErrorMessage = "The prepared export is no longer usable. Export the Project again."
                }
            }
        }
    }

    private func finishProjectExport() {
        projectExportProgressTimer?.invalidate()
        projectExportProgressTimer = nil
        isExportingProject = false
        projectExportCanCancel = false
        projectExportStatus = nil
        projectExportProgress = 0
        projectExportTask = nil
        setIdleTimerDisabled(false)
    }

    private func completeProjectExportShare() {
        do {
            try projectStore.recordExportHandoffCompleted(projectID: project.id)
            try projectStore.removePendingExport(projectID: project.id)
            let updated = try projectStore.setPendingExportState(projectID: project.id, pending: false)
            project = updated
            onProjectChanged(updated)
        } catch {
            logger.warning("Export sharing completed; durable cleanup will resume on launch: \(error.localizedDescription, privacy: .public)")
            if let updated = try? projectStore.load(id: project.id) {
                project = updated
                onProjectChanged(updated)
            }
        }
    }

    private func interruptActiveTake(reason: String) {
        logger.warning("Take interrupted: \(reason, privacy: .public)")
        if machine.phase == .recording {
            pendingInterruption = true
            pause()
        } else if machine.phase == .startingSegment || machine.phase == .resuming || machine.phase == .stoppingForPause {
            pendingInterruption = true
        } else if machine.phase == .paused {
            pendingInterruption = true
            isInterrupted = true
            currentTake?.status = .interrupted
            persistCurrentTake()
        }
    }

    private var lifecycleTakeActivity: CameraLifecyclePolicy.TakeActivity {
        switch machine.phase {
        case .recording, .startingSegment, .resuming, .stoppingForPause:
            .activeSegment
        case .paused:
            .paused
        default:
            .inactive
        }
    }

    private func handleCaptureInterruption(reason: String) {
        handleCaptureFailure(
            reason: "Capture session interruption \(reason)",
            message: "Camera is unavailable. Your recordings are safe."
        )
    }

    private func handleRuntimeError(_ error: Error) {
        handleCaptureFailure(
            reason: error.localizedDescription,
            message: "The camera stopped unexpectedly. Your recordings are safe."
        )
    }

    private func handleCaptureFailure(reason: String, message: String) {
        let takeDisposition = cameraLifecyclePolicy.takeDispositionForSessionFailure(
            activity: lifecycleTakeActivity
        )
        if takeDisposition == .interruptTake {
            interruptActiveTake(reason: reason)
        }
        if cameraLifecyclePolicy.sessionFailureDisposition == .suppressExpectedLifecycle {
            logger.info("Suppressing expected capture failure during application lifecycle transition")
            return
        }
        presentPersistentCameraFailure(message)
    }

    private func presentPersistentCameraFailure(_ message: String) {
        cameraOperationalState = .unavailable(message)
    }

    private func persistCaptureQualityPreferences() {
        capturePreferenceStore.save(captureQualityPreferences)
        cameraController.setQualityPreferences(captureQualityPreferences)
    }

    private func persistProjectNote(_ text: String, projectID: UUID) {
        do {
            let updated = try projectStore.updateNote(projectID: projectID, text: text)
            project = updated
            canRetryProjectNoteSave = false
            projectNoteSaveErrorMessage = nil
            onProjectChanged(updated)
        } catch {
            canRetryProjectNoteSave = true
            projectNoteSaveErrorMessage = "The Project Note couldn't be saved. Your text is still here."
        }
    }

    private func captureCapabilitiesDidChange(_ capabilities: CaptureCapabilities) {
        captureCapabilities = capabilities
        guard let systemPreference = followSubjectPreferenceCoordinator.receivedSystemValue(
            capabilities.isSubjectFollowingEnabled,
            isSupported: capabilities.supportsSubjectFollowing
        ) else { return }
        captureQualityPreferences.followSubjectEnabled = systemPreference
        capturePreferenceStore.save(captureQualityPreferences)
    }

    private func captureInterruptionDidEnd() {
        guard cameraLifecyclePolicy.shouldRestartAfterInterruptionEnded else {
            logger.info("Skipping capture restart while application is not active")
            return
        }
        restartCaptureSession()
    }

    private func restartCaptureSession() {
        guard currentScenePhase == .active, cameraConfigurationCompleted else { return }
        let lifecycleAttempt = cameraLifecyclePolicy.applicationBecameActive()
        cameraOperationalState = .restoring
        cameraController.startSession { [weak self] isUsable in
            guard let self,
                  let result = self.cameraLifecyclePolicy.restorationCompleted(
                      lifecycleAttempt,
                      isUsable: isUsable
                  ) else { return }
            switch result {
            case .restored:
                self.cameraOperationalState = .ready
                self.logger.info("Capture session is running after lifecycle recovery")
            case .unavailable:
                self.presentPersistentCameraFailure("Camera is unavailable. Your recordings are safe.")
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.machine.phase == .recording else { return }
                self.elapsed = self.logicalTimer.elapsed(activeSegmentDuration: self.cameraController.recordedDuration)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func persistCurrentTake() {
        guard let currentTake else { return }
        do { try store.save(currentTake) }
        catch {
            logger.error("Manifest save failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "The Take could not be saved safely."
        }
    }

    private func resetToIdle() {
        stopTimer()
        currentTake = nil
        finalMovieURL = nil
        activeSegmentIndex = nil
        activeSegmentCamera = nil
        logicalTimer.reset()
        elapsed = 0
        isInterrupted = false
        pendingInterruption = false
        machine = RecorderStateMachine(initialPhase: .idle)
        setIdleTimerDisabled(false)
        recoverableTakes = projectStore.unfinishedTakes(projectID: project.id)
        publishPhase()
    }

    private func publishPhase() {
        phase = machine.phase
        logger.info("Recorder phase: \(self.phase.rawValue, privacy: .public)")
    }

    private func fail(_ message: String) {
        stopTimer()
        errorMessage = message
        do { try machine.apply(.failureOccurred) } catch { machine = RecorderStateMachine(initialPhase: .failed) }
        currentTake?.status = .failed
        persistCurrentTake()
        publishPhase()
        currentTake = nil
        finalMovieURL = nil
        activeSegmentIndex = nil
        activeSegmentCamera = nil
        logicalTimer.reset()
        elapsed = 0
        isInterrupted = false
        pendingInterruption = false
        recoverableTakes = projectStore.unfinishedTakes(projectID: project.id)
        machine = RecorderStateMachine(initialPhase: .idle)
        setIdleTimerDisabled(false)
        publishPhase()
    }

    private func hasStorageCapacity(requiredBytes: Int64) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let available = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        return StoragePreflight.hasCapacity(requiredBytes: requiredBytes, availableBytes: available ?? Int64.max)
    }

    private func storageErrorMessage(action: String, requiredBytes: Int64) -> String {
        let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
        let projects = (try? projectStore.projects()) ?? []
        let largest = projects.map { project in
            (project.name, projectStore.storageBytes(projectID: project.id))
        }
        .sorted { $0.1 > $1.1 }
        .prefix(3)
        .map { "\($0.0) (\(ByteCountFormatter.string(fromByteCount: $0.1, countStyle: .file)))" }
        .joined(separator: ", ")
        if largest.isEmpty {
            return "\(action) needs about \(required) free. Every existing recording is still safe."
        }
        return "\(action) needs about \(required) free. Largest Projects: \(largest)."
    }

    private func isDiskFull(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == AVFoundationErrorDomain &&
            cocoaError.code == AVError.Code.diskFull.rawValue
    }

    private func currentOrientation() -> TakeOrientation {
        let interface = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation
        switch interface {
        case .landscapeLeft: return TakeOrientation.landscapeLeft
        case .landscapeRight: return TakeOrientation.landscapeRight
        default: return TakeOrientation.portrait
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    private enum Haptic {
        case light, medium, rigid, soft, success
    }

    private func haptic(_ haptic: Haptic) {
        switch haptic {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .rigid: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
