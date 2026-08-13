import SwiftUI

struct TrimReviewQueueScreen: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let take = model.trimReviewTakes.first {
                TrimReviewEditor(
                    take: take,
                    envelope: model.trimEnvelope(for: take),
                    url: model.movieURL(for: take),
                    format: model.project.format ?? .portrait,
                    remainingCount: model.trimReviewTakes.count,
                    keepOriginal: { model.keepOriginal(takeID: take.id) },
                    useSelection: { model.useTrimSelection(takeID: take.id, range: $0) }
                )
                .id(take.id)
            } else {
                ContentUnavailableView(
                    "Silence Trims Reviewed",
                    systemImage: "checkmark.circle.fill",
                    description: Text("Play the Project to check the trimmed Timeline, then export when it feels right.")
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
}

private struct TrimReviewEditor: View {
    let take: ProjectTake
    let envelope: [Float]
    let format: ProjectFormat
    let remainingCount: Int
    let keepOriginal: () -> Void
    let useSelection: (TakeRange) -> Void

    @StateObject private var playback: TakePlaybackController
    @State private var editor: SilenceTrimEditorState
    private let suggestionWasDetected: Bool

    init(
        take: ProjectTake,
        envelope: [Float],
        url: URL,
        format: ProjectFormat,
        remainingCount: Int,
        keepOriginal: @escaping () -> Void,
        useSelection: @escaping (TakeRange) -> Void
    ) {
        self.take = take
        self.envelope = envelope
        self.format = format
        self.remainingCount = remainingCount
        self.keepOriginal = keepOriginal
        self.useSelection = useSelection
        let suggestedRange: TakeRange
        let detected: Bool
        if case let .suggestion(suggestion) = take.trimAnalysis {
            suggestedRange = suggestion.range
            detected = true
        } else {
            suggestedRange = TakeRange(startSeconds: 0, endSeconds: take.duration)
            detected = false
        }
        let range: TakeRange
        switch take.trimDecision {
        case let .useSelection(selection): range = selection
        case .keepOriginal: range = TakeRange(startSeconds: 0, endSeconds: take.duration)
        case nil: range = suggestedRange
        }
        suggestionWasDetected = detected
        _editor = State(initialValue: SilenceTrimEditorState(
            duration: take.duration,
            suggestion: suggestedRange,
            selection: range
        ))
        _playback = StateObject(wrappedValue: TakePlaybackController(
            url: url,
            originalDuration: take.duration,
            selection: range,
            mode: .trimmed
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                trimSummary

                PlayerLayerView(player: playback.player)
                    .aspectRatio(format == .portrait ? 9 / 16 : 16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: format == .portrait ? 300 : 220)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                previewControls

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Adjust silence")
                            .font(.headline)
                        Spacer()
                        Button(presentation.resetActionTitle, systemImage: "arrow.counterclockwise") {
                            editor.resetToSuggestion()
                            playback.updateSelection(editor.selection)
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(!presentation.showsResetAction)
                    }

                    TrimWaveform(
                        envelope: envelope,
                        start: editor.selection.start.seconds,
                        end: editor.selection.end.seconds,
                        duration: take.duration,
                        accessibilityValue: presentation.waveformAccessibilityValue,
                        onStartChanged: updateStart,
                        onEndChanged: updateEnd
                    )
                    .frame(height: 108)

                    HStack {
                        Label(
                            "Remove \(RecordingDurationFormatter.clock(editor.leadingRemoval)) start",
                            systemImage: "arrow.right.to.line"
                        )
                        Spacer()
                        Label(
                            "Remove \(RecordingDurationFormatter.clock(editor.trailingRemoval)) end",
                            systemImage: "arrow.left.to.line"
                        )
                    }
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .padding(.bottom, 72)
        }
        .safeAreaInset(edge: .bottom) { decisionBar }
        .navigationTitle("Silence Trim")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("\(remainingCount) to review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { playback.pause() }
    }

    private var trimSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.summaryTitle)
                .font(.title3.bold())
            HStack(spacing: 18) {
                Label(
                    "Keep \(presentation.keptDuration)",
                    systemImage: "checkmark.circle.fill"
                )
                Label(
                    "Remove \(presentation.removedDuration)",
                    systemImage: "waveform.slash"
                )
            }
            .font(.subheadline.weight(.semibold))
            Label("The original Take always stays unchanged.", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var presentation: SilenceTrimPresentation {
        SilenceTrimPresentation(editor: editor, suggestionWasDetected: suggestionWasDetected)
    }

    private var previewControls: some View {
        VStack(spacing: 12) {
            Picker("Preview", selection: Binding(
                get: { playback.mode },
                set: playback.setPreviewMode
            )) {
                ForEach(TakePreviewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Compare the untouched Take with the proposed trim")

            Slider(
                value: Binding(get: { playback.currentTime }, set: playback.seek),
                in: playback.activeStart...max(playback.activeStart + 0.01, playback.activeEnd)
            )
            .accessibilityLabel("Preview position")
            .accessibilityValue(RecordingDurationFormatter.clock(playback.currentTime))

            HStack {
                Text(RecordingDurationFormatter.clock(playback.currentTime))
                    .monospacedDigit()
                Spacer()
                Button(
                    playback.isPlaying ? "Pause" : "Play \(playback.mode.rawValue)",
                    systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                ) {
                    playback.togglePlayback()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Text(RecordingDurationFormatter.clock(playback.activeEnd - playback.activeStart))
                    .monospacedDigit()
            }
            .font(.subheadline)
        }
    }

    private func updateStart(_ value: TimeInterval) {
        editor.setSelectionStart(value)
        playback.updateSelection(editor.selection)
    }

    private func updateEnd(_ value: TimeInterval) {
        editor.setSelectionEnd(value)
        playback.updateSelection(editor.selection)
    }

    private var decisionBar: some View {
        HStack(spacing: 12) {
            Button("Keep Original", action: keepOriginal)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            Button("Use Trim") {
                useSelection(editor.selection)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(editor.removedDuration < 0.02)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .accessibilityIdentifier("silence-trim-decisions")
    }

}

private struct TrimWaveform: View {
    let envelope: [Float]
    let start: TimeInterval
    let end: TimeInterval
    let duration: TimeInterval
    let accessibilityValue: String
    let onStartChanged: (TimeInterval) -> Void
    let onEndChanged: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let startX = width * start / max(duration, 0.001)
            let endX = width * end / max(duration, 0.001)
            ZStack {
                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        guard !envelope.isEmpty else { return }
                        for (index, level) in envelope.enumerated() {
                            let x = size.width * (CGFloat(index) + 0.5) / CGFloat(envelope.count)
                            let height = max(3, size.height * CGFloat(level))
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: (size.height - height) / 2))
                            path.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
                            context.stroke(
                                path,
                                with: .color(.accentColor.opacity(0.82)),
                                lineWidth: max(1, size.width / CGFloat(envelope.count) * 0.58)
                            )
                        }
                    }
                    Color.black.opacity(0.58).frame(width: max(0, startX))
                    Color.black.opacity(0.58)
                        .frame(width: max(0, width - endX))
                        .offset(x: endX)
                }
                .frame(height: 86)
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.secondary.opacity(0.35)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Audio waveform and selected range")
                .accessibilityValue(accessibilityValue)

                trimHandle(
                    label: "Trim start",
                    value: start,
                    position: startX,
                    width: width,
                    onChange: onStartChanged
                )
                trimHandle(
                    label: "Trim end",
                    value: end,
                    position: endX,
                    width: width,
                    onChange: onEndChanged
                )
            }
            .coordinateSpace(name: "trim-waveform")
        }
    }

    private func trimHandle(
        label: String,
        value: TimeInterval,
        position: CGFloat,
        width: CGFloat,
        onChange: @escaping (TimeInterval) -> Void
    ) -> some View {
        let hitCenter = min(max(22, position), max(22, width - 22))
        return ZStack {
            Color.clear
            Capsule()
                .fill(Color.white)
                .frame(width: 10, height: 86)
                .overlay(Capsule().stroke(Color.black.opacity(0.35), lineWidth: 1))
                .shadow(radius: 2)
                .offset(x: position - hitCenter)
        }
        .frame(width: 44, height: 108)
        .contentShape(Rectangle())
        .position(x: hitCenter, y: 54)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("trim-waveform"))
                .onChanged { drag in
                    let seconds = min(max(0, drag.location.x / max(width, 1) * duration), duration)
                    onChange(seconds)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(RecordingDurationFormatter.clock(value))
        .accessibilityHint("Swipe up or down to adjust")
        .accessibilityAdjustableAction { direction in
            let step = max(0.1, duration / 100)
            switch direction {
            case .increment: onChange(value + step)
            case .decrement: onChange(value - step)
            @unknown default: break
            }
        }
    }
}
