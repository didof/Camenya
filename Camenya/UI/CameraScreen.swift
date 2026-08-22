import SwiftUI

struct CameraScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var projectNote: ProjectNoteStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingNote = false
    @State private var reviewingTake: ProjectTake?
    @State private var confirmingCurrentTakeDiscard = false
    @State private var focusPoint: CGPoint?
    @State private var focusPulse = 0
    @State private var exposureDragStart: Float?
    @State private var isAdjustingExposure = false
    let onBack: (() -> Void)?
    let onCaptureEnded: ((ProjectTake?) -> Void)?

    init(
        model: AppModel,
        onBack: (() -> Void)? = nil,
        onCaptureEnded: ((ProjectTake?) -> Void)? = nil
    ) {
        self.model = model
        projectNote = model.projectNote
        self.onBack = onBack
        self.onCaptureEnded = onCaptureEnded
    }

    var body: some View {
        ZStack {
            CamenyaStyle.ink.ignoresSafeArea()
            Group {
                CameraPreview(controller: model.cameraController)
                    .ignoresSafeArea()
                    .overlay { previewInteractionLayer }
                previewScrim
                focusAndExposureIndicator
                cameraChrome
                    .allowsHitTesting(
                        !model.isExportingProject
                            && !model.isEditingTimeline
                            && !model.isAnalyzingTrim
                            && !model.isTranscribingCaptions
                    )

                if model.phase == .finalizing || (model.phase == .storingTake && !model.canRetrySave) {
                    transitionOverlay
                }
                if model.phase == .configuring {
                    preparingOverlay
                }
                if model.isExportingProject {
                    projectExportOverlay
                }
                if let exportError = model.projectExportErrorMessage,
                   !model.isExportingProject {
                    VStack {
                        Spacer()
                        projectExportErrorBanner(exportError)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 108)
                    }
                }
                if model.isAnalyzingTrim {
                    trimAnalysisOverlay
                }
                if model.phase == .idle, let take = model.recoverableTakes.first {
                    recoveryOverlay(take)
                }
            }
            .allowsHitTesting(!model.isCapturePermissionDenied)
            .accessibilityHidden(model.isCapturePermissionDenied)
            if model.isCapturePermissionDenied {
                permissionUnavailableOverlay
            }
        }
        .foregroundStyle(CamenyaStyle.paper)
        .statusBarHidden(true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.phase)
        .onChange(of: scenePhase) { _, newPhase in model.handleScenePhase(newPhase) }
        .sheet(isPresented: $editingNote) {
            ProjectNoteEditor(
                note: projectNote,
                saveErrorMessage: model.projectNoteSaveErrorMessage,
                canRetry: model.canRetryProjectNoteSave,
                onRetry: model.retryProjectNoteSave
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { model.shareableProjectExport },
            set: { if $0 == nil { model.projectExportSharingFinished(completed: false) } }
        )) { item in
            SystemShareSheet(url: item.url) { completed in
                model.projectExportSharingFinished(completed: completed)
            }
        }
        .sheet(item: $reviewingTake) { take in
            TakeReviewScreen(
                url: model.movieURL(for: take),
                title: "Take \((model.project.takes.firstIndex(of: take) ?? 0) + 1)",
                format: model.project.format ?? .portrait
            )
        }
        .onChange(of: model.completedTakeForReview) { _, take in
            guard let take else { return }
            model.consumeCompletedTakeForReview()
            if let onCaptureEnded {
                onCaptureEnded(take)
            } else {
                reviewingTake = take
            }
        }
        .alert("Camenya", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            if model.canRetrySave {
                Button("Retry Save") { model.retrySave() }
            }
            if model.canOpenSettingsForCurrentError {
                Button("Open Settings") { model.openSettings() }
            }
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete Current Take?",
            isPresented: $confirmingCurrentTakeDiscard,
            titleVisibility: .visible
        ) {
            Button("Delete Current Take", role: .destructive) {
                model.discardCurrentTake()
                onCaptureEnded?(nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All recorded Segments in this Take will be deleted.")
        }
    }

    private var previewInteractionLayer: some View {
        GeometryReader { geometry in
            exposureAccessibilityActions(
                Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                        focus(at: CGPoint(
                            x: value.location.x / geometry.size.width,
                            y: value.location.y / geometry.size.height
                        ))
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12).onChanged { value in
                        guard focusPoint != nil, model.captureReady else { return }
                        if exposureDragStart == nil {
                            exposureDragStart = model.captureCapabilities.exposureBias
                            isAdjustingExposure = true
                        }
                        guard let exposureDragStart else { return }
                        model.setExposureBias(model.exposureBias(
                            from: exposureDragStart,
                            verticalTranslation: Double(value.translation.height)
                        ))
                    }.onEnded { _ in
                        exposureDragStart = nil
                        isAdjustingExposure = false
                    }
                )
                .accessibilityElement()
                .accessibilityLabel("Camera preview")
                .accessibilityHint("Activate to focus and expose at the center.")
                .accessibilityAddTraits(.isImage)
                .accessibilityAction { focus(at: CGPoint(x: 0.5, y: 0.5)) }
            )
        }
    }

    private func focus(at previewPoint: CGPoint) {
        guard model.captureReady else { return }
        let normalizedPoint = CGPoint(
            x: min(max(previewPoint.x, 0), 1),
            y: min(max(previewPoint.y, 0), 1)
        )
        focusPoint = normalizedPoint
        focusPulse += 1
        model.focusAndExpose(atPreviewPoint: normalizedPoint)
    }

    @ViewBuilder
    private func exposureAccessibilityActions<Content: View>(_ content: Content) -> some View {
        if focusPoint == nil {
            content
        } else {
            content
                .accessibilityHint("Swipe up or down to adjust exposure.")
                .accessibilityAdjustableAction { direction in
                    model.adjustExposureBias(by: direction == .increment ? 0.25 : -0.25)
                }
                .accessibilityAction(named: "Reset Exposure") { model.setExposureBias(0) }
        }
    }

    private var previewScrim: some View {
        LinearGradient(
            stops: [
                .init(color: CamenyaStyle.ink.opacity(0.72), location: 0),
                .init(color: .clear, location: 0.28),
                .init(color: .clear, location: 0.56),
                .init(color: CamenyaStyle.ink.opacity(0.88), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var focusAndExposureIndicator: some View {
        if let focusPoint {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(CamenyaStyle.warning, lineWidth: 1.5)
                        .frame(width: 68, height: 68)
                        .phaseAnimator([false, true, false], trigger: focusPulse) { content, visible in
                            content
                                .opacity(visible ? 1 : 0)
                                .scaleEffect(reduceMotion || visible ? 1 : 1.12)
                        } animation: { visible in
                            reduceMotion
                                ? .linear(duration: visible ? 0 : 0.55)
                                : (visible ? .easeOut(duration: 0.16) : .easeIn(duration: 0.55))
                        }

                    if isAdjustingExposure {
                        VStack(spacing: 4) {
                            Image(systemName: "sun.max.fill")
                            Text(model.captureCapabilities.exposureBias, format: .number.precision(.fractionLength(1)))
                                .font(.caption2.monospacedDigit())
                        }
                        .font(.caption)
                        .foregroundStyle(CamenyaStyle.warning)
                        .offset(x: 54)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Exposure bias")
                        .accessibilityValue(Text(
                            model.captureCapabilities.exposureBias,
                            format: .number.precision(.fractionLength(1))
                        ))
                        .accessibilityAdjustableAction { direction in
                            model.adjustExposureBias(by: direction == .increment ? 0.25 : -0.25)
                        }
                        .accessibilityAction(named: "Reset Exposure") {
                            model.setExposureBias(0)
                        }
                    }
                }
                .position(
                    x: focusPoint.x * geometry.size.width,
                    y: focusPoint.y * geometry.size.height
                )
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    private var cameraChrome: some View {
        VStack(spacing: 16) {
            statusHeader
            Spacer(minLength: 12)
            if model.phase == .paused {
                pausePanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let cameraRecoveryMessage = model.cameraRecoveryMessage {
                cameraRecoveryPanel(cameraRecoveryMessage)
            }
            controls
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(CamenyaStyle.chrome, in: Circle())
                        .overlay(Circle().stroke(CamenyaStyle.hairline, lineWidth: 1))
                }
                .buttonStyle(CameraPressStyle())
                .disabled(!model.canLeaveProject)
                .opacity(model.canLeaveProject ? 1 : 0.4)
                .accessibilityLabel("Back to Projects")
            }
            if (model.phase == .idle || model.phase == .paused), model.captureReady {
                captureOptionsMenu
            } else {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusTint)
                        .symbolEffect(.pulse, options: .repeating, isActive: model.phase == .recording && !reduceMotion)
                    Text(statusText.uppercased())
                        .kerning(1.1)
                }
                .font(.caption.weight(.bold))
                .padding(.horizontal, 13)
                .frame(height: 38)
                .background(CamenyaStyle.chrome, in: Capsule())
                .overlay(Capsule().stroke(CamenyaStyle.hairline, lineWidth: 1))
            }

            Spacer()

            if model.captureCapabilities.isLowLightBoostActive {
                Image(systemName: "moon.fill")
                    .font(.caption)
                    .frame(width: 32, height: 32)
                    .background(CamenyaStyle.chrome, in: Circle())
                    .overlay(Circle().stroke(CamenyaStyle.hairline, lineWidth: 1))
                    .accessibilityLabel("Low Light active")
            }

            if showsTimer {
                Text(model.formattedElapsed)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 13)
                    .frame(height: 38)
                    .background(CamenyaStyle.chrome, in: Capsule())
                    .overlay(Capsule().stroke(CamenyaStyle.hairline, lineWidth: 1))
                    .accessibilityLabel("Elapsed time, \(model.formattedElapsed)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var captureOptionsMenu: some View {
        Menu {
            if model.captureCapabilities.supportsSubjectFollowing {
                Toggle(
                    "Follow Subject",
                    isOn: Binding(
                        get: { model.captureQualityPreferences.followSubjectEnabled },
                        set: model.setFollowSubjectEnabled
                    )
                )
            }
            if model.captureCapabilities.supportsLowLightBoost {
                Toggle(
                    "Low Light: Auto",
                    isOn: Binding(
                        get: { model.captureQualityPreferences.lowLightAutoEnabled },
                        set: model.setLowLightAutoEnabled
                    )
                )
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(CamenyaStyle.chrome, in: Circle())
                .overlay(Circle().stroke(CamenyaStyle.hairline, lineWidth: 1))
        }
        .accessibilityLabel("Capture Options")
    }

    private var pausePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(model.isInterrupted ? "Recording interrupted" : "Take paused", systemImage: model.isInterrupted ? "exclamationmark.triangle.fill" : "pause.fill")
                    .font(.headline)
                    .foregroundStyle(model.isInterrupted ? CamenyaStyle.warning : CamenyaStyle.paper)
                Spacer()
            }

            Button { editingNote = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: projectNote.text.isEmpty ? "text.badge.plus" : "text.alignleft")
                    Text(projectNote.text.isEmpty ? "Add Project Note" : projectNote.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(CamenyaStyle.muted)
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(CamenyaStyle.paper.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(CameraPressStyle())
            .accessibilityHint("Opens the persistent Project Note editor")

            if model.isInterrupted {
                Label("Completed segments are safe.", systemImage: "checkmark.shield.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(CamenyaStyle.muted)
            }
        }
        .padding(18)
        .background(CamenyaStyle.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(CamenyaStyle.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var controls: some View {
        Group {
            switch model.phase {
            case .idle:
                HStack(alignment: .center) {
                    roundCameraButton(
                        "Project Note",
                        systemImage: projectNote.text.isEmpty ? "text.badge.plus" : "text.alignleft",
                        kind: .utility
                    ) {
                        editingNote = true
                    }
                    Spacer(minLength: 8)
                    recordButton
                    Spacer(minLength: 8)
                    roundCameraButton("Flip", systemImage: "camera.rotate", kind: .utility) { model.flip() }
                }
            case .recording:
                HStack(spacing: 34) {
                    roundCameraButton("Stop", systemImage: "stop.fill", kind: .destructive, action: model.stop)
                    roundCameraButton("Pause", systemImage: "pause.fill", kind: .primary, action: model.pause)
                }
            case .paused where model.isInterrupted:
                interruptedControls
            case .paused:
                HStack(spacing: 24) {
                    roundCameraButton("Stop", systemImage: "stop.fill", kind: .destructive, action: model.stop)
                    roundCameraButton("Resume", systemImage: "play.fill", kind: .primary, action: model.resume)
                    roundCameraButton("Flip", systemImage: "camera.rotate", kind: .utility) { model.flip() }
                }
            case .storingTake where model.canRetrySave:
                primaryActionButton("Retry Add", systemImage: "arrow.clockwise", action: model.retrySave)
                    .frame(maxWidth: .infinity)
            default:
                HStack(spacing: 10) {
                    ProgressView().tint(CamenyaStyle.paper)
                    Text(transitionText).font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(CamenyaStyle.chrome, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(CamenyaStyle.hairline, lineWidth: 1)
        )
    }

    private var interruptedControls: some View {
        VStack(spacing: 10) {
            if model.captureReady && !model.isRestoringCaptureSession {
                primaryActionButton("Continue Take", systemImage: "play.fill", action: model.continueInterruptedTake)
                    .frame(maxWidth: .infinity)
            } else if model.isRestoringCaptureSession {
                ProgressView()
                    .tint(CamenyaStyle.paper)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Restoring camera")
            }
            HStack(spacing: 10) {
                compactTextButton("Finish Take", action: model.stop)
                if model.captureReady && !model.isRestoringCaptureSession {
                    compactIconButton("Flip", systemImage: "camera.rotate", action: model.flip)
                    Menu {
                        Button("Delete Current Take", systemImage: "trash", role: .destructive) {
                            confirmingCurrentTakeDiscard = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(CamenyaStyle.paper.opacity(0.1), in: Circle())
                    }
                    .accessibilityLabel("More")
                }
            }
        }
    }

    private var recordButton: some View {
        Button(action: model.record) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .stroke(CamenyaStyle.paper, lineWidth: 4)
                        .frame(width: 72, height: 72)
                    if model.isRestoringCaptureSession {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(CamenyaStyle.paper)
                    } else {
                        Circle()
                            .fill(CamenyaStyle.recording)
                            .frame(width: 58, height: 58)
                    }
                }
            }
            .frame(width: 82, height: 82)
        }
        .buttonStyle(CameraPressStyle())
        .disabled(!model.captureReady || model.isRestoringCaptureSession)
        .opacity(model.captureReady || model.isRestoringCaptureSession ? 1 : 0.45)
        .accessibilityLabel("Record")
        .accessibilityHint(
            model.isRestoringCaptureSession
                ? "Wait while the camera reconnects"
                : "Starts a new Take with the \(model.selectedCamera.rawValue) camera"
        )
    }

    private func cameraRecoveryPanel(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.isRestoringCaptureSession {
                ProgressView()
                    .tint(CamenyaStyle.paper)
                    .accessibilityLabel("Retrying camera")
            } else {
                Button(action: model.retryCameraRecovery) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(CameraPressStyle())
                .accessibilityLabel("Retry camera")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(CamenyaStyle.chrome, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(CamenyaStyle.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var preparingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(CamenyaStyle.paper)
            Text("Preparing camera")
                .font(.headline)
        }
        .padding(26)
        .background(CamenyaStyle.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var permissionUnavailableOverlay: some View {
        ZStack {
            CamenyaStyle.ink.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "camera.fill")
                    .font(.largeTitle)
                    .foregroundStyle(CamenyaStyle.muted)
                VStack(spacing: 7) {
                    Text("Camera Access Needed")
                        .font(.title3.weight(.semibold))
                    Text("Allow camera and microphone access to record a Take.")
                        .font(.callout)
                        .foregroundStyle(CamenyaStyle.muted)
                        .multilineTextAlignment(.center)
                }
                Button("Open Settings", action: model.openSettings)
                    .buttonStyle(.borderedProminent)
                if let onBack {
                    Button("Back", action: onBack)
                        .buttonStyle(.bordered)
                }
            }
            .padding(28)
            .frame(maxWidth: 340)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var transitionOverlay: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(CamenyaStyle.paper)
            Text(transitionText).font(.headline)
            Text("Keep Camenya open")
                .font(.footnote)
                .foregroundStyle(CamenyaStyle.muted)
        }
        .padding(26)
        .background(CamenyaStyle.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(CamenyaStyle.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var projectExportOverlay: some View {
        VStack(spacing: 14) {
            if model.projectExportStatus == "Combining Takes…" {
                ProgressView(value: model.projectExportProgress)
                    .progressViewStyle(.linear)
                    .tint(CamenyaStyle.paper)
            } else {
                ProgressView().controlSize(.large).tint(CamenyaStyle.paper)
            }
            Text(model.projectExportStatus ?? "Exporting Project…")
                .font(.headline)
            Text("Keep Camenya open. Every original Take remains safe.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(CamenyaStyle.muted)
            if model.projectExportStatus == "Combining Takes…" {
                Button("Cancel Export", role: .cancel) { model.cancelProjectExport() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(26)
        .frame(maxWidth: 320)
        .background(CamenyaStyle.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(CamenyaStyle.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func projectExportErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { model.dismissProjectExportError() }
                .font(.footnote.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
            if model.cleanMasterPhotosSaveNeedsResolution {
                Menu("Resolve") {
                    Button("I See It in Photos") {
                        model.confirmCleanMasterIsSavedToPhotos()
                    }
                    Button("Save Again") {
                        model.saveCleanMasterToPhotosAgain()
                    }
                }
                .font(.footnote.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Choose after checking whether the Clean Master is in Photos")
            } else if model.hasFailedProjectExportRetry {
                Button("Retry") { model.retryFailedProjectExport() }
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(model.isTranscribingCaptions)
                    .accessibilityHint(model.isTranscribingCaptions
                        ? "Wait for caption generation to finish"
                        : "Retry the same export operation")
            }
        }
        .padding(12)
        .background(CamenyaStyle.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CamenyaStyle.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var trimAnalysisOverlay: some View {
        VStack(spacing: 14) {
            ProgressView(value: model.trimAnalysisProgress)
                .progressViewStyle(.linear)
                .tint(CamenyaStyle.paper)
            Text(model.trimAnalysisStatus ?? "Analyzing Take edges…")
                .font(.headline)
            Text("Analysis stays on this device. Original Takes are never changed.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(CamenyaStyle.muted)
            Button("Cancel Analysis", role: .cancel) { model.cancelTrimAnalysis() }
                .buttonStyle(.bordered)
        }
        .padding(26)
        .frame(maxWidth: 320)
        .background(CamenyaStyle.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(CamenyaStyle.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func recoveryOverlay(_ take: TakeManifest) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(CamenyaStyle.warning)
            VStack(spacing: 7) {
                Text("Finish your last Take")
                    .font(.title2.bold())
                Text("\(take.segments.count) completed segments, \(format(take.approximateDuration)) recorded")
                    .font(.subheadline)
                    .foregroundStyle(CamenyaStyle.muted)
                Text(take.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(CamenyaStyle.muted)
            }
            VStack(spacing: 10) {
                primaryActionButton("Recover Video", systemImage: "checkmark", action: { model.recover(take) })
                    .frame(maxWidth: .infinity)
                Button("Discard Take", role: .destructive) { model.discardRecovery(take) }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(CamenyaStyle.panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(CamenyaStyle.hairline, lineWidth: 1)
        )
        .padding()
    }

    private var showsTimer: Bool {
        model.phase != .idle && model.phase != .configuring
    }

    private var statusText: String {
        switch model.phase {
        case .recording: "Recording"
        case .paused: model.isInterrupted ? "Interrupted" : "Paused"
        case .failed: "Attention"
        default: model.selectedCamera == .front ? "Front camera" : "Rear camera"
        }
    }

    private var statusSymbol: String {
        switch model.phase {
        case .recording: "record.circle.fill"
        case .paused: model.isInterrupted ? "exclamationmark.triangle.fill" : "pause.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        default: model.selectedCamera == .front ? "person.crop.circle" : "mountain.2.fill"
        }
    }

    private var statusTint: Color {
        switch model.phase {
        case .recording, .failed: CamenyaStyle.recording
        case .paused where model.isInterrupted: CamenyaStyle.warning
        default: CamenyaStyle.paper
        }
    }

    private var transitionText: String {
        switch model.phase {
        case .startingSegment: "Starting recording…"
        case .stoppingForPause: "Pausing…"
        case .switchingCamera: "Switching camera…"
        case .resuming: "Resuming…"
        case .stopping: "Stopping…"
        case .finalizing: "Finishing video…"
        case .storingTake: "Adding Take to Project…"
        default: "Working…"
        }
    }

    private func roundCameraButton(
        _ title: String,
        systemImage: String,
        kind: RoundCameraButtonKind,
        action: @escaping () -> Void
    ) -> some View {
        let style = kind.style
        return Button(role: style.role, action: action) {
            Image(systemName: systemImage)
                .font(style.font)
                .foregroundStyle(style.foregroundStyle)
                .frame(width: style.diameter, height: style.diameter)
                .background(style.backgroundStyle, in: Circle())
        }
        .buttonStyle(CameraPressStyle())
        .accessibilityLabel(title)
    }

    private func primaryActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(CamenyaStyle.ink)
                .padding(.horizontal, 20)
                .frame(minWidth: 132, minHeight: 56)
                .background(CamenyaStyle.paper, in: Capsule())
        }
        .buttonStyle(CameraPressStyle())
        .accessibilityLabel(title)
    }

    private func compactTextButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(CamenyaStyle.paper.opacity(0.1), in: Capsule())
        }
        .buttonStyle(CameraPressStyle())
    }

    private func compactIconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(CamenyaStyle.paper.opacity(0.1), in: Circle())
        }
        .buttonStyle(CameraPressStyle())
        .accessibilityLabel(title)
    }

    private func format(_ duration: TimeInterval) -> String {
        RecordingDurationFormatter.clock(duration)
    }
}

private enum RoundCameraButtonKind {
    case utility
    case primary
    case destructive

    struct Style {
        let role: ButtonRole?
        let font: Font
        let foregroundStyle: Color
        let backgroundStyle: Color
        let diameter: CGFloat
    }

    var style: Style {
        switch self {
        case .utility:
            Style(
                role: nil,
                font: .system(size: 20, weight: .semibold),
                foregroundStyle: CamenyaStyle.paper,
                backgroundStyle: CamenyaStyle.paper.opacity(0.12),
                diameter: 52
            )
        case .primary:
            Style(
                role: nil,
                font: .system(size: 22, weight: .bold),
                foregroundStyle: CamenyaStyle.ink,
                backgroundStyle: CamenyaStyle.paper,
                diameter: 68
            )
        case .destructive:
            Style(
                role: .destructive,
                font: .system(size: 18, weight: .bold),
                foregroundStyle: CamenyaStyle.recording,
                backgroundStyle: CamenyaStyle.recording.opacity(0.16),
                diameter: 52
            )
        }
    }
}

struct ProjectNoteEditor: View {
    @ObservedObject var note: ProjectNoteStore
    let saveErrorMessage: String?
    let canRetry: Bool
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        note: ProjectNoteStore,
        saveErrorMessage: String? = nil,
        canRetry: Bool = false,
        onRetry: @escaping () -> Void = {}
    ) {
        self.note = note
        self.saveErrorMessage = saveErrorMessage
        self.canRetry = canRetry
        self.onRetry = onRetry
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let saveErrorMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Text(saveErrorMessage)
                            .font(.footnote)
                        Spacer()
                        if canRetry {
                            Button("Retry", action: onRetry)
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.orange.opacity(0.12))
                }
                ZStack(alignment: .topLeading) {
                    if note.text.isEmpty {
                        Text("Write the next line, reminder, or cue…")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                    ProjectNoteTextView(
                        text: $note.text,
                        navigationState: note.navigationState(for: note.text)
                    ) { navigation in
                        note.rememberNavigation(
                            cursorUTF16Offset: navigation.cursorUTF16Offset,
                            verticalScrollOffset: navigation.verticalScrollOffset
                        )
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .navigationTitle("Project Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct CameraPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

private enum CamenyaStyle {
    static let ink = Color(uiColor: .systemBackground)
    static let paper = Color(uiColor: .label)
    static let recording = Color(uiColor: .systemRed)
    static let warning = Color(uiColor: .systemYellow)
    static let chrome = Color(uiColor: .systemBackground).opacity(0.88)
    static let panel = Color(uiColor: .systemBackground).opacity(0.96)
    static let muted = Color(uiColor: .secondaryLabel)
    static let hairline = Color(uiColor: .separator)
}
