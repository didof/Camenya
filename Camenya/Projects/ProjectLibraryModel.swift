import Foundation

@MainActor
final class ProjectLibraryModel: ObservableObject {
    @Published private(set) var projects: [ProjectManifest] = []
    @Published var errorMessage: String?

    let store: ProjectStore

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
    }

    func load() {
        do {
            try store.finishPendingDeletions()
            store.finishCompletedExports()
            try store.migrateLegacyRecordingsIfNeeded()
            projects = try store.projects()
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
            projects.removeAll { $0.id == id }
        } catch {
            errorMessage = "The Project couldn't be deleted completely. Camenya will retry safely."
            load()
        }
    }

    func upsertAndSort(_ project: ProjectManifest) {
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        projects.sort {
            if $0.modifiedAt == $1.modifiedAt { return $0.createdAt > $1.createdAt }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    func storageBytes(for project: ProjectManifest) -> Int64 {
        store.storageBytes(projectID: project.id)
    }
}
