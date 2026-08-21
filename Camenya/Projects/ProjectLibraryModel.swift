import Foundation

@MainActor
final class ProjectLibraryModel: ObservableObject {
    private struct CoverState {
        var source: ProjectCoverSource
        var generatedURL: URL?
        var task: Task<Void, Never>?
    }

    @Published private(set) var projects: [ProjectManifest] = []
    @Published var errorMessage: String?
    @Published private var coverStates: [UUID: CoverState] = [:]

    let store: ProjectStore

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
    }

    func load() {
        do {
            try store.finishPendingDeletions()
            store.finishCompletedExports()
            try store.migrateLegacyRecordingsIfNeeded()
            projects = try removingContentlessDrafts(from: store.projects())
            projects.forEach(refreshCover)
        } catch {
            errorMessage = "The Project Library couldn't be loaded."
        }
    }

    func createProject() -> ProjectManifest? {
        do {
            let project = try store.createProject()
            upsertAndSort(project)
            return project
        } catch {
            errorMessage = "A new Project couldn't be created."
            return nil
        }
    }

    func renameProject(id: UUID, name: String) {
        do { upsertAndSort(try store.renameProject(id: id, name: name)) }
        catch { errorMessage = "The Project couldn't be renamed." }
    }

    func deleteProject(id: UUID) {
        do {
            try store.deleteProject(id: id)
            removeCoverState(for: id)
            projects.removeAll { $0.id == id }
        } catch {
            errorMessage = "The Project couldn't be deleted completely. Camenya will retry safely."
            load()
        }
    }

    func projectDidClose(id: UUID) {
        do {
            let project = try store.load(id: id)
            let hasRecoverableMedia = (try? store.hasRecoverableArtifacts(projectID: id)) ?? true
            if ProjectPresentationPolicy.shouldDiscardDraft(
                project,
                hasRecoverableMedia: hasRecoverableMedia
            ) {
                try store.deleteProject(id: id)
                removeCoverState(for: id)
                projects.removeAll { $0.id == id }
            } else {
                upsertAndSort(project)
            }
        } catch ProjectStoreError.projectNotFound {
            projects.removeAll { $0.id == id }
        } catch {
            errorMessage = "The Project Library couldn't be refreshed."
        }
    }

    func upsertAndSort(_ project: ProjectManifest) {
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        projects.sort {
            if $0.modifiedAt == $1.modifiedAt { return $0.createdAt > $1.createdAt }
            return $0.modifiedAt > $1.modifiedAt
        }
        refreshCover(project)
    }

    func coverThumbnailURL(for project: ProjectManifest) -> URL? {
        if let generatedCoverURL = coverStates[project.id]?.generatedURL {
            return generatedCoverURL
        }
        return ProjectPresentationPolicy.coverTake(in: project).map {
            store.takeThumbnailURL(projectID: project.id, takeID: $0.id)
        }
    }

    private func refreshCover(_ project: ProjectManifest) {
        guard let source = ProjectPresentationPolicy.coverSource(in: project) else {
            removeCoverState(for: project.id)
            try? FileManager.default.removeItem(at: store.projectCoverURL(projectID: project.id))
            return
        }
        if let current = coverStates[project.id], current.source == source {
            guard current.generatedURL == nil, current.task == nil else { return }
        } else {
            removeCoverState(for: project.id)
            coverStates[project.id] = CoverState(source: source, generatedURL: nil, task: nil)
        }

        let movieURL = store.takeMovieURL(projectID: project.id, takeID: source.take.id)
        let destination = store.projectCoverURL(projectID: project.id)
        coverStates[project.id]?.task = Task { [weak self] in
            do {
                try await TakeThumbnailGenerator().generate(
                    movieAt: movieURL,
                    destination: destination,
                    sourceTime: source.sourceTime
                )
                try Task.checkCancellation()
                guard let self, self.coverStates[project.id]?.source == source else { return }
                self.coverStates[project.id]?.task = nil
                self.coverStates[project.id]?.generatedURL = destination
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.coverStates[project.id]?.source == source else { return }
                self.coverStates[project.id]?.task = nil
            }
        }
    }

    private func removeCoverState(for projectID: UUID) {
        coverStates[projectID]?.task?.cancel()
        coverStates[projectID] = nil
    }

    private func removingContentlessDrafts(
        from loadedProjects: [ProjectManifest]
    ) throws -> [ProjectManifest] {
        var projectsToKeep: [ProjectManifest] = []
        for project in loadedProjects {
            let hasRecoverableMedia = (
                try? store.hasRecoverableArtifacts(projectID: project.id)
            ) ?? true
            if ProjectPresentationPolicy.shouldDiscardDraft(
                project,
                hasRecoverableMedia: hasRecoverableMedia
            ) {
                try store.deleteProject(id: project.id)
            } else {
                projectsToKeep.append(project)
            }
        }
        return projectsToKeep
    }
}
