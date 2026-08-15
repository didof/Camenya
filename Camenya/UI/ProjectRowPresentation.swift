import Foundation

struct ProjectRowPresentation: Equatable, Sendable {
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityHint: String

    init(
        project: ProjectManifest,
        storageBytes: Int64,
        modifiedAtDescription: String,
        storageDescription: String? = nil
    ) {
        accessibilityLabel = project.name

        var parts: [String] = []
        let takeCount = project.takes.count
        if takeCount == 0 {
            parts.append("No Takes")
        } else {
            parts.append("\(takeCount) \(takeCount == 1 ? "Take" : "Takes")")
        }
        parts.append(RecordingDurationFormatter.clock(project.approximateDuration))
        if let format = project.format {
            parts.append(format.rawValue.capitalized)
        }
        parts.append(
            storageDescription
                ?? ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file)
        )
        parts.append("Modified \(modifiedAtDescription)")

        accessibilityValue = parts.joined(separator: ", ")
        accessibilityHint = "Opens the Project"
    }
}
