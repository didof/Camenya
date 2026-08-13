import Foundation

@MainActor
final class ProjectNoteStore: ObservableObject {
    @Published var text: String {
        didSet { onChange(text) }
    }

    private var onChange: @MainActor (String) -> Void

    init(text: String = "", onChange: @escaping @MainActor (String) -> Void = { _ in }) {
        self.text = text
        self.onChange = onChange
    }

    func setOnChange(_ onChange: @escaping @MainActor (String) -> Void) {
        self.onChange = onChange
    }
}
