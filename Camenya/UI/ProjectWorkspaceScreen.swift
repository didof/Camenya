import SwiftUI

struct ProjectWorkspaceScreen: View {
    @StateObject private var recorder: AppModel
    @ObservedObject private var library: ProjectLibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var destination: ProjectDestination
    @State private var hasWorkspaceContext: Bool
    @State private var renaming = false
    @State private var draftName: String
    @State private var editingNote = false
    @State private var showingProjectMedia = false
    @State private var isEditingStoryline = false
    @State private var playbackContext = TimelinePlaybackContext.beginning
    @State private var confirmingDeletion = false
    @State private var showingCaptionSetup = false
    @State private var showingCaptionEditor = false
    @State private var showingTextOverlayEditor = false
    @State private var confirmingUnlock = false
    @State private var choosingExportVariant = false
    @State private var openCaptionEditorAfterSetup = false
    @State private var finishVideoAfterStorylineReview = false
    @State private var failedWorkspaceCaptionAction: WorkspaceCaptionAction?

    private enum WorkspaceCaptionAction {
        case unlock
        case resumeGeneration
    }

    init(
        project: ProjectManifest,
        library: ProjectLibraryModel,
        initialDestination: ProjectDestination
    ) {
        _recorder = StateObject(wrappedValue: AppModel(
            project: project,
            projectStore: library.store,
            onProjectChanged: { library.upsertAndSort($0) }
        ))
        self.library = library
        _destination = State(initialValue: initialDestination)
        _hasWorkspaceContext = State(initialValue: initialDestination == .workspace)
        _draftName = State(initialValue: project.name)
    }

    var body: some View {
        ZStack {
            workspaceSurface
                .opacity(destination == .workspace ? 1 : 0)
                .allowsHitTesting(destination == .workspace)
                .accessibilityHidden(destination != .workspace)

            if destination == .capture {
                CameraScreen(
                    model: recorder,
                    onBack: captureBack,
                    onCaptureEnded: captureEnded
                )
                .transition(.opacity)
            }

            if destination == .workspace,
               workspaceCaptionErrorMessage != nil || recorder.projectExportErrorMessage != nil {
                VStack {
                    if workspaceCaptionErrorMessage != nil {
                        workspaceCaptionError
                    }
                    if let message = recorder.projectExportErrorMessage {
                        workspaceExportError(message)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(destination == .capture ? .hidden : .visible, for: .navigationBar)
        .toolbar { workspaceToolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if recorder.isExportingProject, destination == .workspace {
                exportProgressBar
            }
        }
        .onAppear {
            if destination == .capture { recorder.enterCapture() }
            else { recorder.resumeProjectCaptionGeneration() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard destination == .workspace else { return }
            recorder.handleWorkspaceScenePhase(newPhase)
        }
        .sheet(isPresented: $editingNote) {
            ProjectNoteEditor(
                note: recorder.projectNote,
                saveErrorMessage: recorder.projectNoteSaveErrorMessage,
                canRetry: recorder.canRetryProjectNoteSave,
                onRetry: recorder.retryProjectNoteSave
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingProjectMedia) {
            NavigationStack {
                ProjectMediaScreen(
                    model: recorder
                )
            }
        }
        .sheet(item: Binding(
            get: { recorder.shareableProjectExport },
            set: { if $0 == nil { recorder.projectExportSharingFinished(completed: false) } }
        )) { item in
            SystemShareSheet(url: item.url) { completed in
                recorder.projectExportSharingFinished(completed: completed)
            }
        }
        .sheet(isPresented: $showingCaptionSetup, onDismiss: {
            if openCaptionEditorAfterSetup {
                openCaptionEditorAfterSetup = false
                showingCaptionEditor = true
            }
        }) {
            ProjectCaptionSetupSheet(model: recorder) {
                openCaptionEditorAfterSetup = true
            }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingCaptionEditor) {
            if let snapshot = recorder.timelinePlaybackSnapshot {
                ProjectCaptionEditorScreen(
                    model: recorder,
                    snapshot: snapshot,
                    initialProjectTime: playbackContext.projectTime,
                    onDone: { projectTime in
                        playbackContext = TimelinePlaybackContext(
                            selectedClipID: recorder.timelinePlaybackSnapshot?.position(at: projectTime)?.clipID,
                            projectTime: projectTime
                        )
                        showingCaptionEditor = false
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $showingTextOverlayEditor) {
            if let snapshot = recorder.timelinePlaybackSnapshot {
                ProjectTextOverlayEditorScreen(
                    model: recorder,
                    snapshot: snapshot,
                    initialProjectTime: playbackContext.projectTime,
                    onDone: { projectTime in
                        playbackContext = TimelinePlaybackContext(
                            selectedClipID: recorder.timelinePlaybackSnapshot?.position(at: projectTime)?.clipID,
                            projectTime: projectTime
                        )
                        showingTextOverlayEditor = false
                    }
                )
            }
        }
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Project name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { recorder.renameProject(to: draftName) }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Delete Project?",
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive, action: deleteProject)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the Project and every recording and file it owns. This can't be undone.")
        }
        .confirmationDialog(
            "Edit Video?",
            isPresented: $confirmingUnlock,
            titleVisibility: .visible
        ) {
            Button(
                unlockPresentation.actionTitle,
                role: .destructive
            ) {
                attemptUnlock()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(unlockPresentation.message)
        }
        .confirmationDialog(
            "Export Project",
            isPresented: $choosingExportVariant,
            titleVisibility: .visible
        ) {
            Button("With Captions") { recorder.exportProject(includeCaptions: true) }
            Button("Without Captions") { recorder.exportProject(includeCaptions: false) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Camenya", isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.dismissError() } }
        )) {
            if recorder.canOpenSettingsForCurrentError {
                Button("Open Settings") { recorder.openSettings() }
            }
            Button("OK", role: .cancel) { recorder.dismissError() }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        if destination == .workspace, !isEditingStoryline {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: closeProject) {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Back to Projects")
                .disabled(!recorder.canLeaveProject)
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if recorder.timelinePlaybackSnapshot?.clips.isEmpty == false {
                    if recorder.hasPhotosConfirmedPictureLock {
                        Button {
                            showingTextOverlayEditor = true
                        } label: {
                            Image(systemName: "textformat")
                        }
                        .accessibilityLabel("Text Overlays")
                        .accessibilityHint("Add and time text on the finished video")
                        .disabled(recorder.isExportingProject || recorder.isTranscribingCaptions)
                    }

                    Button(action: performCaptionWorkspaceAction) {
                        ZStack {
                            Image(systemName: captionToolbarSymbol)
                            if recorder.isTranscribingCaptions, recorder.isPictureLocked {
                                ProgressView()
                                    .controlSize(.mini)
                                    .offset(x: 9, y: -9)
                            }
                        }
                    }
                    .accessibilityLabel(captionToolbarLabel)
                    .accessibilityHint(captionToolbarHint)
                    .disabled(recorder.isExportingProject)

                    Button("Edit") {
                        finishVideoAfterStorylineReview = false
                        if recorder.isPictureLocked { confirmingUnlock = true }
                        else { isEditingStoryline = true }
                    }
                    .accessibilityLabel(recorder.isPictureLocked ? "Edit Video" : "Edit Storyline")
                    .disabled(recorder.isExportingProject)
                }
                Button {
                    if recorder.hasCompletedProjectCaptions {
                        choosingExportVariant = true
                    } else {
                        recorder.exportProject(includeCaptions: false)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!recorder.canExportProject)
                .accessibilityLabel("Share Project")
                .accessibilityHint(!recorder.hasPhotosConfirmedPictureLock
                    ? "Finish Video before sharing"
                    : recorder.isTranscribingCaptions
                        ? "Wait for caption generation to finish"
                        : "Choose a finished video to share")

                Menu {
                    Button("Rename", systemImage: "pencil") {
                        draftName = recorder.project.name
                        renaming = true
                    }
                    Button("Project Note", systemImage: "note.text") {
                        editingNote = true
                    }
                    Button("Project Media", systemImage: "rectangle.stack") {
                        showingProjectMedia = true
                    }
                    Divider()
                    Button("Delete Project", systemImage: "trash", role: .destructive) {
                        confirmingDeletion = true
                    }
                } label: {
                    Image(systemName: recorder.isPictureLocked ? "lock.circle" : "ellipsis.circle")
                }
                .accessibilityLabel("Project menu")
                .accessibilityValue(recorder.isPictureLocked ? "Video Locked" : "")
            }
        }
    }

    private var workspaceSurface: some View {
        Group {
            if isEditingStoryline,
               let snapshot = recorder.timelinePlaybackSnapshot {
                TimelineReviewScreen(
                    snapshot: snapshot,
                    title: recorder.project.name,
                    format: recorder.project.format ?? .portrait,
                    model: recorder,
                    initialSelectedClipID: playbackContext.selectedClipID,
                    initialProjectTime: playbackContext.projectTime,
                    presentation: .embedded,
                    onDone: { context in
                        playbackContext = context
                        let shouldFinishVideo = finishVideoAfterStorylineReview
                            && recorder.isReadyForPictureLock
                        finishVideoAfterStorylineReview = false
                        isEditingStoryline = false
                        if shouldFinishVideo { recorder.finishVideo() }
                    }
                )
            } else {
                VStack(spacing: 0) {
                    if let snapshot = recorder.timelinePlaybackSnapshot {
                        ProjectWorkspacePlaybackView(
                            snapshot: snapshot,
                            model: recorder,
                            isActive: destination == .workspace,
                            initialContext: playbackContext,
                            onContextChanged: { playbackContext = $0 },
                            onPrepare: beginCaptionPreparation,
                            onFinish: recorder.finishVideo
                        )
                    } else {
                        ProgressView("Preparing Project…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if !recorder.isPictureLocked {
                        Button(action: beginCapture) {
                            Label("New Take", systemImage: "plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .disabled(!recorder.canLeaveProject)
                    } else if recorder.hasPhotosConfirmedPictureLock {
                        HStack(spacing: 12) {
                            Button(action: performCaptionWorkspaceAction) {
                                Label(
                                    recorder.projectCaptionTrack == nil ? "Captions" : "Edit Captions",
                                    systemImage: "captions.bubble"
                                )
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            Button {
                                showingTextOverlayEditor = true
                            } label: {
                                Label("Text", systemImage: "textformat")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .disabled(recorder.isExportingProject || recorder.isTranscribingCaptions)
                    } else {
                        Button(action: recorder.finishVideo) {
                            Label("Finish Video", systemImage: "checkmark.seal")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .disabled(recorder.isExportingProject)
                        .accessibilityHint(
                            "Create, validate, and save a Clean Master before using finishing tools"
                        )
                    }
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var exportProgressBar: some View {
        HStack(spacing: 12) {
            ProgressView(value: recorder.projectExportProgress)
                .frame(width: 72)
            Text(recorder.projectExportStatus ?? "Preparing Project Export…")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            if recorder.projectExportCanCancel {
                Button("Cancel") { recorder.cancelProjectExport() }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recorder.projectExportStatus ?? "Preparing Project Export")
    }

    private func workspaceExportError(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if recorder.cleanMasterPhotosSaveNeedsResolution {
                Menu("Resolve") {
                    Button("I See It in Photos") {
                        recorder.confirmCleanMasterIsSavedToPhotos()
                    }
                    Button("Save Again") {
                        recorder.saveCleanMasterToPhotosAgain()
                    }
                }
                .font(.footnote.weight(.semibold))
                .accessibilityHint("Choose after checking whether the Clean Master is in Photos")
            } else if recorder.hasFailedProjectExportRetry {
                Button("Retry") { recorder.retryFailedProjectExport() }
                    .font(.footnote.weight(.semibold))
                    .disabled(recorder.isTranscribingCaptions)
                    .accessibilityHint(recorder.isTranscribingCaptions
                        ? "Wait for caption generation to finish"
                        : "Retry the same export operation")
            }
            Button {
                recorder.dismissProjectExportError()
            } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss export error")
        }
        .padding(12)
        .background(.bar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func beginCapture() {
        destination = .capture
        recorder.enterCapture()
    }

    private var captionWorkspaceAction: ProjectCaptionWorkspaceAction {
        ProjectPresentationPolicy.captionWorkspaceAction(
            isPictureLocked: recorder.isPictureLocked,
            hasPhotosConfirmedPictureLock: recorder.hasPhotosConfirmedPictureLock,
            isReadyForPictureLock: recorder.isReadyForPictureLock,
            hasCaptionTrack: recorder.projectCaptionTrack != nil
        )
    }

    private var unlockPresentation: ProjectUnlockPresentation {
        ProjectPresentationPolicy.unlockPresentation(
            hasPhotosConfirmedPictureLock: recorder.hasPhotosConfirmedPictureLock,
            hasCaptionTrack: recorder.projectCaptionTrack != nil,
            hasTextOverlays: !recorder.projectTextOverlays.isEmpty
        )
    }

    private var captionToolbarLabel: String {
        switch captionWorkspaceAction {
        case .reviewVideo: "Review Before Captions"
        case .finishVideo: "Finish Video"
        case .createCaptions: "Create Captions"
        case .openCaptionEditor: "Open Captions"
        }
    }

    private var captionToolbarSymbol: String {
        switch captionWorkspaceAction {
        case .reviewVideo: "checkmark.circle"
        case .finishVideo: "checkmark.seal"
        case .createCaptions, .openCaptionEditor: "captions.bubble"
        }
    }

    private var captionToolbarHint: String {
        switch captionWorkspaceAction {
        case .reviewVideo: "Review and confirm the current video, then create captions."
        case .finishVideo: "Create, validate, and save a clean video before adding finishing text."
        case .createCaptions: "Choose the spoken language for this finished video."
        case .openCaptionEditor: "Review and edit the captions for this locked video."
        }
    }

    private func performCaptionWorkspaceAction() {
        switch captionWorkspaceAction {
        case .reviewVideo:
            beginCaptionPreparation()
        case .finishVideo:
            recorder.finishVideo()
        case .createCaptions:
            showingCaptionSetup = true
        case .openCaptionEditor:
            showingCaptionEditor = true
        }
    }

    private func beginCaptionPreparation() {
        finishVideoAfterStorylineReview = true
        isEditingStoryline = true
    }

    private var workspaceCaptionErrorMessage: String? {
        guard failedWorkspaceCaptionAction != nil
                || (recorder.projectCaptionTrack?.isGenerationComplete == false
                    && !recorder.isTranscribingCaptions) else { return nil }
        return recorder.captionGenerationErrorMessage
    }

    private var workspaceCaptionError: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(workspaceCaptionErrorMessage ?? "Caption operation failed.")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                switch failedWorkspaceCaptionAction ?? .resumeGeneration {
                case .unlock: attemptUnlock()
                case .resumeGeneration: recorder.resumeProjectCaptionGeneration()
                }
            }
            .font(.footnote.weight(.semibold))
            Button {
                failedWorkspaceCaptionAction = nil
                recorder.dismissCaptionGenerationError()
            } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss caption error")
        }
        .padding(.leading, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func attemptUnlock() {
        if recorder.unlockPictureLock() {
            failedWorkspaceCaptionAction = nil
            isEditingStoryline = true
        } else {
            failedWorkspaceCaptionAction = .unlock
        }
    }

    private func captureBack() {
        recorder.leaveCapture {
            if hasWorkspaceContext {
                destination = .workspace
            } else {
                library.projectDidClose(id: recorder.project.id)
                dismiss()
            }
        }
    }

    private func captureEnded(_ take: ProjectTake?) {
        recorder.leaveCapture {
            if take != nil || hasWorkspaceContext {
                hasWorkspaceContext = true
                destination = .workspace
            } else {
                library.projectDidClose(id: recorder.project.id)
                dismiss()
            }
        }
    }

    private func closeProject() {
        recorder.leaveProject {
            library.projectDidClose(id: recorder.project.id)
            dismiss()
        }
    }

    private func deleteProject() {
        recorder.leaveProject {
            library.deleteProject(id: recorder.project.id)
            dismiss()
        }
    }

}

private struct ProjectWorkspacePlaybackView: View {
    @StateObject private var playback: TimelinePlaybackSession
    @ObservedObject var model: AppModel
    let snapshot: ExportSnapshot
    let isActive: Bool
    let onContextChanged: (TimelinePlaybackContext) -> Void
    let onPrepare: () -> Void
    let onFinish: () -> Void
    @State private var controlsVisible = true
    @State private var controlsRevealStartedAt: TimeInterval?

    init(
        snapshot: ExportSnapshot,
        model: AppModel,
        isActive: Bool,
        initialContext: TimelinePlaybackContext,
        onContextChanged: @escaping (TimelinePlaybackContext) -> Void,
        onPrepare: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        _playback = StateObject(wrappedValue: TimelinePlaybackSession(
            snapshot: snapshot,
            initialSelectedClipID: initialContext.selectedClipID,
            initialProjectTime: initialContext.projectTime
        ))
        self.snapshot = snapshot
        self.model = model
        self.isActive = isActive
        self.onContextChanged = onContextChanged
        self.onPrepare = onPrepare
        self.onFinish = onFinish
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    if playback.state.phase == .empty {
                        emptyStoryline
                    } else {
                        viewer(maximumHeight: geometry.size.height * 0.56)
                        storylineOverview
                        selectionSummary
                    }

                    if model.needsStorylineCheck, !model.isPictureLocked {
                        Button(action: onPrepare) {
                            HStack(spacing: 10) {
                                Image(systemName: "captions.bubble")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Review Before Captions")
                                    Text("Confirm this edit before generating text.")
                                        .font(.caption)
                                        .fontWeight(.regular)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else if model.isReadyForPictureLock, !model.isPictureLocked {
                        Button(action: onFinish) {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.seal")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Finish Video")
                                    Text("Validate and save the Clean Master before adding text.")
                                        .font(.caption)
                                        .fontWeight(.regular)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .disabled(model.isExportingProject)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .onChange(of: snapshot) { _, newSnapshot in
            playback.replaceSnapshot(
                newSnapshot,
                selectedClipID: playback.state.selectedClipID,
                projectTime: playback.state.playhead
            )
        }
        .onChange(of: isActive) { _, active in
            if !active { playback.send(.pause) }
        }
        .onChange(of: playback.state.playhead) {
            onContextChanged(TimelinePlaybackContext(
                selectedClipID: playback.state.selectedClipID,
                projectTime: playback.state.playhead
            ))
            guard ProjectPresentationPolicy.shouldHideViewerControls(
                isPlaying: playback.state.isPlaying,
                revealStartedAt: controlsRevealStartedAt,
                now: ProcessInfo.processInfo.systemUptime
            ) else { return }
            controlsVisible = false
            controlsRevealStartedAt = nil
        }
        .onChange(of: playback.state.selectedClipID) {
            onContextChanged(TimelinePlaybackContext(
                selectedClipID: playback.state.selectedClipID,
                projectTime: playback.state.playhead
            ))
        }
        .onDisappear { playback.send(.pause) }
        .sensoryFeedback(.selection, trigger: playback.state.selectedClipID)
    }

    private func viewer(maximumHeight: CGFloat) -> some View {
        ZStack {
            PlayerLayerView(player: playback.player)
                .background(.black)

            if let finishing = snapshot.finishingTimeline {
                ForEach(finishing.activeTextOverlays(at: playback.state.playhead.seconds)) { overlay in
                    TextOverlayLayerPreview(overlay: overlay)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let captions = finishing.captions,
                   let active = ProjectCaptionOverlayResolver.active(
                        in: captions,
                        at: playback.state.playhead.seconds
                   ) {
                    CaptionLayerPreview(
                        cue: active.cue,
                        configuration: ProjectCaptionConfiguration(
                            localeIdentifier: "und",
                            placement: captions.placement,
                            style: captions.style,
                            customization: captions.customization
                        ),
                        activeTime: playback.state.playhead.seconds
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }

            if playback.state.phase == .preparing {
                ProgressView()
                    .padding(16)
                    .background(.regularMaterial, in: Circle())
            } else if controlsVisible || !playback.state.isPlaying {
                Button(action: performViewerPrimaryAction) {
                    Image(systemName: viewerPrimaryAction == .retryPreparation
                        ? "arrow.clockwise"
                        : (playback.state.isPlaying ? "pause.fill" : "play.fill"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 58, height: 58)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel(viewerPrimaryAction == .retryPreparation
                    ? "Retry Preview"
                    : (playback.state.isPlaying ? "Pause" : "Play"))
            }
        }
        .aspectRatio(model.project.format == .landscape ? 16 / 9 : 9 / 16, contentMode: .fit)
        .frame(maxHeight: max(220, maximumHeight))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if playback.state.isPlaying, !controlsVisible {
                controlsVisible = true
                controlsRevealStartedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project Viewer")
    }

    private var storylineOverview: some View {
        TimelineFilmstrip(
            playback: playback,
            format: model.project.format ?? .portrait,
            isCommitting: false,
            preparationIssueCount: model.preparationIssueCount(for:)
        )
        .frame(height: 72)
    }

    private var selectionSummary: some View {
        HStack {
            if let ordinal = playback.state.selectedClipOrdinal,
               let clip = playback.state.selectedClip {
                Text("Clip \(ordinal) of \(playback.state.clipCount) · \(RecordingDurationFormatter.clock(clip.duration))")
            }
            Spacer()
            Text(RecordingDurationFormatter.clock(playback.state.duration.seconds))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var emptyStoryline: some View {
        ContentUnavailableView {
            Label("No Takes Yet", systemImage: "film.stack")
        } description: {
            Text("Record a Take to start this Storyline.")
        }
        .frame(minHeight: 320)
    }

    private var viewerPrimaryAction: ProjectViewerPrimaryAction {
        ProjectPresentationPolicy.viewerPrimaryAction(
            isPreparationFailed: playback.state.phase == .failed
        )
    }

    private func performViewerPrimaryAction() {
        if viewerPrimaryAction == .retryPreparation {
            playback.send(.retryPreparation)
            controlsVisible = true
            controlsRevealStartedAt = nil
        } else {
            playback.send(.togglePlayback)
            controlsVisible = !playback.state.isPlaying
            controlsRevealStartedAt = nil
        }
    }
}

struct ProjectMediaEditFailure: Equatable, Sendable {
    let edit: TimelineEdit

    var retryEdit: TimelineEdit { edit }
}

private struct ProjectMediaScreen: View {
    private struct Preview: Identifiable {
        let take: ProjectTake
        let title: String
        var id: UUID { take.id }
    }

    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var preview: Preview?
    @State private var deletingTake: ProjectTake?
    @State private var deleteError: String?
    @State private var editFailure: ProjectMediaEditFailure?
    @State private var isCommittingEdit = false

    var body: some View {
        List {
            if !model.project.removedClips.isEmpty {
                Section("Removed Clips") {
                    ForEach(model.project.removedClips) { removed in
                        if let take = take(for: removed.clip.takeID) {
                            mediaRow(
                                take: take,
                                title: "Removed Clip",
                                duration: removed.clip.selection.duration
                            )
                            .contextMenu {
                                previewButton(take, title: "Removed Clip")
                                Button("Restore Clip", systemImage: "arrow.uturn.backward") {
                                    performTimelineEdit(.restore(clipID: removed.id))
                                }
                                .disabled(isCommittingEdit)
                            }
                        }
                    }
                }
            }

            if !model.project.unusedTakes.isEmpty {
                Section("Unused Takes") {
                    ForEach(model.project.unusedTakes) { take in
                        mediaRow(take: take, title: "Unused Take", duration: take.duration)
                            .contextMenu {
                                previewButton(take, title: "Unused Take")
                                Button("Add to Storyline", systemImage: "plus.rectangle.on.rectangle") {
                                    performTimelineEdit(.addFullTakeToStoryline(takeID: take.id))
                                }
                                .disabled(isCommittingEdit)
                                Button("Delete Take", systemImage: "trash", role: .destructive) {
                                    deletingTake = take
                                }
                            }
                    }
                }
            }

            if !usedTakes.isEmpty {
                Section("Used Takes") {
                    ForEach(usedTakes) { take in
                        mediaRow(take: take, title: "Used Take", duration: take.duration)
                            .contextMenu {
                                previewButton(take, title: "Used Take")
                                if ProjectPresentationPolicy.canAddFullTakeToStoryline(
                                    takeID: take.id,
                                    in: model.project
                                ) {
                                    Button(
                                        "Add Full Take to Storyline",
                                        systemImage: "plus.rectangle.on.rectangle"
                                    ) {
                                        performTimelineEdit(.addFullTakeToStoryline(takeID: take.id))
                                    }
                                    .disabled(isCommittingEdit)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Project Media")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let editFailure {
                editFailureBar(editFailure)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .disabled(isCommittingEdit)
            }
        }
        .sheet(item: $preview) { preview in
            TakeReviewScreen(
                url: model.movieURL(for: preview.take),
                title: preview.title,
                format: model.project.format ?? .portrait
            )
        }
        .confirmationDialog(
            "Delete Take?",
            isPresented: Binding(
                get: { deletingTake != nil },
                set: { if !$0 { deletingTake = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deletingTake {
                Button("Delete Take", role: .destructive) {
                    delete(deletingTake)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the unreferenced Take and its source media.")
        }
        .alert("Take Not Deleted", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "The Take is unchanged.")
        }
    }

    private var usedTakes: [ProjectTake] {
        model.project.usedTakes
    }

    private func take(for id: UUID) -> ProjectTake? {
        model.project.takes.first { $0.id == id }
    }

    private func mediaRow(
        take: ProjectTake,
        title: String,
        duration: TimeInterval
    ) -> some View {
        Button {
            preview = Preview(take: take, title: title)
        } label: {
            HStack(spacing: 12) {
                TakeThumbnailView(
                    url: model.thumbnailURL(for: take),
                    placeholderSystemName: "film",
                    cornerRadius: 9
                )
                .frame(width: 54, height: 72)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(RecordingDurationFormatter.clock(duration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Previews this media. More actions are available from the context menu.")
    }

    private func previewButton(_ take: ProjectTake, title: String) -> some View {
        Button("Preview", systemImage: "play") {
            preview = Preview(take: take, title: title)
        }
    }

    private func editFailureBar(_ failure: ProjectMediaEditFailure) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text("The Storyline couldn't be updated. Your media is unchanged.")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                performTimelineEdit(failure.retryEdit)
            }
            .font(.footnote.weight(.semibold))
            .frame(minHeight: 44)
            .disabled(isCommittingEdit)
            Button {
                editFailure = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Storyline error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private func performTimelineEdit(_ edit: TimelineEdit) {
        guard !isCommittingEdit else { return }
        guard let snapshot = model.timelinePlaybackSnapshot else {
            editFailure = ProjectMediaEditFailure(edit: edit)
            return
        }
        isCommittingEdit = true
        editFailure = nil
        Task { @MainActor in
            defer { isCommittingEdit = false }
            do {
                _ = try await model.performTimelineEdit(
                    edit,
                    expectedRevision: snapshot.revision
                )
            } catch {
                editFailure = ProjectMediaEditFailure(edit: edit)
            }
        }
    }

    private func delete(_ take: ProjectTake) {
        deletingTake = nil
        Task {
            do {
                try await model.deleteUnusedTakePermanently(take.id)
            } catch {
                deleteError = "The Take couldn't be deleted. Its media is unchanged."
            }
        }
    }
}
