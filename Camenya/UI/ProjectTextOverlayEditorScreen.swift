import AVFoundation
import SwiftUI
import UIKit

struct ProjectTextOverlayEditorScreen: View {
    @ObservedObject var model: AppModel
    let snapshot: ExportSnapshot
    let onDone: (ProjectTime) -> Void
    @StateObject private var playback: TimelinePlaybackSession
    @State private var editor: TextOverlayEditorState
    @State private var selectedID: UUID?
    @State private var textDraft = ""
    @State private var showingStyle = false
    @State private var saveError: String?
    @State private var failedSave: [ProjectTextOverlay]?
    @State private var timingStep = 0.1
    @State private var timelineScrubOrigin: TimeInterval?
    @State private var positionDrag: PositionDragContext?
    @State private var timingDragBefore: [ProjectTextOverlay]?
    @AccessibilityFocusState private var errorFocused: Bool
    @FocusState private var textFieldFocused: Bool

    init(
        model: AppModel,
        snapshot: ExportSnapshot,
        initialProjectTime: ProjectTime,
        onDone: @escaping (ProjectTime) -> Void
    ) {
        self.model = model
        self.snapshot = snapshot
        self.onDone = onDone
        _playback = StateObject(wrappedValue: TimelinePlaybackSession(
            snapshot: snapshot,
            initialProjectTime: initialProjectTime
        ))
        _editor = State(initialValue: TextOverlayEditorState(
            overlays: model.project.projectTextOverlays,
            duration: snapshot.duration.seconds
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if TextOverlayEditorPresentationPolicy.showsVideoPreview(
                    isTextFieldFocused: textFieldFocused
                ) {
                    videoPreview
                    playbackControl
                }
                overlayLane
                inspector
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { errorBar }
            .sheet(isPresented: $showingStyle) {
                if let selected = selectedOverlay {
                    TextOverlayStyleSheet(appearance: selected.appearance) { appearance in
                        try? editor.updateAppearance(id: selected.id, appearance: appearance)
                    }
                    .presentationDetents([.medium, .large])
                }
            }
        }
        .onChange(of: selectedID) { _, value in
            textDraft = editor.overlays.first(where: { $0.id == value })?.text ?? ""
        }
        .onChange(of: editor.overlays) { _, _ in clearStaleSaveFailure() }
        .onChange(of: textDraft) { _, _ in clearStaleSaveFailure() }
        .onChange(of: textFieldFocused) { _, focused in
            if !focused { commitSelectedText() }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = activeOverlays.last?.id ?? editor.overlays.first?.id
            }
        }
        .onDisappear { playback.send(.pause) }
    }

    private var videoPreview: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                PlayerLayerView(player: playback.player)
                ForEach(activeOverlays) { overlay in
                    TextOverlayLayerPreview(overlay: overlay)
                        .allowsHitTesting(false)
                    overlayPositionTarget(for: overlay, in: geometry.size)
                }
                if positionDrag != nil {
                    TextContentSafeRegionGuide()
                }
            }
        }
        .aspectRatio(model.project.format == .landscape ? 16 / 9 : 9 / 16, contentMode: .fit)
        .frame(maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var playbackControl: some View {
        Button {
            playback.send(.togglePlayback)
        } label: {
            Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.state.isPlaying ? "Pause" : "Play")
    }

    @ViewBuilder
    private func overlayPositionTarget(
        for overlay: ProjectTextOverlay,
        in size: CGSize
    ) -> some View {
        let frame = ProjectFinishingRenderer().previewFrame(overlay: overlay, canvas: size)
        let targetSize = CGSize(width: max(44, frame.width), height: max(44, frame.height))
        let target = Color.clear
            .frame(width: targetSize.width, height: targetSize.height)
            .contentShape(Rectangle())
            .position(x: frame.midX, y: frame.midY)
            .accessibilityElement()
            .accessibilityLabel(
                TextOverlayEditorPresentationPolicy.positionAccessibilityLabel(text: overlay.text)
            )

        if overlay.id == selectedID {
            target
                .gesture(positionGesture(for: overlay, in: size))
                .accessibilityHint("Drag to reposition this text")
                .accessibilityAction(named: "Move Left") { nudgePosition(id: overlay.id, x: -0.05, y: 0) }
                .accessibilityAction(named: "Move Right") { nudgePosition(id: overlay.id, x: 0.05, y: 0) }
                .accessibilityAction(named: "Move Up") { nudgePosition(id: overlay.id, x: 0, y: -0.05) }
                .accessibilityAction(named: "Move Down") { nudgePosition(id: overlay.id, x: 0, y: 0.05) }
        } else {
            target
                .onTapGesture { selectOverlay(overlay, seekToStart: false) }
                .accessibilityHint("Select this text")
                .accessibilityAction { selectOverlay(overlay, seekToStart: false) }
        }
    }

    private var overlayLane: some View {
        GeometryReader { geometry in
            let pointsPerSecond: CGFloat = 46
            let playhead = playback.state.playhead.seconds
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                ForEach(editor.overlays) { overlay in
                    let width = max(12, overlay.range.duration * pointsPerSecond)
                    let centerX = geometry.size.width / 2
                        + ((overlay.range.start.seconds + overlay.range.duration / 2) - playhead)
                            * pointsPerSecond
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(overlay.id == selectedID ? Color.accentColor : Color.secondary.opacity(0.45))
                        .frame(width: width, height: 30)
                        .overlay {
                            HStack(spacing: 3) {
                                if overlay.id == selectedID {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                Text(overlay.text).lineLimit(1)
                            }
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                        }
                        .position(x: centerX, y: geometry.size.height / 2)
                        .onTapGesture { selectOverlay(overlay, seekToStart: true) }
                }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                VStack {
                    Text(RecordingDurationFormatter.preciseEditingClock(playhead))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, 3)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(timelineScrubGesture(pointsPerSecond: pointsPerSecond))
        }
        .frame(height: 68)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TextOverlayEditorPresentationPolicy.timelineAccessibilityLabel)
        .accessibilityValue(RecordingDurationFormatter.preciseEditingClock(playback.state.playhead.seconds))
    }

    @ViewBuilder
    private var inspector: some View {
        if let overlay = selectedOverlay {
            ScrollView {
                VStack(spacing: 12) {
                    TextField("Text", text: $textDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($textFieldFocused)
                        .onSubmit { commitText(for: overlay.id) }

                    HStack {
                        Button("Style", systemImage: "textformat") { showingStyle = true }
                        Spacer()
                        Menu {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                guard commitText(for: overlay.id) else { return }
                                if let copy = try? editor.duplicate(id: overlay.id) { selectedID = copy.id }
                            }
                            Button("Bring Forward", systemImage: "square.2.layers.3d.top.filled") {
                                guard commitText(for: overlay.id) else { return }
                                try? editor.moveForward(id: overlay.id)
                            }
                            Button("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") {
                                guard commitText(for: overlay.id) else { return }
                                try? editor.moveBackward(id: overlay.id)
                            }
                            Button("Reset Position", systemImage: "scope") {
                                guard commitText(for: overlay.id) else { return }
                                try? editor.updatePosition(
                                    id: overlay.id,
                                    center: NormalizedProjectPoint(x: 0.5, y: 0.5)
                                )
                            }
                            Divider()
                            Button("Delete Text", systemImage: "trash", role: .destructive) {
                                if TextOverlayEditorPresentationPolicy.shouldCommitDraftBeforeDeletion(
                                    textDraft
                                ), !commitText(for: overlay.id) {
                                    return
                                }
                                saveError = nil
                                failedSave = nil
                                try? editor.delete(id: overlay.id)
                                selectedID = editor.overlays.last?.id
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Text actions")
                    }
                    .buttonStyle(.bordered)

                    ProjectTimeRangeControl(
                        start: overlay.range.start.seconds,
                        end: overlay.range.end.seconds,
                        duration: snapshot.duration.seconds,
                        step: $timingStep,
                        onChange: { start, end in
                            try? editor.updateRange(id: overlay.id, start: start, end: end)
                        },
                        onBeginContinuousChange: {
                            timingDragBefore = editor.overlays
                        },
                        onPreviewChange: { start, end in
                            try? editor.updateRangeTransient(id: overlay.id, start: start, end: end)
                        },
                        onEndContinuousChange: {
                            if let timingDragBefore {
                                editor.commitTransientChange(name: "Adjust Timing", from: timingDragBefore)
                            }
                            timingDragBefore = nil
                        }
                    )
                }
            }
        } else {
            ContentUnavailableView(
                "Add Text",
                systemImage: "text.badge.plus",
                description: Text("Add an overlay at the playhead, then place and time it.")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { onDone(playback.state.playhead) }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                guard commitSelectedText() else { return }
                let overlay = editor.addOverlay(at: playback.state.playhead.seconds)
                selectedID = overlay.id
                textDraft = overlay.text
                Task { @MainActor in textFieldFocused = true }
            } label: { Image(systemName: "plus") }
            .accessibilityLabel("Add Text")

            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!canUndo)
                .accessibilityLabel("Undo")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!canRedo)
                .accessibilityLabel("Redo")
            Button("Done") { finishEditing() }
                .fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private var errorBar: some View {
        if let saveError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(saveError).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                if let failedSave {
                    Button("Retry") { persist(failedSave) }
                }
            }
            .padding(12)
            .background(.bar)
            .accessibilityFocused($errorFocused)
        }
    }

    private var selectedOverlay: ProjectTextOverlay? {
        editor.overlays.first(where: { $0.id == selectedID })
    }

    private var activeOverlays: [ProjectTextOverlay] {
        editor.overlays.filter {
            playback.state.playhead.seconds >= $0.range.start.seconds
                && playback.state.playhead.seconds < $0.range.end.seconds
        }
    }

    private func timelineScrubGesture(pointsPerSecond: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                playback.send(.pause)
                let origin = timelineScrubOrigin ?? playback.state.playhead.seconds
                if timelineScrubOrigin == nil { timelineScrubOrigin = origin }
                let proposed = origin
                    - Double(value.translation.width / pointsPerSecond)
                playback.send(.previewSeek(ProjectTime(seconds: min(max(0, proposed), snapshot.duration.seconds))))
            }
            .onEnded { _ in
                timelineScrubOrigin = nil
                playback.send(.seek(playback.state.playhead))
            }
    }

    private func positionGesture(for overlay: ProjectTextOverlay, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let context = positionDrag ?? PositionDragContext(
                    center: overlay.center,
                    before: editor.overlays
                )
                if positionDrag == nil { positionDrag = context }
                let safeRegion = CaptionPresentationLayout.contentSafeRegion(in: size)
                let x = min(1, max(0, context.center.x + Double(value.translation.width / max(1, safeRegion.width))))
                let y = min(1, max(0, context.center.y + Double(value.translation.height / max(1, safeRegion.height))))
                try? editor.updatePositionTransient(
                    id: overlay.id,
                    center: NormalizedProjectPoint(x: x, y: y)
                )
            }
            .onEnded { _ in
                if let context = positionDrag {
                    editor.commitTransientChange(name: "Move Text", from: context.before)
                }
                positionDrag = nil
            }
    }

    @discardableResult
    private func commitText(for id: UUID) -> Bool {
        let normalized = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            failedSave = nil
            saveError = "Text can't be empty."
            errorFocused = true
            textFieldFocused = true
            return false
        }
        do {
            try editor.updateText(id: id, text: normalized)
            return true
        } catch {
            failedSave = nil
            saveError = "This text change couldn't be applied."
            errorFocused = true
            return false
        }
    }

    private func undo() {
        guard commitSelectedText() else { return }
        guard let operation = editor.undo() else { return }
        synchronizeDraftWithSelection()
        UIAccessibility.post(notification: .announcement, argument: "Undid \(operation.name)")
    }

    private func redo() {
        guard let operation = editor.redo() else { return }
        synchronizeDraftWithSelection()
        UIAccessibility.post(notification: .announcement, argument: "Redid \(operation.name)")
    }

    @discardableResult
    private func commitSelectedText() -> Bool {
        guard let selectedID else { return true }
        return commitText(for: selectedID)
    }

    private func synchronizeDraftWithSelection() {
        textDraft = selectedOverlay?.text ?? ""
    }

    private func nudgePosition(id: UUID, x: Double, y: Double) {
        guard let overlay = editor.overlays.first(where: { $0.id == id }) else { return }
        let center = NormalizedProjectPoint(
            x: min(1, max(0, overlay.center.x + x)),
            y: min(1, max(0, overlay.center.y + y))
        )
        try? editor.updatePosition(id: id, center: center)
    }

    private var canUndo: Bool {
        editor.canUndo || (selectedOverlay.map { $0.text != textDraft } ?? false)
    }

    private var canRedo: Bool {
        editor.canRedo && (selectedOverlay.map { $0.text == textDraft } ?? true)
    }

    private func selectOverlay(_ overlay: ProjectTextOverlay, seekToStart: Bool) {
        guard commitSelectedText() else { return }
        selectedID = overlay.id
        if seekToStart { playback.send(.seek(overlay.range.start)) }
    }

    private func finishEditing() {
        guard commitSelectedText() else { return }
        persist(editor.overlays)
    }

    private func persist(_ overlays: [ProjectTextOverlay]) {
        if model.saveProjectTextOverlays(overlays) {
            saveError = nil
            failedSave = nil
            onDone(playback.state.playhead)
        } else {
            failedSave = overlays
            saveError = "Text changes couldn't be saved."
            errorFocused = true
        }
    }

    private func clearStaleSaveFailure() {
        guard saveError != nil else { return }
        saveError = nil
        failedSave = nil
    }
}

private struct PositionDragContext {
    let center: NormalizedProjectPoint
    let before: [ProjectTextOverlay]
}

private struct TextContentSafeRegionGuide: View {
    var body: some View {
        GeometryReader { geometry in
            let region = CaptionPresentationLayout.contentSafeRegion(in: geometry.size)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .frame(width: region.width, height: region.height)
                Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: region.height)
                Rectangle().fill(.white.opacity(0.35)).frame(width: region.width, height: 1)
            }
            .position(x: region.midX, y: region.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ProjectTimeRangeControl: View {
    let start: TimeInterval
    let end: TimeInterval
    let duration: TimeInterval
    @Binding var step: TimeInterval
    let onChange: (TimeInterval, TimeInterval) -> Void
    let onBeginContinuousChange: () -> Void
    let onPreviewChange: (TimeInterval, TimeInterval) -> Void
    let onEndContinuousChange: () -> Void
    @State private var handleDragActive = false
    @State private var handleDragOrigin: TimeRangeDragOrigin?

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8)
                    Capsule().fill(Color.accentColor.opacity(0.45))
                        .frame(width: max(2, CGFloat((end - start) / max(duration, 0.001)) * geometry.size.width), height: 8)
                        .offset(x: CGFloat(start / max(duration, 0.001)) * geometry.size.width)
                    handle(at: start, width: geometry.size.width, edge: .start)
                    handle(at: end, width: geometry.size.width, edge: .end)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 38)

            Picker("Precision", selection: $step) {
                Text("0.1 s").tag(0.1)
                Text("0.01 s").tag(0.01)
            }
            .pickerStyle(.segmented)

            edgeRow("Start", value: start, minus: { onChange(max(0, start - step), end) }, plus: {
                onChange(min(end - 0.01, start + step), end)
            })
            edgeRow("End", value: end, minus: { onChange(start, max(start + 0.01, end - step)) }, plus: {
                onChange(start, min(duration, end + step))
            })
        }
    }

    private enum Edge { case start, end }

    private func handle(at value: TimeInterval, width: CGFloat, edge: Edge) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 10, height: 34)
            .offset(x: CGFloat(value / max(duration, 0.001)) * width - 5)
            .gesture(DragGesture().onChanged { gesture in
                if !handleDragActive {
                    handleDragActive = true
                    handleDragOrigin = TimeRangeDragOrigin(start: start, end: end)
                    onBeginContinuousChange()
                }
                let origin = handleDragOrigin ?? TimeRangeDragOrigin(start: start, end: end)
                let delta = TimeInterval(gesture.translation.width / max(1, width)) * duration
                if edge == .start {
                    onPreviewChange(
                        min(max(0, origin.start + delta), origin.end - 0.01),
                        origin.end
                    )
                } else {
                    onPreviewChange(
                        origin.start,
                        max(origin.start + 0.01, min(duration, origin.end + delta))
                    )
                }
            }.onEnded { _ in
                handleDragActive = false
                handleDragOrigin = nil
                onEndContinuousChange()
            })
            .accessibilityLabel(edge == .start ? "Start" : "End")
            .accessibilityValue(RecordingDurationFormatter.preciseEditingClock(value))
    }

    private func edgeRow(
        _ label: String,
        value: TimeInterval,
        minus: @escaping () -> Void,
        plus: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline.weight(.semibold))
                Text(RecordingDurationFormatter.preciseEditingClock(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            ControlGroup {
                Button(action: minus) { Image(systemName: "minus") }
                    .accessibilityLabel("Move \(label) earlier")
                Button(action: plus) { Image(systemName: "plus") }
                    .accessibilityLabel("Move \(label) later")
            }
        }
    }
}

private struct TimeRangeDragOrigin {
    let start: TimeInterval
    let end: TimeInterval
}

private struct TextOverlayStyleSheet: View {
    let onApply: (TextAppearance) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var appearance: TextAppearance
    @State private var color: Color
    @State private var saved: [SavedTextAppearance]
    @State private var saving = false
    @State private var name = ""
    private let store = TextAppearanceStore()

    init(appearance: TextAppearance, onApply: @escaping (TextAppearance) -> Void) {
        self.onApply = onApply
        _appearance = State(initialValue: appearance)
        _color = State(initialValue: Color(
            red: appearance.color.red,
            green: appearance.color.green,
            blue: appearance.color.blue,
            opacity: appearance.color.alpha
        ))
        _saved = State(initialValue: Self.loadSharedStyles())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    TextOverlayLayerPreview(overlay: ProjectTextOverlay(
                        text: "Your text",
                        range: ProjectTimeRange(start: .zero, end: ProjectTime(seconds: 2)),
                        center: NormalizedProjectPoint(x: 0.5, y: 0.5),
                        appearance: appearance
                    ))
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .frame(maxHeight: 180)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if !saved.isEmpty {
                    Section("Saved Styles") {
                        ForEach(saved) { style in
                            Button(style.name) {
                                appearance = style.appearance
                                color = Color(red: appearance.color.red, green: appearance.color.green, blue: appearance.color.blue, opacity: appearance.color.alpha)
                            }
                        }
                    }
                }
                Section("Typography") {
                    Picker("Font", selection: $appearance.fontDesign) {
                        ForEach(TextFontDesign.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Weight", selection: $appearance.fontWeight) {
                        ForEach(TextFontWeight.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Size", selection: $appearance.fontScale) {
                        ForEach(TextFontScale.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Alignment", selection: $appearance.alignment) {
                        ForEach(TextHorizontalAlignment.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Appearance") {
                    ColorPicker("Color", selection: $color, supportsOpacity: true)
                    Picker("Outline", selection: $appearance.outline) {
                        ForEach(TextOutlineStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Background", selection: $appearance.background) {
                        ForEach(TextBackgroundStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Button("Save Style", systemImage: "bookmark") { saving = true }
            }
            .navigationTitle("Text Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { applyAndDismiss() }.fontWeight(.semibold)
                }
            }
            .alert("Save Style", isPresented: $saving) {
                TextField("Style name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    updateColor()
                    _ = store.save(name: name, appearance: appearance)
                    saved = Self.loadSharedStyles()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .onChange(of: color) { _, _ in updateColor() }
        }
    }

    private func updateColor() {
        let resolved = UIColor(color)
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        appearance.color = TextColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func applyAndDismiss() {
        updateColor()
        onApply(appearance)
        dismiss()
    }

    private static func loadSharedStyles() -> [SavedTextAppearance] {
        var result = TextAppearanceStore().load()
        let names = Set(result.map { $0.name.lowercased() })
        result.append(contentsOf: CaptionStyleStore().load().compactMap { style in
            guard !names.contains(style.name.lowercased()) else { return nil }
            return SavedTextAppearance(
                id: style.id,
                name: style.name,
                appearance: TextAppearance(captionCustomization: style.customization)
            )
        })
        return result
    }
}

private extension RawRepresentable where RawValue == String {
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
