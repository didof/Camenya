import SwiftUI

struct ProjectLibraryScreen: View {
    @ObservedObject var model: ProjectLibraryModel
    @State private var createdProject: ProjectManifest?
    @State private var renamingProject: ProjectManifest?
    @State private var deletingProject: ProjectManifest?
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        createdProject = model.createProject()
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(item: $createdProject) { project in
                ProjectWorkspaceScreen(project: project, library: model)
            }
        }
        .task { model.load() }
        .alert("Rename Project", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("Project name", text: $draftName)
            Button("Cancel", role: .cancel) { renamingProject = nil }
            Button("Save") {
                if let project = renamingProject, !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.renameProject(id: project.id, name: draftName.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                renamingProject = nil
            }
        }
        .confirmationDialog("Delete Project?", isPresented: Binding(
            get: { deletingProject != nil },
            set: { if !$0 { deletingProject = nil } }
        ), titleVisibility: .visible) {
            if let project = deletingProject {
                Button("Delete \(project.takes.count) Takes Permanently", role: .destructive) {
                    model.deleteProject(id: project.id)
                    deletingProject = nil
                }
            }
            Button("Cancel", role: .cancel) { deletingProject = nil }
        } message: {
            if let project = deletingProject {
                Text("This permanently removes \(project.takes.count) Takes and \(ByteCountFormatter.string(fromByteCount: model.storageBytes(for: project), countStyle: .file)) of recordings, thumbnails, and temporary files owned by the Project.")
            }
        }
        .alert("Camenya", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var projectList: some View {
        List {
            ForEach(model.projects) { project in
                NavigationLink {
                    ProjectWorkspaceScreen(project: project, library: model)
                } label: {
                    ProjectRow(
                        project: project,
                        thumbnailURL: project.takes.first.map {
                            model.store.takeThumbnailURL(projectID: project.id, takeID: $0.id)
                        },
                        storageBytes: model.storageBytes(for: project)
                    )
                }
                .accessibilityAction(named: "Rename") {
                    draftName = project.name
                    renamingProject = project
                }
                .accessibilityAction(named: "Delete") {
                    deletingProject = project
                }
                .contextMenu {
                    Button {
                        draftName = project.name
                        renamingProject = project
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) {
                        deletingProject = project
                    } label: { Label("Delete Project", systemImage: "trash") }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { deletingProject = project } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        draftName = project.name
                        renamingProject = project
                    } label: { Label("Rename", systemImage: "pencil") }
                    .tint(.indigo)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Record several Takes, arrange them, and export one finished movie when you're ready.")
        } actions: {
            Button("New Project") { createdProject = model.createProject() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectManifest
    let thumbnailURL: URL?
    let storageBytes: Int64

    private var presentation: ProjectRowPresentation {
        ProjectRowPresentation(
            project: project,
            storageBytes: storageBytes,
            modifiedAtDescription: project.modifiedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.gradient)
                .frame(width: 76, height: 58)
                .overlay {
                    TakeThumbnailView(
                        url: thumbnailURL,
                        placeholderSystemName: project.takes.isEmpty ? "video.badge.plus" : "play.rectangle.fill",
                        cornerRadius: 12
                    )
                    .font(.title2)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(project.name).font(.headline).lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(project.takes.count) \(project.takes.count == 1 ? "Take" : "Takes")")
                    Text(RecordingDurationFormatter.clock(project.approximateDuration))
                    if let format = project.format { Text(format.rawValue.capitalized) }
                    Text(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.accessibilityHint)
    }

}

private struct ProjectWorkspaceScreen: View {
    @StateObject private var recorder: AppModel
    @Environment(\.dismiss) private var dismiss

    init(project: ProjectManifest, library: ProjectLibraryModel) {
        _recorder = StateObject(wrappedValue: AppModel(
            project: project,
            projectStore: library.store,
            onProjectChanged: { library.upsertAndSort($0) }
        ))
    }

    var body: some View {
        CameraScreen(model: recorder, onBack: { recorder.leaveProject { dismiss() } })
            .navigationBarBackButtonHidden(true)
            .task { recorder.configure() }
    }
}
