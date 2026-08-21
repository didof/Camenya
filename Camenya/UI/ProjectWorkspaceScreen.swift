import SwiftUI

struct ProjectWorkspaceScreen: View {
    @StateObject private var recorder: AppModel
    @ObservedObject private var library: ProjectLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var destination: ProjectDestination
    @State private var hasWorkspaceContext: Bool
    @State private var renaming = false
    @State private var draftName: String
    @State private var editingNote = false
    @State private var showingProjectMedia = false
    @State private var isEditingStoryline = false
    @State private var playbackContext = TimelinePlaybackContext.beginning
    @State private var confirmingDeletion = false

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

            if recorder.isExportingProject {
                exportOverlay
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(destination == .capture ? .hidden : .visible, for: .navigationBar)
        .toolbar { workspaceToolbar }
        .onAppear {
            if destination == .capture { recorder.enterCapture() }
        }
        .sheet(isPresented: $editingNote) {
            ProjectNoteEditor(text: Binding(
                get: { recorder.projectNote.text },
                set: { recorder.projectNote.text = $0 }
            ), saveErrorMessage: recorder.projectNoteSaveErrorMessage,
            canRetry: recorder.canRetryProjectNoteSave,
            onRetry: recorder.retryProjectNoteSave)
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
        .alert("Camenya", isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.dismissError() } }
        )) {
            if recorder.canRetryProjectExportSave {
                Button("Retry Photos Save") { recorder.retryProjectExportSave() }
            }
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

            ToolbarItem(placement: .principal) {
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
                    HStack(spacing: 5) {
                        Text(recorder.project.name)
                            .font(.headline)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                }
                .accessibilityLabel("Project menu for \(recorder.project.name)")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if recorder.timelinePlaybackSnapshot?.clips.isEmpty == false {
                    Button("Edit") { isEditingStoryline = true }
                }
                Button {
                    recorder.exportProject()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(recorder.timelinePlaybackSnapshot?.clips.isEmpty != false)
                .accessibilityLabel("Project Export")
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
                        isEditingStoryline = false
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
                            onPrepare: { isEditingStoryline = true }
                        )
                    } else {
                        ProgressView("Preparing Project…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

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
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var exportOverlay: some View {
        Color.black.opacity(0.22)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 12) {
                    ProgressView(value: recorder.projectExportProgress)
                        .progressViewStyle(.linear)
                    Text(recorder.projectExportStatus ?? "Preparing Project Export…")
                        .font(.callout.weight(.semibold))
                }
                .padding(22)
                .frame(maxWidth: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(recorder.projectExportStatus ?? "Preparing Project Export")
    }

    private func beginCapture() {
        destination = .capture
        recorder.enterCapture()
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
    @State private var controlsVisible = true
    @State private var controlsRevealStartedAt: TimeInterval?

    init(
        snapshot: ExportSnapshot,
        model: AppModel,
        isActive: Bool,
        initialContext: TimelinePlaybackContext,
        onContextChanged: @escaping (TimelinePlaybackContext) -> Void,
        onPrepare: @escaping () -> Void
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

                    if model.preparationItemCount > 0 {
                        Button(action: onPrepare) {
                            HStack(spacing: 10) {
                                Image(systemName: "wand.and.stars")
                                Text("Prepare Project")
                                Spacer()
                                Text("\(model.preparationItemCount)")
                                    .foregroundStyle(.secondary)
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
        GeometryReader { geometry in
            let spacing = CGFloat(max(0, playback.state.clips.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(Array(playback.state.clips.enumerated()), id: \.element.id) { index, clip in
                    let fraction = clip.duration / max(0.001, playback.state.duration.seconds)
                    let preparationIssueCount = model.preparationIssueCount(for: clip)
                    Button {
                        playback.send(.selectClip(clip.id))
                    } label: {
                        TakeThumbnailView(
                            url: clip.thumbnailURL,
                            placeholderSystemName: "film",
                            cornerRadius: 5
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipped()
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(
                                    playback.state.selectedClipID == clip.id
                                        ? Color.accentColor
                                        : Color(uiColor: .separator),
                                    lineWidth: playback.state.selectedClipID == clip.id ? 3 : 0.5
                                )
                        }
                        .overlay(alignment: .topTrailing) {
                            if preparationIssueCount > 0 {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .orange)
                                    .padding(4)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(1, (geometry.size.width - spacing) * fraction))
                    .accessibilityLabel("Clip \(index + 1) of \(playback.state.clipCount)")
                    .accessibilityValue(clipAccessibilityValue(
                        clip,
                        preparationIssueCount: preparationIssueCount
                    ))
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 2).onChanged { value in
                    let fraction = min(max(0, value.location.x / max(1, geometry.size.width)), 1)
                    playback.send(.previewSeek(ProjectTime(
                        seconds: Double(fraction) * playback.state.duration.seconds
                    )))
                }.onEnded { _ in
                    playback.send(.seek(playback.state.playhead))
                }
            )
        }
        .frame(height: 64)
        .accessibilityLabel("Complete Storyline")
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

    private func clipAccessibilityValue(
        _ clip: TimelinePlaybackSession.FilmstripClip,
        preparationIssueCount: Int
    ) -> String {
        var components = [RecordingDurationFormatter.clock(clip.duration)]
        if playback.state.selectedClipID == clip.id { components.append("selected") }
        if preparationIssueCount == 0 {
            components.append("ready")
        } else {
            let noun = preparationIssueCount == 1 ? "item" : "items"
            components.append("\(preparationIssueCount) preparation \(noun)")
        }
        return components.joined(separator: ", ")
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
