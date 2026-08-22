import Foundation

struct NormalizedProjectPoint: Codable, Equatable, Hashable, Sendable {
    let x: Double
    let y: Double

    var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }
}

enum TextFontDesign: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case system, rounded, serif, monospaced
}

enum TextFontWeight: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case regular, semibold, bold, heavy
}

enum TextFontScale: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case small, standard, large
}

struct TextColor: Codable, Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let white = TextColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let yellow = TextColor(red: 1, green: 0.8, blue: 0, alpha: 1)

    var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

enum TextOutlineStyle: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case none, thin, strong
}

enum TextBackgroundStyle: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case none, shadow, roundedBox
}

enum TextHorizontalAlignment: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case leading, center, trailing
}

struct TextAppearance: Codable, Equatable, Hashable, Sendable {
    var fontDesign: TextFontDesign
    var fontWeight: TextFontWeight
    var fontScale: TextFontScale
    var color: TextColor
    var outline: TextOutlineStyle
    var background: TextBackgroundStyle
    var alignment: TextHorizontalAlignment

    static let `default` = TextAppearance(
        fontDesign: .system,
        fontWeight: .bold,
        fontScale: .standard,
        color: .white,
        outline: .thin,
        background: .shadow,
        alignment: .center
    )

    var isValid: Bool { color.isValid }
}

extension TextAppearance {
    init(captionCustomization: CaptionStyleCustomization) {
        let design: TextFontDesign = switch captionCustomization.fontDesign {
        case .system: .system
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        let scale: TextFontScale = switch captionCustomization.fontScale {
        case .small: .small
        case .standard: .standard
        case .large: .large
        }
        let color: TextColor = switch captionCustomization.textColor {
        case .white: .white
        case .yellow: .yellow
        case .custom: captionCustomization.customTextColor ?? .white
        }
        let background: TextBackgroundStyle = switch captionCustomization.background {
        case .none: .none
        case .shadow: .shadow
        case .roundedBox: .roundedBox
        }
        self.init(
            fontDesign: design,
            fontWeight: captionCustomization.fontWeight ?? .bold,
            fontScale: scale,
            color: color,
            outline: captionCustomization.outline ?? .none,
            background: background,
            alignment: captionCustomization.alignment ?? .center
        )
    }

    var captionCustomization: CaptionStyleCustomization {
        var customization = CaptionStyleCustomization()
        customization.fontDesign = switch fontDesign {
        case .system: .system
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        customization.fontScale = switch fontScale {
        case .small: .small
        case .standard: .standard
        case .large: .large
        }
        if color == .white {
            customization.textColor = .white
        } else if color == .yellow {
            customization.textColor = .yellow
        } else {
            customization.textColor = .custom
            customization.customTextColor = color
        }
        customization.outline = outline
        customization.fontWeight = fontWeight
        customization.alignment = alignment
        customization.background = switch background {
        case .none: .none
        case .shadow: .shadow
        case .roundedBox: .roundedBox
        }
        return customization
    }

    func applying(to current: CaptionStyleCustomization) -> CaptionStyleCustomization {
        let mapped = captionCustomization
        var result = current
        result.fontDesign = mapped.fontDesign
        result.fontScale = mapped.fontScale
        result.textColor = mapped.textColor
        result.customTextColor = mapped.customTextColor
        result.outline = mapped.outline
        result.background = mapped.background
        result.fontWeight = mapped.fontWeight
        result.alignment = mapped.alignment
        return result
    }
}

struct ProjectTextOverlay: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var text: String
    var range: ProjectTimeRange
    var center: NormalizedProjectPoint
    var appearance: TextAppearance

    init(
        id: UUID = UUID(),
        text: String,
        range: ProjectTimeRange,
        center: NormalizedProjectPoint,
        appearance: TextAppearance
    ) {
        self.id = id
        self.text = text
        self.range = range
        self.center = center
        self.appearance = appearance
    }

    func isValid(inside duration: TimeInterval) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty
            && range.start.seconds.isFinite
            && range.end.seconds.isFinite
            && range.start.seconds >= 0
            && range.end.seconds <= duration
            && range.end.seconds > range.start.seconds
            && center.isValid
            && appearance.isValid
    }
}

struct ProjectFinishingTimeline: Equatable, Sendable {
    let pictureLockID: UUID
    let duration: TimeInterval
    let textOverlays: [ProjectTextOverlay]
    let captions: ProjectCaptionExportTimeline?

    func activeTextOverlays(at projectTime: TimeInterval) -> [ProjectTextOverlay] {
        textOverlays.filter {
            projectTime >= $0.range.start.seconds && projectTime < $0.range.end.seconds
        }
    }
}

enum TextOverlayEditorPresentationPolicy {
    static func showsVideoPreview(isTextFieldFocused: Bool) -> Bool {
        !isTextFieldFocused
    }

    static func positionAccessibilityLabel(text: String) -> String {
        "Text overlay: \(text)"
    }

    static func shouldCommitDraftBeforeDeletion(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let timelineAccessibilityLabel = "Text overlay timeline"
}

enum TextOverlayEditorError: Error, Equatable {
    case overlayNotFound
    case invalidOverlay
}

struct TextOverlayHistoryOperation: Equatable, Sendable {
    let name: String
}

struct TextOverlayEditorState: Equatable, Sendable {
    private struct HistoryEntry: Equatable, Sendable {
        let name: String
        let before: [ProjectTextOverlay]
        let after: [ProjectTextOverlay]
    }

    private(set) var overlays: [ProjectTextOverlay]
    let duration: TimeInterval
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []

    init(overlays: [ProjectTextOverlay], duration: TimeInterval) {
        self.overlays = overlays
        self.duration = max(0, duration)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    mutating func addOverlay(
        at projectTime: TimeInterval,
        text: String = "Text"
    ) -> ProjectTextOverlay {
        let start = min(max(0, projectTime), max(0, duration - 0.1))
        let end = min(duration, max(start + 0.1, start + 3))
        let overlay = ProjectTextOverlay(
            text: text,
            range: ProjectTimeRange(
                start: ProjectTime(seconds: start),
                end: ProjectTime(seconds: end)
            ),
            center: NormalizedProjectPoint(x: 0.5, y: 0.5),
            appearance: .default
        )
        commit(name: "Add Text") { $0.append(overlay) }
        return overlay
    }

    mutating func updateText(id: UUID, text: String) throws {
        try update(id: id, name: "Edit Text") { $0.text = text }
    }

    mutating func updateAppearance(id: UUID, appearance: TextAppearance) throws {
        try update(id: id, name: "Change Style") { $0.appearance = appearance }
    }

    mutating func updatePosition(id: UUID, center: NormalizedProjectPoint) throws {
        try update(id: id, name: "Move Text") { $0.center = center }
    }

    mutating func updatePositionTransient(id: UUID, center: NormalizedProjectPoint) throws {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else {
            throw TextOverlayEditorError.overlayNotFound
        }
        let previous = overlays[index]
        overlays[index].center = center
        guard overlays[index].isValid(inside: duration) else {
            overlays[index] = previous
            throw TextOverlayEditorError.invalidOverlay
        }
    }

    mutating func updateRange(id: UUID, start: TimeInterval, end: TimeInterval) throws {
        try update(id: id, name: "Adjust Timing") {
            $0.range = ProjectTimeRange(
                start: ProjectTime(seconds: start),
                end: ProjectTime(seconds: end)
            )
        }
    }

    mutating func updateRangeTransient(id: UUID, start: TimeInterval, end: TimeInterval) throws {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else {
            throw TextOverlayEditorError.overlayNotFound
        }
        let previous = overlays[index]
        overlays[index].range = ProjectTimeRange(
            start: ProjectTime(seconds: start),
            end: ProjectTime(seconds: end)
        )
        guard overlays[index].isValid(inside: duration) else {
            overlays[index] = previous
            throw TextOverlayEditorError.invalidOverlay
        }
    }

    mutating func commitTransientChange(
        name: String,
        from before: [ProjectTextOverlay]
    ) {
        record(name: name, before: before)
    }

    mutating func nudgeStart(id: UUID, by delta: TimeInterval) throws {
        guard let overlay = overlays.first(where: { $0.id == id }) else {
            throw TextOverlayEditorError.overlayNotFound
        }
        try updateRange(
            id: id,
            start: overlay.range.start.seconds + delta,
            end: overlay.range.end.seconds
        )
    }

    mutating func nudgeEnd(id: UUID, by delta: TimeInterval) throws {
        guard let overlay = overlays.first(where: { $0.id == id }) else {
            throw TextOverlayEditorError.overlayNotFound
        }
        try updateRange(
            id: id,
            start: overlay.range.start.seconds,
            end: overlay.range.end.seconds + delta
        )
    }

    @discardableResult
    mutating func duplicate(id: UUID) throws -> ProjectTextOverlay {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else {
            throw TextOverlayEditorError.overlayNotFound
        }
        var copy = overlays[index]
        copy = ProjectTextOverlay(
            text: copy.text,
            range: copy.range,
            center: NormalizedProjectPoint(
                x: min(1, copy.center.x + 0.04),
                y: min(1, copy.center.y + 0.04)
            ),
            appearance: copy.appearance
        )
        commit(name: "Duplicate Text") { $0.insert(copy, at: index + 1) }
        return copy
    }

    mutating func delete(id: UUID) throws {
        guard overlays.contains(where: { $0.id == id }) else {
            throw TextOverlayEditorError.overlayNotFound
        }
        commit(name: "Delete Text") { $0.removeAll(where: { $0.id == id }) }
    }

    mutating func moveForward(id: UUID) throws {
        try move(id: id, offset: 1, name: "Bring Forward")
    }

    mutating func moveBackward(id: UUID) throws {
        try move(id: id, offset: -1, name: "Send Backward")
    }

    @discardableResult
    mutating func undo() -> TextOverlayHistoryOperation? {
        guard let entry = undoStack.popLast() else { return nil }
        overlays = entry.before
        redoStack.append(entry)
        return TextOverlayHistoryOperation(name: entry.name)
    }

    @discardableResult
    mutating func redo() -> TextOverlayHistoryOperation? {
        guard let entry = redoStack.popLast() else { return nil }
        overlays = entry.after
        undoStack.append(entry)
        return TextOverlayHistoryOperation(name: entry.name)
    }

    private mutating func update(
        id: UUID,
        name: String,
        mutation: (inout ProjectTextOverlay) -> Void
    ) throws {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else {
            throw TextOverlayEditorError.overlayNotFound
        }
        let before = overlays
        mutation(&overlays[index])
        guard overlays[index].isValid(inside: duration) else {
            overlays = before
            throw TextOverlayEditorError.invalidOverlay
        }
        record(name: name, before: before)
    }

    private mutating func move(id: UUID, offset: Int, name: String) throws {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else {
            throw TextOverlayEditorError.overlayNotFound
        }
        let destination = index + offset
        guard overlays.indices.contains(destination) else { return }
        commit(name: name) { values in
            let value = values.remove(at: index)
            values.insert(value, at: destination)
        }
    }

    private mutating func commit(
        name: String,
        mutation: (inout [ProjectTextOverlay]) -> Void
    ) {
        let before = overlays
        mutation(&overlays)
        record(name: name, before: before)
    }

    private mutating func record(name: String, before: [ProjectTextOverlay]) {
        guard before != overlays else { return }
        undoStack.append(HistoryEntry(name: name, before: before, after: overlays))
        redoStack.removeAll()
    }
}
