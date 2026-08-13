import SwiftUI

struct CameraScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var projectNote: ProjectNoteStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingNote = false
    @State private var reviewingTake: ProjectTake?
    @State private var managingTakes = false
    @State private var reviewingTimeline = false
    @State private var timelineSources: [TimelinePlaybackSource] = []
    @State private var reviewingTrim = false
    @State private var configuringCaptions = false
    @State private var reviewingCaptions = false
    @State private var takeListActionCoordinator = TakeListActionCoordinator()
    let onBack: (() -> Void)?

    init(model: AppModel, onBack: (() -> Void)? = nil) {
        self.model = model
        projectNote = model.projectNote
        self.onBack = onBack
    }

    var body: some View {
        ZStack {
            CamenyaStyle.ink.ignoresSafeArea()
            CameraPreview(controller: model.cameraController).ignoresSafeArea()
            previewScrim
            cameraChrome
                .allowsHitTesting(
                    !model.isExportingProject
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
            if model.isAnalyzingTrim {
                trimAnalysisOverlay
            }
            if model.isTranscribingCaptions {
                captionTranscriptionOverlay
            }
            if model.phase == .idle, let take = model.recoverableTakes.first {
                recoveryOverlay(take)
            }
        }
        .foregroundStyle(CamenyaStyle.paper)
        .statusBarHidden(true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.phase)
        .onChange(of: scenePhase) { _, newPhase in model.handleScenePhase(newPhase) }
        .sheet(isPresented: $editingNote) {
            ProjectNoteEditor(text: $projectNote.text)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $reviewingTake) { take in
            TakeReviewScreen(
                url: model.movieURL(for: take),
                title: "Take \((model.project.takes.firstIndex(of: take) ?? 0) + 1)",
                format: model.project.format ?? .portrait
            )
        }
        .sheet(isPresented: $managingTakes, onDismiss: performPendingTakeListAction) {
            TakeListScreen(model: model) { action in
                takeListActionCoordinator.request(action)
                managingTakes = false
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $reviewingTimeline) {
            TimelineReviewScreen(
                sources: timelineSources,
                title: model.project.name,
                format: model.project.format ?? .portrait
            )
        }
        .sheet(isPresented: $reviewingTrim) {
            TrimReviewQueueScreen(model: model)
        }
        .sheet(isPresented: $configuringCaptions) {
            CaptionSetupScreen(
                existingConfiguration: model.captionConfiguration,
                captionedTakeCount: model.captionedTakeCount,
                totalTakeCount: model.project.takes.count,
                onStart: { configuration in
                    model.createCaptions(configuration: configuration)
                },
                onRegenerateAll: { configuration in
                    model.createCaptions(configuration: configuration, regenerateAll: true)
                }
            )
        }
        .sheet(isPresented: $reviewingCaptions) {
            CaptionReviewQueueScreen(model: model)
        }
        .onChange(of: model.isAnalyzingTrim) { wasAnalyzing, isAnalyzing in
            if wasAnalyzing, !isAnalyzing, !model.trimReviewTakeIDs.isEmpty {
                reviewingTrim = true
            }
        }
        .onChange(of: model.isTranscribingCaptions) { wasTranscribing, isTranscribing in
            if wasTranscribing, !isTranscribing, !model.captionReviewTakeIDs.isEmpty {
                reviewingCaptions = true
            }
        }
        .onChange(of: model.completedTakeForReview) { _, take in
            guard let take else { return }
            reviewingTake = take
            model.consumeCompletedTakeForReview()
        }
        .alert("Camenya", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            if model.canRetrySave {
                Button("Retry Save") { model.retrySave() }
            }
            if model.canRetryProjectExportSave {
                Button("Retry Photos Save") { model.retryProjectExportSave() }
            }
            if model.canOpenSettingsForCurrentError {
                Button("Open Settings") { model.openSettings() }
            }
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func performPendingTakeListAction() {
        guard let action = takeListActionCoordinator.consumeNextAction(
            sheetIsPresented: managingTakes
        ) else { return }
        switch action {
        case .playProject:
            guard let sources = model.timelinePlaybackSources else {
                model.reportInvalidTrimRange()
                return
            }
            timelineSources = sources
            reviewingTimeline = true
        case .analyzeEdges:
            model.cleanUpEdges()
        case .reviewEdges:
            reviewingTrim = true
        case .captionSettings:
            configuringCaptions = true
        case .reviewCaptions:
            if model.prepareCaptionReview() { reviewingCaptions = true }
            else { configuringCaptions = true }
        case let .manageCaptions(takeID):
            if model.prepareCaptionReview(takeID: takeID) { reviewingCaptions = true }
            else { configuringCaptions = true }
        case let .manageEdges(takeID):
            if model.prepareTrimReview(takeID: takeID) {
                reviewingTrim = true
            }
        case .exportProject:
            model.exportProject()
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

    private var cameraChrome: some View {
        VStack(spacing: 16) {
            statusHeader
            Spacer(minLength: 12)
            if model.phase == .paused {
                pausePanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if model.phase == .idle, !model.project.takes.isEmpty {
                timelineShelf
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
                        .frame(width: 38, height: 38)
                        .background(CamenyaStyle.chrome, in: Circle())
                        .overlay(Circle().stroke(CamenyaStyle.hairline, lineWidth: 1))
                }
                .buttonStyle(CameraPressStyle())
                .disabled(!model.canLeaveProject)
                .opacity(model.canLeaveProject ? 1 : 0.4)
                .accessibilityLabel("Back to Projects")
            }
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

            Spacer()

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

    private var timelineShelf: some View {
        Button { managingTakes = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.project.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(model.project.takes.count) \(model.project.takes.count == 1 ? "Take" : "Takes") · \(RecordingDurationFormatter.clock(model.project.approximateDuration))")
                        .font(.caption)
                        .foregroundStyle(CamenyaStyle.muted)
                }
                Spacer(minLength: 8)
                Text("View Takes")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(CameraPressStyle())
        .background(CamenyaStyle.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(CamenyaStyle.hairline, lineWidth: 1))
        .accessibilityLabel("View \(model.project.takes.count) \(model.project.takes.count == 1 ? "Take" : "Takes")")
        .accessibilityValue(RecordingDurationFormatter.clock(model.project.approximateDuration))
        .accessibilityHint("Opens the Take list for review, reordering, and deletion")
        .accessibilityIdentifier("take-list-open")
    }

    private var pausePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(model.isInterrupted ? "Recording interrupted" : "Take paused", systemImage: model.isInterrupted ? "exclamationmark.triangle.fill" : "pause.fill")
                    .font(.headline)
                    .foregroundStyle(model.isInterrupted ? CamenyaStyle.warning : CamenyaStyle.paper)
                Spacer()
                Button { editingNote = true } label: {
                    Label(projectNote.text.isEmpty ? "Add Project Note" : "Edit", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .background(CamenyaStyle.paper.opacity(0.12), in: Capsule())
                .accessibilityHint("Opens the persistent Project Note editor")
            }

            Rectangle()
                .fill(CamenyaStyle.hairline)
                .frame(height: 1)

            ScrollView {
                Text(projectNote.text.isEmpty ? "Add your next line so it is ready before you resume." : projectNote.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.title3.weight(projectNote.text.isEmpty ? .regular : .medium))
                    .foregroundStyle(projectNote.text.isEmpty ? CamenyaStyle.muted : CamenyaStyle.paper)
                    .lineSpacing(4)
            }
            .frame(maxHeight: 190)

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
                    utilityButton("Flip", systemImage: "camera.rotate") { model.flip() }
                    Spacer(minLength: 8)
                    recordButton
                    Spacer(minLength: 8)
                    utilityButton("Project Note", systemImage: projectNote.text.isEmpty ? "text.badge.plus" : "text.alignleft") {
                        editingNote = true
                    }
                }
            case .recording:
                HStack(spacing: 16) {
                    destructiveUtilityButton("Stop", systemImage: "stop.fill", action: model.stop)
                    primaryActionButton("Pause", systemImage: "pause.fill", action: model.pause)
                }
            case .paused where model.isInterrupted:
                interruptedControls
            case .paused:
                HStack(spacing: 10) {
                    utilityButton("Flip", systemImage: "camera.rotate") { model.flip() }
                    destructiveUtilityButton("Stop", systemImage: "stop.fill", action: model.stop)
                    primaryActionButton("Resume", systemImage: "play.fill", action: model.resume)
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
            primaryActionButton("Continue Take", systemImage: "play.fill", action: model.continueInterruptedTake)
                .frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                compactTextButton("Discard", role: .destructive, action: model.discardCurrentTake)
                compactTextButton("Finish Take", action: model.stop)
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
                    Circle()
                        .fill(CamenyaStyle.recording)
                        .frame(width: 58, height: 58)
                }
                Text("Record")
                    .font(.caption.weight(.semibold))
            }
            .frame(minWidth: 82, minHeight: 86)
        }
        .buttonStyle(CameraPressStyle())
        .disabled(!model.captureReady)
        .opacity(model.captureReady ? 1 : 0.45)
        .accessibilityLabel("Record")
        .accessibilityHint("Starts a new Take with the \(model.selectedCamera.rawValue) camera")
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

    private var captionTranscriptionOverlay: some View {
        VStack(spacing: 14) {
            ProgressView(value: model.captionTranscriptionProgress)
                .progressViewStyle(.linear)
                .tint(CamenyaStyle.paper)
            Text(model.captionTranscriptionStatus ?? "Creating captions…")
                .font(.headline)
            Text("Speech recognition stays on this iPhone. Original Takes are never changed.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(CamenyaStyle.muted)
            Button("Cancel Transcription", role: .cancel) { model.cancelCaptionTranscription() }
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

    private func utilityButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 46, height: 42)
                    .background(CamenyaStyle.paper.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(minWidth: 64, minHeight: 68)
        }
        .buttonStyle(CameraPressStyle())
        .accessibilityLabel(title)
    }

    private func destructiveUtilityButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 46, height: 42)
                    .background(CamenyaStyle.recording.opacity(0.16), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(CamenyaStyle.recording)
            .frame(minWidth: 64, minHeight: 68)
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

    private func format(_ duration: TimeInterval) -> String {
        RecordingDurationFormatter.clock(duration)
    }
}

private struct ProjectNoteEditor: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Write the next line, reminder, or cue…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.title3)
                    .lineSpacing(4)
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .accessibilityLabel("Project Note")
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
            .onAppear { isFocused = true }
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
    static let ink = Color(red: 0.035, green: 0.039, blue: 0.051)
    static let paper = Color(red: 0.965, green: 0.965, blue: 0.945)
    static let recording = Color(red: 1, green: 0.27, blue: 0.23)
    static let warning = Color(red: 1, green: 0.78, blue: 0.22)
    static let chrome = ink.opacity(0.84)
    static let panel = ink.opacity(0.94)
    static let muted = paper.opacity(0.68)
    static let hairline = paper.opacity(0.16)
}
