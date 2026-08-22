import Foundation

struct ProjectNoteNavigationState: Equatable, Sendable {
    var cursorUTF16Offset: Int = 0
    var verticalScrollOffset: Double = 0

    func normalized(for text: String) -> Self {
        Self(
            cursorUTF16Offset: min(max(cursorUTF16Offset, 0), text.utf16.count),
            verticalScrollOffset: max(verticalScrollOffset, 0)
        )
    }
}

@MainActor
final class ProjectNoteStore: ObservableObject {
    @Published var text: String {
        didSet { onChange(text) }
    }

    private var onChange: @MainActor (String) -> Void
    private var noteNavigationState = ProjectNoteNavigationState()

    init(text: String = "", onChange: @escaping @MainActor (String) -> Void = { _ in }) {
        self.text = text
        self.onChange = onChange
    }

    func setOnChange(_ onChange: @escaping @MainActor (String) -> Void) {
        self.onChange = onChange
    }

    func rememberNavigation(cursorUTF16Offset: Int, verticalScrollOffset: Double) {
        noteNavigationState = ProjectNoteNavigationState(
            cursorUTF16Offset: cursorUTF16Offset,
            verticalScrollOffset: verticalScrollOffset
        ).normalized(for: text)
    }

    func navigationState(for text: String) -> ProjectNoteNavigationState {
        noteNavigationState.normalized(for: text)
    }
}
