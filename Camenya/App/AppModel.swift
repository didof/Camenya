import AVFoundation
import Foundation
import OSLog
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var project: ProjectManifest {
        didSet {
            exportSnapshot = nil
            refreshExportSnapshot()
        }
    }
    @Published private(set) var exportSnapshot: ExportSnapshot?
    @Published private(set) var phase: RecorderPhase = .configuring
    @Published private(set) var selectedCamera: CameraPosition = .front
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String? {
        didSet {
            if !isPublishingCameraAlert { presentedCameraAlertID = nil }
        }
    }
    @Published private(set) var recoverableTakes: [TakeManifest] = []
    @Published private(set) var isInterrupted = false
    @Published private(set) var captureReady = false
    @Published private(set) var isExportingProject = false
    @Published private(set) var isEditingTimeline = false
    @Published private(set) var projectExportStatus: String?
    @Published private(set) var completedTakeForReview: ProjectTake?
    @Published private(set) var projectExportProgress: Double = 0
    @Published private(set) var isAnalyzingTrim = false
    @Published private(set) var trimAnalysisProgress: Double = 0
    @Published private(set) var trimAnalysisStatus: String?
    @Published private(set) var trimAnalysisSummary: String?
    @Published private(set) var trimReviewTakeIDs: [UUID] = []
    @Published private(set) var isTranscribingCaptions = false
    @Published private(set) var captionTranscriptionProgress: Double = 0
    @Published private(set) var captionTranscriptionStatus: String?
    @Published private(set) var captionReviewTakeIDs: [UUID] = []

    let cameraController = CameraController()
    let projectNote: ProjectNoteStore

    private let logger = Logger(subsystem: "org.camenya.app", category: "AppModel")
    private let projectStore: ProjectStore
    private let store: TakeManifestStore
    private let timelineEditor: TimelineEditor
    private let finalizer = TakeFinalizer()
    private let validator = SegmentValidator()
    private let projectExporter = ProjectExporter()
    private let photoLibrarySaver = PhotoLibrarySaver()
    private let thumbnailGenerator = TakeThumbnailGenerator()
    private let trimAnalyzer = TakeTrimAnalyzer()
    private let captionTranscriber = CaptionTranscriber(recognizer: CaptionRecognizerFactory.make())
    private let onProjectChanged: @MainActor (ProjectManifest) -> Void
    private var machine = RecorderStateMachine()
    private var cameraRecoveryAlertState = CameraRecoveryAlertState()
    private var presentedCameraAlertID: UInt?
    private var isPublishingCameraAlert = false
    private var logicalTimer = LogicalRecordingTimer()
    private var currentTake: TakeManifest?
    private var finalMovieURL: URL?
    private var frozenRotationAngle: CGFloat = 90
    private var activeSegmentIndex: Int?
    private var activeSegmentCamera: CameraPosition?
    private var timer: Timer?
    private var pendingInterruption = false
    private var configurationStarted = false
    private var projectExportTask: Task<Void, Never>?
    private var projectExportProgressTimer: Timer?
    private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]
    private var trimAnalysisTask: Task<Void, Never>?
    private var captionTranscriptionTask: Task<Void, Never>?
    private var exportSnapshotTask: Task<Void, Never>?
    private var exportSnapshotRequestID = 0
    private var timelineEditActivity = TimelineEditActivity()

    init(
        project: ProjectManifest,
        projectStore: ProjectStore,
        onProjectChanged: @escaping @MainActor (ProjectManifest) -> Void = { _ in }
    ) {
        self.project = project
        self.exportSnapshot = nil
        self.projectStore = projectStore
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
        self.captionReviewTakeIDs = project.takes.compactMap { take in
            take.captions?.reviewState == .needsReview ? take.id : nil
        }
        let projectID = project.id
        cameraController.onRecordingStarted = { [weak self] in self?.recordingDidStart() }
        cameraController.onRecordingFinished = { [weak self] url, error in self?.recordingDidFinish(url: url, error: error) }
        cameraController.onInterrupted = { [weak self] reason in self?.handleCaptureInterruption(reason: reason) }
        cameraController.onInterruptionEnded = { [weak self] in self?.restartCaptureSession() }
        cameraController.onRuntimeError = { [weak self] error in self?.handleRuntimeError(error) }
        projectNote.setOnChange { [weak self] text in
            guard let self else { return }
            do {
                let updated = try projectStore.updateNote(projectID: projectID, text: text)
                self.project = updated
                onProjectChanged(updated)
            } catch {
                self.errorMessage = "The Project Note couldn't be saved. Copy it before leaving this Project."
            }
        }
        refreshExportSnapshot()
    }

    func configure() {
        guard !configurationStarted else { return }
        configurationStarted = true
        recoverableTakes = projectStore.unfinishedTakes(projectID: project.id)
        Task {
            guard await CameraPermissions.requestRequiredAccess() else {
                machine = RecorderStateMachine(initialPhase: .idle)
                publishPhase()
                errorMessage = "Camera and microphone access are required before recording."
                return
            }
            cameraController.configure { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    do {
                        self.captureReady = true
                        try self.machine.apply(.sessionConfigured)
                        self.publishPhase()
                    } catch {
                        self.logger.error("Session transition failed: \(error.localizedDescription, privacy: .public)")
                        self.fail("The camera could not be prepared.")
                    }
                case let .failure(error):
                    self.logger.error("Camera configuration failed: \(error.localizedDescription, privacy: .public)")
                    self.machine = RecorderStateMachine(initialPhase: .idle)
                    self.publishPhase()
                    self.errorMessage = "Camera unavailable."
                }
            }
        }
    }

    func record() {
        guard !isEditingTimeline else {
            errorMessage = "Wait for the Storyline edit to finish before recording."
            return
        }
        guard !isExportingProject else {
            errorMessage = "Wait for Project Export to finish before recording."
            return
        }
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
        isInterrupted = false
        pendingInterruption = false
        currentTake?.status = .paused
        persistCurrentTake()
        restartCaptureSession()
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
        switch scenePhase {
        case .active:
            restartCaptureSession()
        case .background:
            interruptActiveTake(reason: "Application entered the background")
            if isExportingProject { cancelProjectExport() }
            if isAnalyzingTrim { cancelTrimAnalysis() }
            if isTranscribingCaptions { cancelCaptionTranscription() }
            cameraController.stopSession()
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
        presentedCameraAlertID = nil
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
        guard phase == .idle, !isExportingProject else {
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
        guard phase == .idle, !isExportingProject else {
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
        captionReviewTakeIDs.removeAll { $0 == takeID }
        project = updated
        onProjectChanged(updated)
    }

    var trimReviewTakes: [ProjectTake] {
        trimReviewTakeIDs.compactMap { id in project.takes.first(where: { $0.id == id }) }
    }

    var captionReviewTakes: [ProjectTake] {
        captionReviewTakeIDs.compactMap { id in project.takes.first(where: { $0.id == id }) }
    }

    var captionConfiguration: ProjectCaptionConfiguration? {
        project.captionConfiguration
    }

    var hasReviewableCaptions: Bool {
        guard let locale = project.captionConfiguration?.localeIdentifier else { return false }
        return project.takes.contains { take in
            guard let captions = take.captions else { return false }
            return captions.localeIdentifier == locale && captions.reviewState != .stale
        }
    }

    var captionedTakeCount: Int {
        project.takes.filter { $0.captions != nil }.count
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

    @discardableResult
    func prepareCaptionReview() -> Bool {
        guard let locale = project.captionConfiguration?.localeIdentifier else { return false }
        captionReviewTakeIDs = project.takes.compactMap { take in
            guard let captions = take.captions,
                  captions.localeIdentifier == locale,
                  captions.reviewState != .stale else { return nil }
            return take.id
        }
        return !captionReviewTakeIDs.isEmpty
    }

    @discardableResult
    func prepareCaptionReview(takeID: UUID) -> Bool {
        guard let locale = project.captionConfiguration?.localeIdentifier,
              let take = project.takes.first(where: { $0.id == takeID }),
              let captions = take.captions,
              captions.localeIdentifier == locale,
              captions.reviewState != .stale else {
            return false
        }
        captionReviewTakeIDs = [takeID]
        return true
    }

    func setCaptionPlacement(_ placement: CaptionPlacementZone) {
        guard var configuration = project.captionConfiguration else { return }
        configuration.placement = placement
        do {
            let updated = try projectStore.setCaptionConfiguration(
                projectID: project.id,
                configuration: configuration
            )
            project = updated
            onProjectChanged(updated)
        } catch {
            errorMessage = "The caption position couldn't be saved."
        }
    }

    func createCaptions(
        configuration: ProjectCaptionConfiguration,
        regenerateAll: Bool = false
    ) {
        guard phase == .idle,
              !isExportingProject,
              !isAnalyzingTrim,
              !isTranscribingCaptions else { return }
        let scope: CaptionTranscriptionScope = regenerateAll ? .all : .missingOrOutdated
        let eligibleIDs = Set(CaptionTranscriptionSelection.takeIDs(
            from: project.takes,
            configuration: configuration,
            scope: scope
        ))
        let eligible = project.takes.filter { eligibleIDs.contains($0.id) }
        do {
            let updated = try projectStore.setCaptionConfiguration(
                projectID: project.id,
                configuration: configuration
            )
            project = updated
            onProjectChanged(updated)
        } catch {
            errorMessage = "The caption language couldn't be saved."
            return
        }
        guard !eligible.isEmpty else {
            _ = prepareCaptionReview()
            return
        }
        isTranscribingCaptions = true
        let expectedStorylineRevision = project.primaryStoryline.revision
        captionTranscriptionProgress = 0
        captionTranscriptionStatus = "Preparing on-device captions…"
        captionReviewTakeIDs = []
        setIdleTimerDisabled(true)
        captionTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            var reviewIDs: [UUID] = []
            do {
                for (offset, take) in eligible.enumerated() {
                    try Task.checkCancellation()
                    captionTranscriptionStatus = "Transcribing Take \(offset + 1) of \(eligible.count)…"
                    guard let sourceRange = take.concreteEffectiveRange else {
                        throw CaptionTranscriptionError.invalidSourceRange
                    }
                    let draft = try await captionTranscriber.transcribe(
                        movieAt: movieURL(for: take),
                        sourceRange: sourceRange,
                        localeIdentifier: configuration.localeIdentifier
                    )
                    try Task.checkCancellation()
                    let updated = try projectStore.recordCaptionDraft(
                        projectID: project.id,
                        takeID: take.id,
                        draft: draft,
                        expectedStorylineRevision: expectedStorylineRevision
                    )
                    project = updated
                    onProjectChanged(updated)
                    reviewIDs.append(take.id)
                    captionTranscriptionProgress = Double(offset + 1) / Double(eligible.count)
                }
                captionReviewTakeIDs = reviewIDs
                finishCaptionTranscription()
            } catch is CancellationError {
                captionReviewTakeIDs = reviewIDs
                finishCaptionTranscription()
            } catch let error as CaptionTranscriptionError where error == .cancelled {
                captionReviewTakeIDs = reviewIDs
                finishCaptionTranscription()
            } catch {
                captionReviewTakeIDs = reviewIDs
                finishCaptionTranscription()
                errorMessage = error.localizedDescription
                logger.error("Caption transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelCaptionTranscription() {
        captionTranscriptionTask?.cancel()
    }

    @discardableResult
    func saveCaptionDraft(takeID: UUID, track: TakeCaptionTrack) -> Bool {
        do {
            var draft = track
            draft.reviewState = .needsReview
            let updated = try projectStore.recordCaptionDraft(
                projectID: project.id,
                takeID: takeID,
                draft: draft
            )
            project = updated
            onProjectChanged(updated)
            return true
        } catch {
            errorMessage = "Caption changes couldn't be saved."
            return false
        }
    }

    @discardableResult
    func approveCaptions(takeID: UUID, track: TakeCaptionTrack) -> Bool {
        do {
            var draft = track
            draft.reviewState = .needsReview
            _ = try projectStore.recordCaptionDraft(
                projectID: project.id,
                takeID: takeID,
                draft: draft
            )
            let updated = try projectStore.approveCaptions(projectID: project.id, takeID: takeID)
            project = updated
            captionReviewTakeIDs.removeAll { $0 == takeID }
            onProjectChanged(updated)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func trimEnvelope(for take: ProjectTake) -> [Float] {
        (try? projectStore.trimEnvelope(projectID: project.id, takeID: take.id)) ?? []
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
    }

    var canExportProject: Bool {
        canManageTakes
            && (canRetryProjectExportSave || exportSnapshot?.clips.isEmpty == false)
    }

    func exportProject() {
        guard phase == .idle,
              !isExportingProject,
              !isEditingTimeline,
              !isAnalyzingTrim else { return }
        if canRetryProjectExportSave {
            retryProjectExportSave()
            return
        }
        let sourceBytes = project.takes.reduce(Int64(0)) { $0 + storageBytes(for: $1) }
        let requiredBytes = StoragePreflight.exportRequiredBytes(sourceBytes: sourceBytes)
        guard hasStorageCapacity(requiredBytes: requiredBytes) else {
            errorMessage = storageErrorMessage(action: "Export", requiredBytes: requiredBytes)
            return
        }
        do {
            guard let exportSnapshot, !exportSnapshot.clips.isEmpty else {
                throw TimelineEditorError.corruptPrimaryStoryline
            }
            let plan = try ProjectExportPlan(snapshot: exportSnapshot)
            beginProjectExport(plan: plan)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reportInvalidTrimRange() {
        errorMessage = "A saved Take selection is invalid. Reset its edge cleanup and try again."
    }

    func retryProjectExportSave() {
        let url = projectStore.pendingExportURL(projectID: project.id)
        guard FileManager.default.fileExists(atPath: url.path), !isExportingProject else { return }
        saveProjectExportToPhotos(url)
    }

    func cancelProjectExport() {
        guard isExportingProject, projectExportStatus == "Combining Takes…" else { return }
        projectExporter.cancel()
        projectExportTask?.cancel()
    }

    var formattedElapsed: String {
        RecordingDurationFormatter.clock(elapsed)
    }

    var canRetrySave: Bool { phase == .storingTake && finalMovieURL != nil && errorMessage != nil }

    var canRetryProjectExportSave: Bool {
        !isExportingProject && projectStore.pendingExportNeedsPhotoSave(projectID: project.id)
    }

    var canOpenSettingsForCurrentError: Bool {
        AppErrorSettingsPolicy.allowsOpeningSettings(for: errorMessage)
    }

    var canLeaveProject: Bool {
        phase == .idle
            && !isExportingProject
            && !isEditingTimeline
            && !isAnalyzingTrim
            && !isTranscribingCaptions
    }

    private func finishCaptionTranscription() {
        isTranscribingCaptions = false
        captionTranscriptionProgress = 0
        captionTranscriptionStatus = nil
        captionTranscriptionTask = nil
        setIdleTimerDisabled(false)
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

    private func beginProjectExport(plan: ProjectExportPlan) {
        errorMessage = nil
        isExportingProject = true
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
        let outputURL = projectStore.pendingExportURL(projectID: project.id)
        projectExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await projectExporter.export(plan: plan, to: outputURL)
                try Task.checkCancellation()
                let updated = try projectStore.setPendingExportState(projectID: project.id, pending: true)
                project = updated
                onProjectChanged(updated)
                projectExportStatus = "Saving to Photos…"
                try await photoLibrarySaver.saveVideo(at: url)
                completeProjectExportPhotosSave()
                finishProjectExport()
                haptic(.success)
            } catch let error as ProjectExportError where error == .cancelled {
                finishProjectExport()
            } catch is CancellationError {
                finishProjectExport()
            } catch {
                let exportIsReady = FileManager.default.fileExists(atPath: outputURL.path)
                finishProjectExport()
                errorMessage = exportIsReady
                    ? "The finished video is safe in this Project, but it couldn't be added to Photos."
                    : "The Project couldn't be combined. Every Take is still safe."
                logger.error("Project export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func saveProjectExportToPhotos(_ url: URL) {
        errorMessage = nil
        isExportingProject = true
        projectExportStatus = "Saving to Photos…"
        setIdleTimerDisabled(true)
        projectExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await photoLibrarySaver.saveVideo(at: url)
                completeProjectExportPhotosSave()
                finishProjectExport()
                haptic(.success)
            } catch {
                finishProjectExport()
                errorMessage = "The finished video is still safe in this Project. Camenya couldn't add it to Photos."
            }
        }
    }

    private func finishProjectExport() {
        projectExportProgressTimer?.invalidate()
        projectExportProgressTimer = nil
        isExportingProject = false
        projectExportStatus = nil
        projectExportProgress = 0
        projectExportTask = nil
        setIdleTimerDisabled(false)
    }

    private func completeProjectExportPhotosSave() {
        do {
            try projectStore.recordPhotosSaveCompleted(projectID: project.id)
            try projectStore.removePendingExport(projectID: project.id)
            let updated = try projectStore.setPendingExportState(projectID: project.id, pending: false)
            project = updated
            onProjectChanged(updated)
        } catch {
            logger.warning("Photos save succeeded; durable cleanup will resume on launch: \(error.localizedDescription, privacy: .public)")
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

    private func handleCaptureInterruption(reason: String) {
        interruptActiveTake(reason: "Capture session interruption \(reason)")
        presentCaptureSessionFailure("Camera unavailable. Your recorded segments are safe.")
    }

    private func handleRuntimeError(_ error: Error) {
        interruptActiveTake(reason: error.localizedDescription)
        presentCaptureSessionFailure("The camera stopped unexpectedly. Your recorded segments are safe.")
    }

    private func presentCaptureSessionFailure(_ message: String) {
        let alert = cameraRecoveryAlertState.presentCaptureSessionFailure(message)
        presentedCameraAlertID = alert.id
        isPublishingCameraAlert = true
        errorMessage = alert.message
        isPublishingCameraAlert = false
    }

    private func restartCaptureSession() {
        let recoveryAttempt = cameraRecoveryAlertState.beginRecoveryAttempt()
        cameraController.startSession { [weak self] isUsable in
            guard let self, isUsable else { return }
            guard self.cameraRecoveryAlertState.recoveredAlert(
                recoveryAttempt,
                ifPresentedAlertID: self.presentedCameraAlertID
            ) != nil else { return }
            self.presentedCameraAlertID = nil
            self.errorMessage = nil
            self.logger.info("Capture session is running after lifecycle recovery")
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
