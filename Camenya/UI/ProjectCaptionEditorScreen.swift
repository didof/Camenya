import AVFoundation
import SwiftUI

struct ProjectCaptionSetupSheet: View {
    @ObservedObject var model: AppModel
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var localeIdentifier: String

    init(model: AppModel, onCreated: @escaping () -> Void = {}) {
        self.model = model
        self.onCreated = onCreated
        _localeIdentifier = State(initialValue: model.captionConfiguration?.localeIdentifier
            ?? Locale.current.identifier)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Create Captions")
                        .font(.title2.bold())
                    Text("Choose the Project default. Take overrides below take priority.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Picker("Project Default Language", selection: $localeIdentifier) {
                    ForEach(languageIdentifiers, id: \.self) { identifier in
                        Text(Locale.current.localizedString(forIdentifier: identifier)
                            ?? identifier)
                            .tag(identifier)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if !takeLanguageOverrides.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Take Overrides")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(takeLanguageOverrides.prefix(3)) { item in
                            HStack {
                                Text(item.title)
                                Spacer()
                                Text(languageName(item.identifier))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                        if takeLanguageOverrides.count > 3 {
                            Text("And \(takeLanguageOverrides.count - 3) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Text("Creating captions locks the current edit. Unlocking it later removes generated captions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)

                if let error = model.captionGenerationErrorMessage {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isStaticText)
                }

                Button("Create Captions") {
                    let existing = model.captionConfiguration
                    let created = model.createProjectCaptions(configuration: ProjectCaptionConfiguration(
                        localeIdentifier: localeIdentifier,
                        placement: existing?.placement ?? .lower,
                        style: existing?.style ?? .clean,
                        density: existing?.density ?? .standard,
                        customization: existing?.customization ?? CaptionStyleCustomization()
                    ))
                    if created {
                        onCreated()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            .padding(24)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var languageIdentifiers: [String] {
        ProjectPresentationPolicy.captionLanguageIdentifiers(including: [localeIdentifier])
    }

    private struct TakeLanguageOverride: Identifiable {
        let id: UUID
        let title: String
        let identifier: String
    }

    private var takeLanguageOverrides: [TakeLanguageOverride] {
        let activeTakeIDs = Set(model.project.primaryStoryline.clips.map(\.takeID))
        return model.project.takes.enumerated().compactMap { index, take in
            guard activeTakeIDs.contains(take.id),
                  let identifier = take.spokenLanguageIdentifier else { return nil }
            return TakeLanguageOverride(
                id: take.id,
                title: "Take \(index + 1)",
                identifier: identifier
            )
        }
    }

    private func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

struct ProjectCaptionEditorScreen: View {
    @ObservedObject var model: AppModel
    let onDone: (ProjectTime) -> Void
    @StateObject private var playback: TimelinePlaybackSession
    @State private var editor: ProjectCaptionEditorState
    @State private var persistedCues: [CaptionCue]
    @State private var selectedCueID: UUID?
    @State private var history = CaptionHistoryCoordinator()
    @State private var textEditBaseline: [CaptionCue]?
    @State private var cursorOffset = 0
    @State private var cursorOffsets: [UUID: Int] = [:]
    @State private var showingStyle = false
    @State private var showingLanguages = false
    @State private var timingCueID: UUID?
    @State private var focusedCueID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editorErrorMessage: String?
    @State private var failedEditorAction: FailedEditorAction?

    private enum FailedEditorAction {
        case saveAndClose
        case completeReview
        case cancelGeneration
        case restoreHistory(CaptionHistoryTransition)
    }

    init(
        model: AppModel,
        snapshot: ExportSnapshot,
        initialProjectTime: ProjectTime,
        onDone: @escaping (ProjectTime) -> Void
    ) {
        self.model = model
        self.onDone = onDone
        _playback = StateObject(wrappedValue: TimelinePlaybackSession(
            snapshot: snapshot,
            initialProjectTime: initialProjectTime
        ))
        let cues = model.project.projectCaptionTrack?.cues ?? []
        _editor = State(initialValue: ProjectCaptionEditorState(
            duration: snapshot.duration.seconds,
            cues: cues
        ))
        _persistedCues = State(initialValue: cues)
        _selectedCueID = State(initialValue: cues.first(where: {
            initialProjectTime.seconds >= $0.range.start.seconds
                && initialProjectTime.seconds < $0.range.end.seconds
        })?.id)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if let cueID = timingCueID,
                   let cue = editor.cues.first(where: { $0.id == cueID }) {
                    timingSubmode(cue)
                        .id(cue.id)
                } else {
                    VStack(spacing: 0) {
                        if focusedCueID == nil {
                            viewer(height: max(220, geometry.size.height * 0.39))
                            transport
                        } else if geometry.size.height >= 560 {
                            viewer(height: min(190, geometry.size.height * 0.28))
                        }
                        if let cueID = focusedCueID,
                           let cue = editor.cues.first(where: { $0.id == cueID }) {
                            keyboardEditingSurface(
                                cue,
                                showsNeighboringCaptions: geometry.size.height >= 430
                            )
                        } else {
                            transcript
                        }
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle("Captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if timingCueID == nil { editorToolbar }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if timingCueID == nil { bottomBar }
            }
        }
        .sheet(isPresented: $showingStyle) {
            ProjectCaptionStyleSheet(
                model: model,
                player: playback.player,
                previewCues: editor.cues,
                preferredCueID: selectedCueID
            ) { configuration in
                applyCaptionConfiguration(configuration)
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingLanguages) {
            ProjectCaptionLanguageSheet(model: model) {
                resetEditorForRegeneration()
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: playback.state.playhead) { _, playhead in
            guard playback.state.isPlaying,
                  let active = activeCue(at: playhead.seconds) else { return }
            selectedCueID = active.id
        }
        .onChange(of: focusedCueID) { old, focused in
            if old != nil, old != focused { commitTextEditingHistory() }
            if let focused, old != focused {
                textEditBaseline = editor.cues
                let textLength = editor.cues.first(where: { $0.id == focused })?.text.utf16.count ?? 0
                cursorOffset = cursorOffsets[focused] ?? textLength
                cursorOffsets[focused] = cursorOffset
            }
            if focused != nil { playback.send(.pause) }
        }
        .onChange(of: model.project.projectCaptionTrack?.cues ?? []) { old, new in
            guard new != old else { return }
            if new.isEmpty,
               model.project.projectCaptionTrack?.isGenerationComplete == false {
                resetEditorForRegeneration()
                return
            }
            if editor.cues == persistedCues {
                editor = ProjectCaptionEditorState(duration: editor.duration, cues: new)
            } else {
                var merged = editor.cues
                let known = Set(merged.map(\.id))
                merged.append(contentsOf: new.filter { !known.contains($0.id) })
                editor = ProjectCaptionEditorState(duration: editor.duration, cues: merged)
            }
            persistedCues = new
        }
        .onDisappear { playback.send(.pause) }
    }

    private func viewer(height: CGFloat) -> some View {
        CaptionVideoPreview(
            player: playback.player,
            cue: activeCue(at: playback.state.playhead.seconds),
            configuration: model.captionConfiguration
                ?? ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower),
            activeTime: playback.state.playhead.seconds,
            format: model.project.format ?? .portrait,
            showsSafeRegion: false,
            showsPreparingIndicator: playback.state.phase == .preparing
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Caption preview")
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                playback.send(.togglePlayback)
            } label: {
                Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(playback.state.isPlaying ? "Pause" : "Play")

            Text(RecordingDurationFormatter.clock(playback.state.playhead.seconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { playback.state.playhead.seconds },
                    set: { playback.send(.previewSeek(ProjectTime(seconds: $0))) }
                ),
                in: 0...max(0.001, playback.state.duration.seconds),
                onEditingChanged: { editing in
                    if !editing { playback.send(.seek(playback.state.playhead)) }
                }
            )
            .accessibilityLabel("Project time")

            Text(RecordingDurationFormatter.clock(playback.state.duration.seconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(.bar)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if editor.cues.isEmpty, !model.isTranscribingCaptions {
                        ContentUnavailableView(
                            "No Captions",
                            systemImage: "captions.bubble",
                            description: Text("Add a caption at the current time or retry generation.")
                        )
                        .padding(.top, 44)
                    }
                    ForEach(editor.cues) { cue in
                        captionRow(cue)
                            .id(cue.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: selectedCueID) { _, cueID in
                guard let cueID else { return }
                withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(cueID, anchor: .center) }
            }
        }
    }

    private func keyboardEditingSurface(
        _ cue: CaptionCue,
        showsNeighboringCaptions: Bool
    ) -> some View {
        let index = editor.cues.firstIndex(where: { $0.id == cue.id }) ?? 0
        let previous = index > 0 ? editor.cues[index - 1].text : nil
        let next = editor.cues.indices.contains(index + 1) ? editor.cues[index + 1].text : nil
        return VStack(spacing: 12) {
            if showsNeighboringCaptions, let previous {
                Text(previous)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            CursorAwareCaptionTextView(
                text: cueTextBinding(cue.id),
                cursorOffset: cursorBinding(cue.id),
                isFirstResponder: true,
                onSplit: { splitFocusedCue() },
                onDone: { focusedCueID = nil }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("Caption text")

            if showsNeighboringCaptions, let next {
                Text(next)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }

    private func captionRow(_ cue: CaptionCue) -> some View {
        let selected = cue.id == selectedCueID
        return HStack(alignment: .top, spacing: 10) {
            Text(RecordingDurationFormatter.editingClock(cue.range.start.seconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
                .padding(.top, 4)

            Text(cue.text.isEmpty ? "Empty caption" : cue.text)
                .foregroundStyle(cue.text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    playback.send(.pause)
                    playback.send(.seek(ProjectTime(seconds: cue.range.start.seconds)))
                    if selectedCueID == cue.id, canEditCaptions { focusedCueID = cue.id }
                    selectedCueID = cue.id
                }

            if selected, canEditCaptions {
                Menu {
                    Button("Edit Text", systemImage: "character.cursor.ibeam") {
                        focusedCueID = cue.id
                    }
                    Button("Adjust Timing", systemImage: "timeline.selection") {
                        timingCueID = cue.id
                    }
                    if let splitOffset = splitCursorOffset(for: cue) {
                        Button("Split at Cursor", systemImage: "scissors") {
                            mutate("Split Caption at Cursor") { state in
                                if let selected = state.split(
                                    cueID: cue.id,
                                    characterOffset: splitOffset
                                ) {
                                    selectedCueID = selected
                                }
                            }
                        }
                    }
                    if editor.canMergePrevious(cueID: cue.id) {
                        Button("Merge with Previous", systemImage: "arrow.up.to.line.compact") {
                            mutate("Merge with Previous Caption") { state in
                                selectedCueID = state.merge(cueID: cue.id, withPrevious: true)
                            }
                        }
                    }
                    if editor.canMergeNext(cueID: cue.id) {
                        Button("Merge with Next", systemImage: "arrow.down.to.line.compact") {
                            mutate("Merge with Next Caption") { state in
                                selectedCueID = state.merge(cueID: cue.id, withPrevious: false)
                            }
                        }
                    }
                    if cue.wasEdited || cue.timingWasEdited {
                        Button("Restore Recognized", systemImage: "arrow.uturn.backward") {
                        mutate("Restore Recognized Caption") { $0.restore(cueID: cue.id) }
                        }
                    }
                    Divider()
                    Button("Delete Caption", systemImage: "trash", role: .destructive) {
                        mutate("Delete Caption") { $0.delete(cueID: cue.id) }
                        selectedCueID = nil
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("More actions for caption")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            if cue.confidence.map({ $0 < 0.6 }) == true {
                VStack {
                    Image(systemName: "exclamationmark")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                }
                .frame(width: 18)
                .padding(.vertical, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cue.text.isEmpty ? "Empty caption" : cue.text)
        .accessibilityValue([
            "Starts \(RecordingDurationFormatter.editingClock(cue.range.start.seconds))",
            selected ? "Selected" : nil,
            cue.confidence.map({ $0 < 0.6 }) == true ? "Low confidence" : nil
        ].compactMap { $0 }.joined(separator: ". "))
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { saveAndClose() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                commitTextEditingHistory()
                focusedCueID = nil
                performHistory(isUndo: true)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!CaptionEditorHistoryPolicy.canUndo(
                undoCount: history.undoCount,
                textBaseline: textEditBaseline,
                currentCues: editor.cues
            ))
            .accessibilityLabel("Undo Caption Edit")

            Button {
                commitTextEditingHistory()
                focusedCueID = nil
                performHistory(isUndo: false)
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!CaptionEditorHistoryPolicy.canRedo(
                redoCount: history.redoCount,
                textBaseline: textEditBaseline,
                currentCues: editor.cues
            ))
            .accessibilityLabel("Redo Caption Edit")

            Menu {
                Button("Add Caption", systemImage: "plus") {
                    commitTextEditingHistory()
                    mutate("Add Caption") { state in
                        if let id = state.addCaption(at: playback.state.playhead.seconds) {
                            selectedCueID = id
                            focusedCueID = id
                        }
                    }
                }
                .disabled(!canEditCaptions)

                Button("Caption Style", systemImage: "paintbrush") {
                    commitTextEditingHistory()
                    focusedCueID = nil
                    playback.send(.pause)
                    showingStyle = true
                }

                Button("Spoken Languages", systemImage: "globe") {
                    showingLanguages = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Caption options")
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let editorErrorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(editorErrorMessage).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                if let failedEditorAction {
                    Button("Retry") { retry(failedEditorAction) }
                        .font(.footnote.weight(.semibold))
                }
                Button {
                    self.editorErrorMessage = nil
                    self.failedEditorAction = nil
                } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Dismiss caption error")
            }
            .padding(12)
            .background(.bar)
        } else if model.isTranscribingCaptions, model.isPictureLocked {
            HStack(spacing: 12) {
                ProgressView(value: model.projectCaptionGenerationProgress)
                Text(model.captionTranscriptionStatus ?? "Creating Captions")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") {
                    if model.cancelProjectCaptionGeneration() {
                        onDone(playback.state.playhead)
                    } else {
                        editorErrorMessage = model.captionGenerationErrorMessage
                            ?? "Caption generation couldn't be cancelled."
                        failedEditorAction = .cancelGeneration
                    }
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(.bar)
        } else if let error = model.captionGenerationErrorMessage,
                  model.project.projectCaptionTrack?.isGenerationComplete != true {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(error).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry") { model.resumeProjectCaptionGeneration() }
                    .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(.bar)
        } else if model.project.projectCaptionTrack?.isGenerationComplete == true,
                  model.project.projectCaptionTrack?.reviewState != .approved
                    || editor.cues != persistedCues {
            Button("Complete Review") {
                completeReview(editor.cues)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(.bar)
        }
    }

    private func timingSubmode(_ cue: CaptionCue) -> some View {
        ProjectCaptionTimingSubmode(
            cue: cue,
            playback: playback,
            configuration: model.captionConfiguration
                ?? ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower),
            waveform: model.projectCaptionWaveform,
            projectDuration: editor.duration,
            minimumStart: precedingCue(for: cue.id)?.range.end.seconds ?? 0,
            maximumEnd: followingCue(for: cue.id)?.range.start.seconds ?? editor.duration,
            format: model.project.format ?? .portrait,
            onPreview: { range in
                playback.send(.pause)
                playback.send(.seek(ProjectTime(seconds: range.start.seconds)))
            },
            onPlay: { playback.send(.playRange($0)) },
            onCancel: { timingCueID = nil },
            onCommit: { range in
                mutate("Adjust Caption Timing") {
                    _ = $0.updateRange(cueID: cue.id, range: range)
                }
                timingCueID = nil
            }
        )
    }

    private var canEditCaptions: Bool {
        model.project.projectCaptionTrack?.isGenerationComplete == true
            && !model.isTranscribingCaptions
            && !model.isExportingProject
    }

    private func cueTextBinding(_ cueID: UUID) -> Binding<String> {
        Binding(
            get: { editor.cues.first(where: { $0.id == cueID })?.text ?? "" },
            set: { editor.updateText(cueID: cueID, text: $0) }
        )
    }

    private func cursorBinding(_ cueID: UUID) -> Binding<Int> {
        Binding(
            get: { cursorOffset },
            set: { offset in
                cursorOffset = offset
                cursorOffsets[cueID] = offset
            }
        )
    }

    private func splitCursorOffset(for cue: CaptionCue) -> Int? {
        guard let offset = cursorOffsets[cue.id],
              offset > 0,
              offset < cue.text.utf16.count else { return nil }
        return offset
    }

    private func precedingCue(for cueID: UUID) -> CaptionCue? {
        guard let index = editor.cues.firstIndex(where: { $0.id == cueID }), index > 0 else { return nil }
        return editor.cues[index - 1]
    }

    private func followingCue(for cueID: UUID) -> CaptionCue? {
        guard let index = editor.cues.firstIndex(where: { $0.id == cueID }),
              editor.cues.indices.contains(index + 1) else { return nil }
        return editor.cues[index + 1]
    }

    private func activeCue(at time: TimeInterval) -> CaptionCue? {
        editor.cues.first {
            $0.isEnabled && time >= $0.range.start.seconds && time < $0.range.end.seconds
        }
    }

    private func mutate(
        _ operationName: String,
        _ change: (inout ProjectCaptionEditorState) -> Void
    ) {
        let before = editor.cues
        change(&editor)
        guard editor.cues != before else { return }
        history.record(
            cues: before,
            configuration: currentCaptionConfiguration,
            operationName: operationName
        )
        announceHistory(operationName)
    }

    private func splitFocusedCue() {
        guard let focusedCueID else { return }
        commitTextEditingHistory()
        mutate("Split Caption at Cursor") { state in
            if let selected = state.split(cueID: focusedCueID, characterOffset: cursorOffset) {
                selectedCueID = selected
                self.focusedCueID = selected
            }
        }
    }

    private func commitTextEditingHistory() {
        guard let baseline = textEditBaseline else { return }
        textEditBaseline = nil
        guard baseline != editor.cues else { return }
        history.record(
            cues: baseline,
            configuration: currentCaptionConfiguration,
            operationName: "Edit Caption Text"
        )
        announceHistory("Caption text edited")
    }

    private func announceHistory(_ message: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func saveAndClose() {
        focusedCueID = nil
        commitTextEditingHistory()
        saveAndClose(editor.cues)
    }

    private func saveAndClose(_ cues: [CaptionCue]) {
        guard cues != persistedCues else {
            editorErrorMessage = nil
            failedEditorAction = nil
            onDone(playback.state.playhead)
            return
        }
        guard model.saveProjectCaptionCues(cues) else {
            editorErrorMessage = model.captionGenerationErrorMessage ?? "Caption changes couldn't be saved."
            failedEditorAction = .saveAndClose
            return
        }
        persistedCues = cues
        editorErrorMessage = nil
        failedEditorAction = nil
        onDone(playback.state.playhead)
    }

    private func completeReview(_ cues: [CaptionCue]) {
        guard model.saveProjectCaptionCues(cues), model.completeProjectCaptionReview() else {
            editorErrorMessage = model.captionGenerationErrorMessage ?? "Caption review couldn't be completed."
            failedEditorAction = .completeReview
            return
        }
        persistedCues = cues
        editorErrorMessage = nil
        failedEditorAction = nil
        onDone(playback.state.playhead)
    }

    private func retry(_ action: FailedEditorAction) {
        switch action {
        case .saveAndClose: saveAndClose(editor.cues)
        case .completeReview: completeReview(editor.cues)
        case .cancelGeneration:
            if model.cancelProjectCaptionGeneration() {
                editorErrorMessage = nil
                failedEditorAction = nil
                onDone(playback.state.playhead)
            } else {
                editorErrorMessage = model.captionGenerationErrorMessage
            }
        case let .restoreHistory(transition):
            restoreHistory(transition)
        }
    }

    private func resetEditorForRegeneration() {
        editor = ProjectCaptionEditorState(duration: editor.duration, cues: [])
        persistedCues = []
        selectedCueID = nil
        focusedCueID = nil
        timingCueID = nil
        history.removeAll()
        textEditBaseline = nil
        cursorOffsets.removeAll()
    }

    private func applyCaptionConfiguration(_ configuration: ProjectCaptionConfiguration) -> Bool {
        let densityChanged = configuration.density != model.captionConfiguration?.density
        let baseCues = densityChanged
            ? CaptionDensityReflow.apply(
                configuration.density,
                to: editor.cues,
                regions: model.project.projectCaptionTrack?.regions ?? [],
                configuration: configuration,
                format: model.project.format ?? .portrait
            )
            : editor.cues
        let reflowed = CaptionPresentationComposer.compose(
            baseCues,
            configuration: configuration,
            format: model.project.format ?? .portrait
        )
        let before = editor.cues
        let beforeConfiguration = currentCaptionConfiguration
        guard model.updateProjectCaptionConfiguration(
            configuration,
            reflowedCues: reflowed == before ? nil : reflowed
        ) else { return false }
        if configuration != beforeConfiguration || reflowed != before {
            let operationName: String
            if densityChanged {
                operationName = "Apply Caption Density"
            } else if configuration.placement != beforeConfiguration.placement,
                      configuration.style == beforeConfiguration.style,
                      configuration.customization == beforeConfiguration.customization {
                operationName = "Move Captions"
            } else {
                operationName = "Change Caption Style"
            }
            history.record(
                cues: before,
                configuration: beforeConfiguration,
                operationName: operationName
            )
            if reflowed != before {
                editor = ProjectCaptionEditorState(duration: editor.duration, cues: reflowed)
                persistedCues = reflowed
            }
            announceHistory(operationName)
        }
        return true
    }

    private var currentCaptionConfiguration: ProjectCaptionConfiguration {
        model.captionConfiguration
            ?? ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
    }

    private func performHistory(isUndo: Bool) {
        guard let transition = history.transition(
            isUndo: isUndo,
            currentCues: editor.cues,
            currentConfiguration: currentCaptionConfiguration
        ) else { return }
        restoreHistory(transition)
    }

    private func restoreHistory(_ transition: CaptionHistoryTransition) {
        guard history.canApply(
            transition,
            currentCues: editor.cues,
            currentConfiguration: currentCaptionConfiguration
        ) else {
            editorErrorMessage = "Captions changed after that history action. Undo or Redo again from the current edit."
            failedEditorAction = nil
            return
        }
        let target = transition.target
        if target.configuration != currentCaptionConfiguration {
            guard model.updateProjectCaptionConfiguration(
                target.configuration,
                reflowedCues: target.cues
            ) else {
                editorErrorMessage = model.captionGenerationErrorMessage
                    ?? "The caption history couldn't be restored."
                failedEditorAction = .restoreHistory(transition)
                return
            }
            persistedCues = target.cues
        }
        guard history.commit(transition) else {
            editorErrorMessage = "Caption history changed. Undo or Redo again from the current edit."
            failedEditorAction = nil
            return
        }
        editor = ProjectCaptionEditorState(duration: editor.duration, cues: target.cues)
        editorErrorMessage = nil
        failedEditorAction = nil
        announceHistory(transition.announcement)
    }
}

private struct ProjectCaptionLanguageSheet: View {
    @ObservedObject var model: AppModel
    let onRegenerationStarted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var projectLanguage: String
    @State private var takeOverrides: [UUID: String]
    @State private var confirmingRegeneration = false
    @State private var errorMessage: String?

    init(model: AppModel, onRegenerationStarted: @escaping () -> Void) {
        self.model = model
        self.onRegenerationStarted = onRegenerationStarted
        _projectLanguage = State(initialValue: model.captionConfiguration?.localeIdentifier ?? "en-US")
        _takeOverrides = State(initialValue: Dictionary(uniqueKeysWithValues: model.project.takes.map {
            ($0.id, $0.spokenLanguageIdentifier ?? "")
        }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project Language") {
                    languagePicker("Default", selection: $projectLanguage, includesProjectDefault: false)
                }

                if !lockedTakes.isEmpty {
                    Section {
                        ForEach(Array(lockedTakes.enumerated()), id: \.element.id) { index, take in
                            languagePicker(
                                "Take \(index + 1)",
                                selection: Binding(
                                    get: { takeOverrides[take.id] ?? "" },
                                    set: { takeOverrides[take.id] = $0 }
                                ),
                                includesProjectDefault: true
                            )
                        }
                    } header: {
                        Text("Take Overrides")
                    } footer: {
                        Text("Use a separate Take when the spoken language changes inside the video.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Button("Retry") { regenerate() }
                    }
                }
            }
            .navigationTitle("Spoken Languages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Regenerate") { confirmingRegeneration = true }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Regenerate All Captions?",
                isPresented: $confirmingRegeneration,
                titleVisibility: .visible
            ) {
                Button("Regenerate Captions", role: .destructive) { regenerate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Current caption text, timing, and manual corrections will be replaced. Style and position stay unchanged.")
            }
        }
    }

    private var lockedTakes: [ProjectTake] {
        let ids = Set(model.project.pictureLock?.clips.map(\.takeID) ?? [])
        return model.project.takes.filter { ids.contains($0.id) }
    }

    private func languagePicker(
        _ title: String,
        selection: Binding<String>,
        includesProjectDefault: Bool
    ) -> some View {
        Picker(title, selection: selection) {
            if includesProjectDefault { Text("Project Default").tag("") }
            ForEach(languageIdentifiers, id: \.self) { identifier in
                Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
                    .tag(identifier)
            }
        }
    }

    private func regenerate() {
        if model.regenerateProjectCaptions(
            projectLanguage: projectLanguage,
            takeLanguageOverrides: takeOverrides
        ) {
            errorMessage = nil
            onRegenerationStarted()
            dismiss()
        } else {
            errorMessage = model.captionGenerationErrorMessage
        }
    }

    private var languageIdentifiers: [String] {
        ProjectPresentationPolicy.captionLanguageIdentifiers(
            including: [projectLanguage] + Array(takeOverrides.values)
        )
    }
}

private struct ProjectCaptionOverlay: View {
    let cue: CaptionCue
    let configuration: ProjectCaptionConfiguration
    var activeTime: TimeInterval? = nil

    var body: some View {
        CaptionLayerPreview(
            cue: ProjectCaptionExportCue(
                range: cue.range,
                text: cue.text,
                timedSpans: cue.hasTrustworthyWordTiming ? cue.timedSpans : []
            ),
            configuration: configuration,
            activeTime: activeTime
        )
    }
}

private struct CaptionVideoPreview: View {
    let player: AVPlayer
    let cue: CaptionCue?
    let configuration: ProjectCaptionConfiguration
    let activeTime: TimeInterval?
    let format: ProjectFormat
    var showsSafeRegion = false
    var showsPreparingIndicator = false
    @State private var reportedVideoRect = CGRect.zero

    var body: some View {
        GeometryReader { geometry in
            let videoRect = resolvedVideoRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.black
                PlayerLayerView(player: player) { rect in
                    guard rect.width > 1, rect.height > 1 else { return }
                    reportedVideoRect = rect
                }

                ZStack {
                    if showsSafeRegion {
                        CaptionContentSafeRegionGuide()
                    }
                    if let cue {
                        ProjectCaptionOverlay(
                            cue: cue,
                            configuration: configuration,
                            activeTime: activeTime
                        )
                    }
                }
                .frame(width: videoRect.width, height: videoRect.height)
                .offset(x: videoRect.minX, y: videoRect.minY)
                .allowsHitTesting(false)

                if showsPreparingIndicator {
                    ProgressView()
                        .padding(14)
                        .background(.regularMaterial, in: Circle())
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
        }
        .clipped()
    }

    private func resolvedVideoRect(in size: CGSize) -> CGRect {
        if reportedVideoRect.width > 1,
           reportedVideoRect.height > 1,
           reportedVideoRect.maxX <= size.width + 1,
           reportedVideoRect.maxY <= size.height + 1 {
            return reportedVideoRect
        }
        let aspect = format == .portrait ? (9.0 / 16.0) : (16.0 / 9.0)
        let containerAspect = size.width / max(1, size.height)
        let fittedSize: CGSize
        if containerAspect > aspect {
            fittedSize = CGSize(width: size.height * aspect, height: size.height)
        } else {
            fittedSize = CGSize(width: size.width, height: size.width / aspect)
        }
        return CGRect(
            x: (size.width - fittedSize.width) / 2,
            y: (size.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}

private struct ProjectCaptionStyleSheet: View {
    @ObservedObject var model: AppModel
    let player: AVPlayer
    let previewCues: [CaptionCue]
    let preferredCueID: UUID?
    let onApply: (ProjectCaptionConfiguration) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: ProjectCaptionConfiguration
    @State private var saveErrorMessage: String?
    @State private var appliedDensity: CaptionTextDensity
    @State private var failedConfiguration: ProjectCaptionConfiguration?
    @State private var failedDismissAfterSuccess = false
    @State private var savedStyles: [SavedCaptionStyle]
    @State private var savingCurrentStyle = false
    @State private var savedStyleName = ""
    private let styleStore: CaptionStyleStore

    init(
        model: AppModel,
        player: AVPlayer,
        previewCues: [CaptionCue],
        preferredCueID: UUID?,
        styleStore: CaptionStyleStore = CaptionStyleStore(),
        onApply: @escaping (ProjectCaptionConfiguration) -> Bool
    ) {
        self.model = model
        self.player = player
        self.previewCues = previewCues
        self.preferredCueID = preferredCueID
        self.styleStore = styleStore
        self.onApply = onApply
        let initial = model.captionConfiguration
            ?? ProjectCaptionConfiguration(localeIdentifier: "en-US", placement: .lower)
        _configuration = State(initialValue: initial)
        _appliedDensity = State(initialValue: initial.density)
        _savedStyles = State(initialValue: styleStore.load())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    CaptionVideoPreview(
                        player: player,
                        cue: densityPreviewCue ?? CaptionCue(
                            range: TakeRange(startSeconds: 0, endSeconds: 2),
                            recognizedText: "Your captions stay clear",
                            text: "Your captions stay clear",
                            confidence: 1,
                            alternatives: [],
                            timedSpans: []
                        ),
                        configuration: configuration,
                        activeTime: nil,
                        format: model.project.format ?? .portrait,
                        showsSafeRegion: true
                    )
                    .aspectRatio(
                        model.project.format == .landscape ? (16.0 / 9.0) : (9.0 / 16.0),
                        contentMode: .fit
                    )
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Content Safe Region preview")
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { value in
                                let proposed: CaptionPlacementZone = value.translation.height < -24
                                    ? .upper
                                    : (value.translation.height > 24 ? .lower : .center)
                                if proposed != configuration.placement {
                                    configuration.placement = proposed
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                    )
                }

                Section("Style") {
                    Picker("Preset", selection: $configuration.style) {
                        Text("Clean").tag(CaptionStylePreset.clean)
                        Text("Impact").tag(CaptionStylePreset.impact)
                        Text("Minimal").tag(CaptionStylePreset.minimal)
                        Text("Custom").tag(CaptionStylePreset.custom)
                    }
                    .pickerStyle(.menu)

                    if configuration.style == .custom {
                        DisclosureGroup("Customize") {
                            Picker("Font", selection: $configuration.customization.fontDesign) {
                                Text("System").tag(CaptionFontDesign.system)
                                Text("Rounded").tag(CaptionFontDesign.rounded)
                                Text("Serif").tag(CaptionFontDesign.serif)
                            }
                            Picker("Size", selection: $configuration.customization.fontScale) {
                                Text("Small").tag(CaptionFontScale.small)
                                Text("Standard").tag(CaptionFontScale.standard)
                                Text("Large").tag(CaptionFontScale.large)
                            }
                            Picker("Text", selection: $configuration.customization.textColor) {
                                Text("White").tag(CaptionTextColor.white)
                                Text("Yellow").tag(CaptionTextColor.yellow)
                            }
                            Picker("Highlight", selection: $configuration.customization.highlighting) {
                                Text("None").tag(CaptionHighlightStyle.none)
                                Text("Colored Text").tag(CaptionHighlightStyle.coloredText)
                                Text("Pill").tag(CaptionHighlightStyle.pill)
                            }
                            Picker("Accent", selection: $configuration.customization.accentColor) {
                                Text("Yellow").tag(CaptionAccentColor.yellow)
                                Text("Cyan").tag(CaptionAccentColor.cyan)
                                Text("Green").tag(CaptionAccentColor.green)
                                Text("Pink").tag(CaptionAccentColor.pink)
                            }
                            Picker("Background", selection: $configuration.customization.background) {
                                Text("None").tag(CaptionBackgroundStyle.none)
                                Text("Shadow").tag(CaptionBackgroundStyle.shadow)
                                Text("Rounded Box").tag(CaptionBackgroundStyle.roundedBox)
                            }
                            if configuration.customization.background == .roundedBox {
                                Picker("Opacity", selection: $configuration.customization.containerOpacity) {
                                    Text("Light").tag(CaptionContainerOpacity.light)
                                    Text("Medium").tag(CaptionContainerOpacity.medium)
                                    Text("Strong").tag(CaptionContainerOpacity.strong)
                                }
                            }
                        }

                        Button("Save Custom Style", systemImage: "bookmark") {
                            savedStyleName = ""
                            savingCurrentStyle = true
                        }
                    }

                    if !savedStyles.isEmpty {
                        Menu("Saved Styles", systemImage: "bookmark.fill") {
                            ForEach(savedStyles) { style in
                                Button(style.name) { applySavedStyle(style) }
                            }
                            Divider()
                            Menu("Delete Saved Style", systemImage: "trash") {
                                ForEach(savedStyles) { style in
                                    Button(style.name, role: .destructive) {
                                        styleStore.delete(id: style.id)
                                        savedStyles = styleStore.load()
                                    }
                                }
                            }
                        }
                    }

                    Button("Reset Style", systemImage: "arrow.counterclockwise") {
                        configuration.style = .clean
                        configuration.customization = CaptionStyleCustomization()
                    }
                }

                Section("Position") {
                    Picker("Position", selection: $configuration.placement) {
                        Text("Upper").tag(CaptionPlacementZone.upper)
                        Text("Center").tag(CaptionPlacementZone.center)
                        Text("Lower").tag(CaptionPlacementZone.lower)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Text per Caption") {
                    Picker("Density", selection: $configuration.density) {
                        Text("Less").tag(CaptionTextDensity.less)
                        Text("Standard").tag(CaptionTextDensity.standard)
                        Text("More").tag(CaptionTextDensity.more)
                    }
                    .pickerStyle(.segmented)
                    if configuration.density != appliedDensity {
                        Button("Apply Density") {
                            let densityOnly = CaptionStyleDraftPolicy.densityOnlyConfiguration(
                                draft: configuration,
                                persisted: model.captionConfiguration ?? configuration
                            )
                            apply(densityOnly, dismissAfterSuccess: false)
                        }
                        Text("\(preservedEditedCueCount) edited captions will be preserved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Caption Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var accepted = configuration
                        accepted.density = appliedDensity
                        apply(accepted, dismissAfterSuccess: true)
                    }
                    .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let saveErrorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(saveErrorMessage).font(.footnote)
                        Spacer()
                        Button("Retry") {
                            if let failedConfiguration {
                                apply(
                                    failedConfiguration,
                                    dismissAfterSuccess: failedDismissAfterSuccess
                                )
                            }
                        }
                    }
                    .padding(12)
                    .background(.bar)
                }
            }
            .alert("Save Caption Style", isPresented: $savingCurrentStyle) {
                TextField("Style name", text: $savedStyleName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { saveCurrentStyle() }
                    .disabled(savedStyleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Saves font, colors, highlighting, and background for other Projects.")
            }
        }
    }

    private var preservedEditedCueCount: Int {
        CaptionDensityPreviewPolicy.preservedEditedCueCount(in: previewCues)
    }

    private var densityPreviewCue: CaptionCue? {
        CaptionDensityPreviewPolicy.cue(
            in: previewCues,
            preferredCueID: preferredCueID,
            regions: model.project.projectCaptionTrack?.regions ?? [],
            configuration: configuration,
            format: model.project.format ?? .portrait
        )
    }

    private func apply(
        _ candidate: ProjectCaptionConfiguration,
        dismissAfterSuccess: Bool
    ) {
        if onApply(candidate) {
            saveErrorMessage = nil
            failedConfiguration = nil
            failedDismissAfterSuccess = false
            appliedDensity = candidate.density
            if dismissAfterSuccess { dismiss() }
        } else {
            saveErrorMessage = model.captionGenerationErrorMessage
            failedConfiguration = candidate
            failedDismissAfterSuccess = dismissAfterSuccess
        }
    }

    private func saveCurrentStyle() {
        _ = styleStore.save(
            name: savedStyleName,
            customization: configuration.customization
        )
        savedStyles = styleStore.load()
    }

    private func applySavedStyle(_ style: SavedCaptionStyle) {
        configuration.style = .custom
        configuration.customization = style.customization
    }
}

private struct CaptionContentSafeRegionGuide: View {
    var body: some View {
        GeometryReader { geometry in
            let region = CaptionPresentationLayout.contentSafeRegion(in: geometry.size)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5]))
                .frame(width: region.width, height: region.height)
                .position(x: region.midX, y: region.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ProjectCaptionTimingSubmode: View {
    let cue: CaptionCue
    @ObservedObject var playback: TimelinePlaybackSession
    let configuration: ProjectCaptionConfiguration
    let waveform: [Float]
    let projectDuration: TimeInterval
    let minimumStart: TimeInterval
    let maximumEnd: TimeInterval
    let format: ProjectFormat
    let onPreview: (TakeRange) -> Void
    let onPlay: (TakeRange) -> Void
    let onCancel: () -> Void
    let onCommit: (TakeRange) -> Void
    @State private var start: TimeInterval
    @State private var end: TimeInterval

    init(
        cue: CaptionCue,
        playback: TimelinePlaybackSession,
        configuration: ProjectCaptionConfiguration,
        waveform: [Float],
        projectDuration: TimeInterval,
        minimumStart: TimeInterval,
        maximumEnd: TimeInterval,
        format: ProjectFormat,
        onPreview: @escaping (TakeRange) -> Void,
        onPlay: @escaping (TakeRange) -> Void,
        onCancel: @escaping () -> Void,
        onCommit: @escaping (TakeRange) -> Void
    ) {
        self.cue = cue
        self.playback = playback
        self.configuration = configuration
        self.waveform = waveform
        self.projectDuration = projectDuration
        self.minimumStart = minimumStart
        self.maximumEnd = maximumEnd
        self.format = format
        self.onPreview = onPreview
        self.onPlay = onPlay
        self.onCancel = onCancel
        self.onCommit = onCommit
        _start = State(initialValue: cue.range.start.seconds)
        _end = State(initialValue: cue.range.end.seconds)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                    .frame(minWidth: 44, minHeight: 44)
                Spacer()
                Text("Adjust Timing")
                    .font(.headline)
                Spacer()
                Button("Done") { onCommit(candidate) }
                    .fontWeight(.semibold)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16)
            .background(.bar)

            ScrollView {
                VStack(spacing: 22) {
                    CaptionVideoPreview(
                        player: playback.player,
                        cue: cue,
                        configuration: configuration,
                        activeTime: playback.state.playhead.seconds,
                        format: format
                    )
                    .aspectRatio(
                        format == .landscape ? (16.0 / 9.0) : (9.0 / 16.0),
                        contentMode: .fit
                    )
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    CaptionTimingWaveform(
                        samples: waveform,
                        duration: projectDuration,
                        start: $start,
                        end: $end,
                        minimumStart: minimumStart,
                        maximumEnd: maximumEnd
                    )
                    .frame(height: 86)

                    VStack(spacing: 8) {
                        HStack {
                            Text("Start")
                            Spacer()
                            Text(RecordingDurationFormatter.editingClock(start)).monospacedDigit()
                        }
                        Slider(value: $start, in: minimumStart...max(minimumStart, end - 0.1))
                            .accessibilityLabel("Caption Start")
                            .accessibilityValue(RecordingDurationFormatter.editingClock(start))
                            .accessibilityHint("Adjusts the beginning without crossing adjacent captions.")
                    }

                    VStack(spacing: 8) {
                        HStack {
                            Text("End")
                            Spacer()
                            Text(RecordingDurationFormatter.editingClock(end)).monospacedDigit()
                        }
                        Slider(value: $end, in: min(maximumEnd, start + 0.1)...maximumEnd)
                            .accessibilityLabel("Caption End")
                            .accessibilityValue(RecordingDurationFormatter.editingClock(end))
                            .accessibilityHint("Adjusts the ending without crossing adjacent captions.")
                    }

                    Button {
                        onPlay(candidate)
                    } label: {
                        Label("Play Candidate", systemImage: "play")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onChange(of: start) { _, _ in onPreview(candidate) }
        .onChange(of: end) { _, _ in onPreview(candidate) }
    }

    private var candidate: TakeRange { TakeRange(startSeconds: start, endSeconds: end) }
}

private struct CaptionTimingWaveform: View {
    let samples: [Float]
    let duration: TimeInterval
    @Binding var start: TimeInterval
    @Binding var end: TimeInterval
    let minimumStart: TimeInterval
    let maximumEnd: TimeInterval
    @State private var startDragOrigin: TimeInterval?
    @State private var endDragOrigin: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            let timelineWidth = max(1, geometry.size.width - 44)
            let safeDuration = max(0.001, duration)
            let startX = 22 + timelineWidth * CGFloat(start / safeDuration)
            let endX = 22 + timelineWidth * CGFloat(end / safeDuration)
            ZStack {
                Canvas { context, size in
                    let selection = CGRect(
                        x: startX,
                        y: 0,
                        width: max(0, endX - startX),
                        height: size.height
                    )
                    context.fill(
                        Path(selection),
                        with: .color(Color.accentColor.opacity(0.12))
                    )
                    for (index, sample) in samples.enumerated() {
                        let x = 22 + timelineWidth
                            * (CGFloat(index) + 0.5) / CGFloat(max(1, samples.count))
                        let height = max(2, size.height * CGFloat(sample))
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: (size.height - height) / 2))
                        line.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
                        context.stroke(
                            line,
                            with: .color(Color.accentColor.opacity(0.8)),
                            lineWidth: 1.5
                        )
                    }
                }
                .accessibilityHidden(true)

                timingHandle(
                    label: "Caption Start",
                    value: start,
                    x: startX,
                    timelineWidth: timelineWidth,
                    dragOrigin: $startDragOrigin,
                    allowedRange: minimumStart...max(minimumStart, end - 0.1),
                    onChange: { start = $0 }
                )

                timingHandle(
                    label: "Caption End",
                    value: end,
                    x: endX,
                    timelineWidth: timelineWidth,
                    dragOrigin: $endDragOrigin,
                    allowedRange: min(maximumEnd, start + 0.1)...maximumEnd,
                    onChange: { end = $0 }
                )
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project-Time waveform")
        .accessibilityValue(
            "Candidate from \(RecordingDurationFormatter.editingClock(start)) "
                + "to \(RecordingDurationFormatter.editingClock(end))"
        )
    }

    private func timingHandle(
        label: String,
        value: TimeInterval,
        x: CGFloat,
        timelineWidth: CGFloat,
        dragOrigin: Binding<TimeInterval?>,
        allowedRange: ClosedRange<TimeInterval>,
        onChange: @escaping (TimeInterval) -> Void
    ) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 44)
            .overlay {
                Capsule().fill(.orange).frame(width: 4)
            }
            .contentShape(Rectangle())
            .position(x: x, y: 43)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let origin = dragOrigin.wrappedValue ?? value
                        if dragOrigin.wrappedValue == nil { dragOrigin.wrappedValue = origin }
                        let proposed = origin
                            + TimeInterval(drag.translation.width / timelineWidth) * max(0.001, duration)
                        onChange(min(max(proposed, allowedRange.lowerBound), allowedRange.upperBound))
                    }
                    .onEnded { _ in dragOrigin.wrappedValue = nil }
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(RecordingDurationFormatter.editingClock(value))
            .accessibilityHint("Drag horizontally to adjust this boundary.")
            .accessibilityAdjustableAction { direction in
                let increment = direction == .increment ? 0.05 : -0.05
                onChange(min(max(value + increment, allowedRange.lowerBound), allowedRange.upperBound))
            }
    }
}
