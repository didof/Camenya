import Foundation

struct SavedTextAppearance: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var appearance: TextAppearance
}

struct TextAppearanceStore {
    private static let key = "finishing.saved-text-appearances.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [SavedTextAppearance] {
        guard let data = defaults.data(forKey: Self.key),
              let values = try? JSONDecoder().decode([SavedTextAppearance].self, from: data) else {
            return []
        }
        return values
    }

    @discardableResult
    func save(name: String, appearance: TextAppearance) -> SavedTextAppearance {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var values = load()
        let index = values.firstIndex {
            $0.name.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let saved = SavedTextAppearance(
            id: index.map { values[$0].id } ?? UUID(),
            name: normalized,
            appearance: appearance
        )
        if let index { values[index] = saved } else { values.append(saved) }
        persist(values)
        return saved
    }

    func delete(id: UUID) {
        persist(load().filter { $0.id != id })
    }

    func delete(name: String) {
        persist(load().filter {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        })
    }

    private func persist(_ values: [SavedTextAppearance]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
