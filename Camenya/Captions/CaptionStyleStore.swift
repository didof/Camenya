import Foundation

struct SavedCaptionStyle: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var customization: CaptionStyleCustomization

    init(
        id: UUID = UUID(),
        name: String,
        customization: CaptionStyleCustomization
    ) {
        self.id = id
        self.name = name
        self.customization = customization
    }
}

struct CaptionStyleStore {
    private static let key = "captions.saved-styles.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [SavedCaptionStyle] {
        guard let data = defaults.data(forKey: Self.key),
              let styles = try? JSONDecoder().decode([SavedCaptionStyle].self, from: data) else {
            return []
        }
        return styles
    }

    @discardableResult
    func save(name: String, customization: CaptionStyleCustomization) -> SavedCaptionStyle {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var styles = load()
        let existingIndex = styles.firstIndex {
            $0.name.compare(normalizedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let style = SavedCaptionStyle(
            id: existingIndex.map { styles[$0].id } ?? UUID(),
            name: normalizedName,
            customization: customization
        )
        if let existingIndex {
            styles[existingIndex] = style
        } else {
            styles.append(style)
        }
        persist(styles)
        return style
    }

    func delete(id: UUID) {
        persist(load().filter { $0.id != id })
    }

    private func persist(_ styles: [SavedCaptionStyle]) {
        guard let data = try? JSONEncoder().encode(styles) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

enum CaptionSavedStyleResolver {
    static func customization(
        for style: SavedCaptionStyle,
        sharedAppearances: [SavedTextAppearance]
    ) -> CaptionStyleCustomization {
        guard let shared = sharedAppearances.first(where: {
            $0.name.compare(style.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            return style.customization
        }
        return shared.appearance.applying(to: style.customization)
    }
}
