import SwiftUI

struct CaptionReviewQueueScreen: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let take = model.captionReviewTakes.first,
                   let track = take.captions,
                   let configuration = model.captionConfiguration {
                    CaptionReviewEditor(
                        take: take,
                        movieURL: model.movieURL(for: take),
                        track: track,
                        configuration: configuration,
                        format: model.project.format ?? .portrait,
                        remainingCount: model.captionReviewTakes.count,
                        onPlacementChanged: model.setCaptionPlacement,
                        onSave: { model.saveCaptionDraft(takeID: take.id, track: $0) },
                        onApprove: { model.approveCaptions(takeID: take.id, track: $0) }
                    )
                    .id(take.id)
                } else {
                    ContentUnavailableView(
                        "Captions Reviewed",
                        systemImage: "captions.bubble.fill",
                        description: Text("Approved captions are ready for the next Project Export.")
                    )
                }
            }
            .navigationTitle("Caption Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.captionReviewTakes.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
}

private struct CaptionReviewEditor: View {
    @StateObject private var playback: TakePlaybackController
    @State private var editor: CaptionEditorState
    @State private var checkpoint: CaptionDraftCheckpoint
    @State private var showsCaptions = true
    @State private var videoRect: CGRect = .zero
    @State private var selectedCueID: UUID?
    @State private var expandedCueIDs: Set<UUID> = []
    @State private var confirmsDiscard = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let take: ProjectTake
    let configuration: ProjectCaptionConfiguration
    let format: ProjectFormat
    let remainingCount: Int
    let onPlacementChanged: (CaptionPlacementZone) -> Void
    let onSave: (TakeCaptionTrack) -> Bool
    let onApprove: (TakeCaptionTrack) -> Bool

    init(
        take: ProjectTake,
        movieURL: URL,
        track: TakeCaptionTrack,
        configuration: ProjectCaptionConfiguration,
        format: ProjectFormat,
        remainingCount: Int,
        onPlacementChanged: @escaping (CaptionPlacementZone) -> Void,
        onSave: @escaping (TakeCaptionTrack) -> Bool,
        onApprove: @escaping (TakeCaptionTrack) -> Bool
    ) {
        self.take = take
        self.configuration = configuration
        self.format = format
        self.remainingCount = remainingCount
        self.onPlacementChanged = onPlacementChanged
        self.onSave = onSave
        self.onApprove = onApprove
        let selection: TakeRange?
        if case let .selection(range) = take.effectiveRange { selection = range } else { selection = nil }
        _playback = StateObject(wrappedValue: TakePlaybackController(
            url: movieURL,
            originalDuration: take.duration,
            selection: selection,
            mode: selection == nil ? .original : .trimmed
        ))
        _editor = State(initialValue: CaptionEditorState(track: track))
        _checkpoint = State(initialValue: CaptionDraftCheckpoint(track: track))
    }

    private var activeCueID: UUID? {
        CaptionOverlayResolver.active(in: editor.track, at: playback.currentTime)?.cue.id
    }

    private var focusedCueID: UUID? {
        activeCueID ?? selectedCueID
    }

    private var hasUnsavedChanges: Bool {
        checkpoint.hasUnsavedChanges(in: editor.track)
    }

    var body: some View {
        VStack(spacing: 0) {
            fixedPreviewHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if !editor.uncertainCueIDs.isEmpty {
                            Button {
                                guard let cue = editor.nextUncertainCue(after: focusedCueID) else { return }
                                focus(cue, using: proxy)
                            } label: {
                                HStack(spacing: 8) {
                                    Label(
                                        "\(editor.uncertainCueIDs.count) low-confidence \(editor.uncertainCueIDs.count == 1 ? "phrase" : "phrases")",
                                        systemImage: "exclamationmark.triangle.fill"
                                    )
                                    Spacer()
                                    Text("Next")
                                    Image(systemName: "chevron.down")
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .accessibilityHint("Seeks to the next phrase that may need wording review")
                            .accessibilityIdentifier("caption-next-low-confidence")
                        }

                        if editor.track.cues.isEmpty {
                            ContentUnavailableView(
                                "No Speech Detected",
                                systemImage: "waveform.slash",
                                description: Text("Approve this Take without captions, or transcribe it again later.")
                            )
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(Array(editor.track.cues.enumerated()), id: \.element.id) { index, cue in
                                    cueEditor(cue, index: index, proxy: proxy)
                                        .id(cue.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: activeCueID) { _, cueID in
                    guard playback.isPlaying, let cueID else { return }
                    selectedCueID = cueID
                    scroll(to: cueID, using: proxy)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button("Save Draft", systemImage: "square.and.arrow.down") {
                    playback.pause()
                    guard onSave(editor.track) else { return }
                    checkpoint.markSaved(editor.track)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(!hasUnsavedChanges)
                .accessibilityIdentifier("caption-save-close")

                Button("Approve Take", systemImage: "checkmark.circle.fill") {
                    playback.pause()
                    _ = onApprove(editor.track)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("caption-approve-take")
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
            .controlSize(.large)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if hasUnsavedChanges { confirmsDiscard = true }
                    else { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Discard unsaved caption edits?",
            isPresented: $confirmsDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The last saved draft remains available.")
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .onDisappear { playback.pause() }
    }

    private var fixedPreviewHeader: some View {
        VStack(spacing: 9) {
            reviewStatus
            preview
            previewSettings
            transport
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private var reviewStatus: some View {
        HStack(spacing: 10) {
            Text(remainingCount == 1 ? "Final Take" : "\(remainingCount) Takes remaining")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(Locale.current.localizedString(forIdentifier: editor.track.localeIdentifier) ?? editor.track.localeIdentifier)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        ZStack {
            PlayerLayerView(player: playback.player) { rect in
                if videoRect != rect { videoRect = rect }
            }
            if showsCaptions,
               let active = CaptionOverlayResolver.active(in: editor.track, at: playback.currentTime) {
                captionOverlay(active, videoRect: videoRect)
            }
        }
        .aspectRatio(format == .portrait ? 9 / 16 : 16 / 9, contentMode: .fit)
        .frame(maxHeight: format == .portrait ? 280 : 190)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var previewSettings: some View {
        HStack(spacing: 8) {
            Picker("Preview", selection: $showsCaptions) {
                Text("Original").tag(false)
                Text("Captioned").tag(true)
            }
            .pickerStyle(.segmented)

            Menu {
                Button("Top") { onPlacementChanged(.upper) }
                Button("Center") { onPlacementChanged(.center) }
                Button("Bottom") { onPlacementChanged(.lower) }
            } label: {
                Label(placementLabel, systemImage: "captions.bubble")
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Caption position, \(placementLabel)")
        }
    }

    private var placementLabel: String {
        switch configuration.placement {
        case .upper: "Top"
        case .center: "Center"
        case .lower: "Bottom"
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Text(RecordingDurationFormatter.clock(playback.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { playback.currentTime }, set: playback.seek),
                in: playback.activeStart...max(playback.activeEnd, playback.activeStart + 0.01)
            )
            .accessibilityLabel("Playback position")
            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func captionOverlay(
        _ active: ActiveCaptionPresentation,
        videoRect: CGRect
    ) -> some View {
        GeometryReader { geometry in
            let displayRect = videoRect.isEmpty
                ? CGRect(origin: .zero, size: geometry.size)
                : videoRect
            let metrics = CaptionPresentationLayout.metrics(for: displayRect.size)
            let maximumContainerWidth = displayRect.width * (1 - CaptionPresentationLayout.horizontalInsetFraction * 2)
            captionText(active)
                .font(.system(size: metrics.fontSize, weight: .bold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: max(1, maximumContainerWidth - metrics.padding * 2))
                .padding(metrics.padding)
                .background(
                    .black.opacity(0.76),
                    in: RoundedRectangle(cornerRadius: metrics.cornerRadius)
                )
                .fixedSize(horizontal: false, vertical: true)
                .position(
                    x: displayRect.midX,
                    y: displayRect.minY + displayRect.height * CaptionPresentationLayout.centerYFraction(
                        for: configuration.placement
                    )
                )
                .accessibilityLabel(active.cue.text)
        }
    }

    private func captionText(_ active: ActiveCaptionPresentation) -> Text {
        guard !active.cue.wasEdited,
              !active.cue.timingWasEdited,
              !active.cue.timedSpans.isEmpty else {
            return Text(active.cue.text).foregroundColor(.white)
        }
        return active.cue.timedSpans.enumerated().reduce(Text("")) { result, item in
            let (index, span) = item
            let prefix = index == 0 ? "" : " "
            let isActive = span == active.timedSpan
            return result + Text(prefix + span.text)
                .foregroundColor(isActive ? .yellow : .white)
                .fontWeight(isActive ? .heavy : .bold)
        }
    }

    private func cueEditor(
        _ cue: CaptionCue,
        index: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        let isFocused = focusedCueID == cue.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                focus(cue, using: proxy)
            } label: {
                HStack(spacing: 10) {
                    Text("Phrase \(index + 1)")
                        .font(.subheadline.weight(.semibold))
                    Text("\(RecordingDurationFormatter.editingClock(cue.range.start.seconds))–\(RecordingDurationFormatter.editingClock(cue.range.end.seconds))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let confidence = cue.confidence, confidence < 0.6 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Check wording")
                    }
                    Spacer()
                    Image(systemName: isFocused ? "speaker.wave.2.circle.fill" : "play.circle")
                        .font(.title2)
                        .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Seeks the preview to this phrase")

            TextField("Caption text", text: Binding(
                get: { currentCue(cue.id)?.text ?? "" },
                set: { editor.updateText(cueID: cue.id, text: $0) }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .disabled(!cue.isEnabled)

            HStack(spacing: 10) {
                Button(
                    cue.isEnabled ? "Hide" : "Include",
                    systemImage: cue.isEnabled ? "eye.slash" : "eye"
                ) {
                    editor.setEnabled(cueID: cue.id, isEnabled: !cue.isEnabled)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)

                Spacer()

                Button {
                    if expandedCueIDs.contains(cue.id) { expandedCueIDs.remove(cue.id) }
                    else { expandedCueIDs.insert(cue.id) }
                } label: {
                    HStack(spacing: 5) {
                        Label("Options", systemImage: "slider.horizontal.3")
                        Image(systemName: expandedCueIDs.contains(cue.id) ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }

            if expandedCueIDs.contains(cue.id) {
                advancedControls(for: cue, index: index)
            }
        }
        .padding(12)
        .background(
            isFocused ? Color.accentColor.opacity(0.08) : Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 1.5)
        }
        .opacity(cue.isEnabled ? 1 : 0.62)
        .accessibilityIdentifier("caption-phrase-\(cue.id.uuidString)")
    }

    @ViewBuilder
    private func advancedControls(for cue: CaptionCue, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !cue.alternatives.isEmpty {
                Menu("Phrase Alternatives", systemImage: "text.bubble") {
                    ForEach(cue.alternatives, id: \.self) { alternative in
                        Button(alternative) {
                            editor.updateText(cueID: cue.id, text: alternative)
                        }
                    }
                }
            }
            ForEach(cue.timedSpans.filter { !$0.alternatives.isEmpty }, id: \.range) { span in
                Menu("Alternatives for “\(span.text)”", systemImage: "text.bubble") {
                    ForEach(span.alternatives, id: \.self) { alternative in
                        Button(alternative) {
                            editor.applyAlternative(
                                cueID: cue.id,
                                spanRange: span.range,
                                alternative: alternative
                            )
                        }
                    }
                }
            }

            HStack {
                trimSlider(cueID: cue.id, isStart: true)
                trimSlider(cueID: cue.id, isStart: false)
            }

            HStack {
                if cue.wasEdited || cue.timingWasEdited || !cue.isEnabled {
                    Button("Restore", systemImage: "arrow.counterclockwise") {
                        try? editor.restore(cueID: cue.id)
                    }
                }
                Menu("Structure", systemImage: "text.badge.plus") {
                    Button("Split Phrase", systemImage: "scissors") {
                        try? editor.split(cueID: cue.id)
                    }
                    .disabled(cue.text.split(whereSeparator: { $0.isWhitespace }).count < 2)
                    Button("Merge with Next", systemImage: "arrow.left.arrow.right") {
                        try? editor.mergeWithNext(cueID: cue.id)
                    }
                    .disabled(index >= editor.track.cues.count - 1)
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
    }

    private func trimSlider(cueID: UUID, isStart: Bool) -> some View {
        let cue = currentCue(cueID)!
        let cueIndex = editor.track.cues.firstIndex(where: { $0.id == cueID })!
        let value = isStart ? cue.range.start.seconds : cue.range.end.seconds
        let previousEnd = cueIndex > 0
            ? editor.track.cues[cueIndex - 1].range.end.seconds
            : editor.track.sourceRange.start.seconds
        let nextStart = cueIndex + 1 < editor.track.cues.count
            ? editor.track.cues[cueIndex + 1].range.start.seconds
            : editor.track.sourceRange.end.seconds
        let lower = isStart ? previousEnd : cue.range.start.seconds + 0.1
        let upper = isStart ? cue.range.end.seconds - 0.1 : nextStart
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(isStart ? "Start" : "End") \(RecordingDurationFormatter.editingClock(value))")
                .font(.caption.monospacedDigit())
            Slider(value: Binding(
                get: { isStart ? currentCue(cueID)!.range.start.seconds : currentCue(cueID)!.range.end.seconds },
                set: { newValue in
                    guard let current = currentCue(cueID) else { return }
                    let range = isStart
                        ? TakeRange(startSeconds: newValue, endSeconds: current.range.end.seconds)
                        : TakeRange(startSeconds: current.range.start.seconds, endSeconds: newValue)
                    try? editor.updateRange(cueID: cueID, range: range)
                }
            ), in: lower...max(lower, upper))
            .accessibilityLabel(isStart ? "Caption start" : "Caption end")
            .accessibilityValue(RecordingDurationFormatter.editingClock(value))
        }
    }

    private func focus(_ cue: CaptionCue, using proxy: ScrollViewProxy) {
        selectedCueID = cue.id
        playback.seek(to: cue.range.start.seconds)
        scroll(to: cue.id, using: proxy)
    }

    private func scroll(to cueID: UUID, using proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(cueID, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(cueID, anchor: .center)
            }
        }
    }

    private func currentCue(_ id: UUID) -> CaptionCue? {
        editor.track.cues.first(where: { $0.id == id })
    }
}
