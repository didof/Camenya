import Foundation

enum ProjectDestination: Equatable, Sendable {
    case workspace
    case capture
}

struct ProjectCoverSource: Equatable, Sendable {
    let clipID: TimelineClip.ID
    let take: ProjectTake
    let sourceTime: MediaTime
}

enum ProjectViewerPrimaryAction: Equatable, Sendable {
    case togglePlayback
    case retryPreparation
}

enum ProjectCaptionWorkspaceAction: Equatable, Sendable {
    case reviewVideo
    case createCaptions
    case openCaptionEditor
}

enum ProjectSpokenLanguageSource: Equatable, Sendable {
    case projectDefault
    case takeOverride
}

struct ProjectSpokenLanguagePresentation: Equatable, Sendable {
    let effectiveIdentifier: String
    let source: ProjectSpokenLanguageSource
}

enum ProjectPresentationPolicy {
    static func captionLanguageIdentifiers(
        including persistedIdentifiers: [String],
        currentLocaleIdentifier: String = Locale.current.identifier
    ) -> [String] {
        let defaults = ["en-US", "en-GB", "it-IT", "de-DE", "fr-FR", "es-ES"]
        var seen = Set<String>()
        return ([currentLocaleIdentifier] + persistedIdentifiers + defaults).compactMap { identifier in
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKey = trimmed.replacingOccurrences(of: "_", with: "-").lowercased()
            guard !trimmed.isEmpty, seen.insert(normalizedKey).inserted else { return nil }
            return trimmed
        }
    }

    static func coverTake(in project: ProjectManifest) -> ProjectTake? {
        coverSource(in: project)?.take
    }

    static func coverSource(in project: ProjectManifest) -> ProjectCoverSource? {
        guard let leadingClip = project.primaryStoryline.clips.first,
              let take = project.takes.first(where: { $0.id == leadingClip.takeID }) else {
            return nil
        }
        return ProjectCoverSource(
            clipID: leadingClip.id,
            take: take,
            sourceTime: leadingClip.selection.start
        )
    }

    static func initialDestination(newlyCreated: Bool) -> ProjectDestination {
        newlyCreated ? .capture : .workspace
    }

    static func viewerPrimaryAction(isPreparationFailed: Bool) -> ProjectViewerPrimaryAction {
        isPreparationFailed ? .retryPreparation : .togglePlayback
    }

    static func captionWorkspaceAction(
        isPictureLocked: Bool,
        isReadyForPictureLock: Bool
    ) -> ProjectCaptionWorkspaceAction {
        if isPictureLocked { return .openCaptionEditor }
        return isReadyForPictureLock ? .createCaptions : .reviewVideo
    }

    static func spokenLanguagePresentation(
        projectDefaultIdentifier: String,
        takeOverrideIdentifier: String?
    ) -> ProjectSpokenLanguagePresentation {
        guard let override = takeOverrideIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return ProjectSpokenLanguagePresentation(
                effectiveIdentifier: projectDefaultIdentifier,
                source: .projectDefault
            )
        }
        return ProjectSpokenLanguagePresentation(
            effectiveIdentifier: override,
            source: .takeOverride
        )
    }

    static func canAddFullTakeToStoryline(
        takeID: UUID,
        in project: ProjectManifest
    ) -> Bool {
        project.takes.contains(where: { $0.id == takeID })
            && !project.primaryStoryline.clips.contains(where: { $0.takeID == takeID })
    }

    static func shouldHideViewerControls(
        isPlaying: Bool,
        revealStartedAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard isPlaying, let revealStartedAt else { return false }
        return now - revealStartedAt >= 2
    }

    static func shouldDiscardDraft(
        _ project: ProjectManifest,
        hasRecoverableMedia: Bool
    ) -> Bool {
        project.isAutomaticallyNamed
            && project.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && project.takes.isEmpty
            && project.primaryStoryline.clips.isEmpty
            && project.removedClips.isEmpty
            && !hasRecoverableMedia
    }

}
