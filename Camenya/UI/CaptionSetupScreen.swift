import SwiftUI

struct CaptionSetupScreen: View {
    let existingConfiguration: ProjectCaptionConfiguration?
    let captionedTakeCount: Int
    let totalTakeCount: Int
    let onStart: (ProjectCaptionConfiguration) -> Void
    let onRegenerateAll: (ProjectCaptionConfiguration) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var localeIdentifier: String
    @State private var placement: CaptionPlacementZone
    @State private var pendingRegeneration = false

    init(
        existingConfiguration: ProjectCaptionConfiguration?,
        captionedTakeCount: Int,
        totalTakeCount: Int,
        onStart: @escaping (ProjectCaptionConfiguration) -> Void,
        onRegenerateAll: @escaping (ProjectCaptionConfiguration) -> Void
    ) {
        self.existingConfiguration = existingConfiguration
        self.captionedTakeCount = captionedTakeCount
        self.totalTakeCount = totalTakeCount
        self.onStart = onStart
        self.onRegenerateAll = onRegenerateAll
        let initialLocale = existingConfiguration?.localeIdentifier
            ?? Self.supportedOptions.first?.identifier
            ?? "it-IT"
        _localeIdentifier = State(initialValue: initialLocale)
        _placement = State(initialValue: existingConfiguration?.placement ?? .lower)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let existingConfiguration {
                    Section("Current Captions") {
                        LabeledContent(
                            "Language",
                            value: localizedName(for: existingConfiguration.localeIdentifier)
                        )
                        LabeledContent(
                            "Transcribed Takes",
                            value: "\(captionedTakeCount) of \(totalTakeCount)"
                        )
                    }
                }
                Section {
                    Picker("Transcription language", selection: $localeIdentifier) {
                        ForEach(Self.supportedOptions) { option in
                            Text(option.name).tag(option.identifier)
                        }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("Choose the spoken language. Audio stays on this iPhone; iOS may download its local speech model after you tap Transcribe.")
                }
                Section("Placement") {
                    Picker("Caption position", selection: $placement) {
                        Text("Bottom").tag(CaptionPlacementZone.lower)
                        Text("Center").tag(CaptionPlacementZone.center)
                        Text("Top").tag(CaptionPlacementZone.upper)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Label("Every caption is reviewed before export", systemImage: "checkmark.bubble")
                    Label("Original Takes remain unchanged", systemImage: "lock.shield")
                }
                if captionedTakeCount > 0 {
                    Section {
                        Button("Regenerate All Captions", systemImage: "arrow.clockwise", role: .destructive) {
                            pendingRegeneration = true
                        }
                    } footer: {
                        Text("Regeneration replaces caption text, timing, and manual corrections for every Take. Recorded video remains unchanged.")
                    }
                }
            }
            .navigationTitle(existingConfiguration == nil ? "Create Captions" : "Caption Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(primaryActionTitle) {
                        if languageChanged, captionedTakeCount > 0 {
                            pendingRegeneration = true
                        } else {
                            start(regenerateAll: false)
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                languageChanged ? "Change language and regenerate captions?" : "Regenerate all captions?",
                isPresented: $pendingRegeneration,
                titleVisibility: .visible
            ) {
                Button(
                    languageChanged ? "Change Language & Regenerate" : "Regenerate All",
                    role: .destructive
                ) {
                    start(regenerateAll: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Existing caption text, timing, and corrections will be replaced. Original Takes stay unchanged.")
            }
        }
    }

    private var configuration: ProjectCaptionConfiguration {
        ProjectCaptionConfiguration(
            localeIdentifier: localeIdentifier,
            placement: placement
        )
    }

    private var languageChanged: Bool {
        guard let existingConfiguration else { return false }
        return existingConfiguration.localeIdentifier != localeIdentifier
    }

    private var primaryActionTitle: String {
        if languageChanged { return "Change & Regenerate" }
        return existingConfiguration == nil ? "Transcribe" : "Apply"
    }

    private func localizedName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func start(regenerateAll: Bool) {
        if regenerateAll { onRegenerateAll(configuration) }
        else { onStart(configuration) }
        dismiss()
    }

    private static let supportedOptions: [CaptionLocaleOption] = {
        let preferred = [Locale.current.identifier, "it-IT", "en-US", "en-GB", "es-ES", "fr-FR", "de-DE"]
        var seen = Set<String>()
        return preferred.compactMap { identifier in
            let canonical = Locale(identifier: identifier).identifier
            guard seen.insert(canonical).inserted else { return nil }
            return CaptionLocaleOption(
                identifier: canonical,
                name: Locale.current.localizedString(forIdentifier: canonical) ?? canonical
            )
        }
    }()
}

private struct CaptionLocaleOption: Identifiable {
    let identifier: String
    let name: String
    var id: String { identifier }
}
