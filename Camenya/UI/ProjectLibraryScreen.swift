import SwiftUI

struct ProjectLibraryScreen: View {
    @ObservedObject var model: ProjectLibraryModel
    @State private var destination: ProjectRoute?
    @State private var renamingProject: ProjectManifest?
    @State private var deletingProject: ProjectManifest?
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.projects.isEmpty {
                    emptyState
                } else {
                    projectGrid
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: createProject) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Project")
                }
            }
            .navigationDestination(item: $destination) { route in
                ProjectWorkspaceScreen(
                    project: route.project,
                    library: model,
                    initialDestination: ProjectPresentationPolicy.initialDestination(
                        newlyCreated: route.newlyCreated
                    )
                )
            }
        }
        .task { model.load() }
        .alert("Rename Project", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("Project name", text: $draftName)
            Button("Cancel", role: .cancel) { renamingProject = nil }
            Button("Rename", action: commitRename)
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Delete Project?",
            isPresented: Binding(
                get: { deletingProject != nil },
                set: { if !$0 { deletingProject = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let project = deletingProject {
                Button("Delete Project", role: .destructive) {
                    model.deleteProject(id: project.id)
                    deletingProject = nil
                }
            }
            Button("Cancel", role: .cancel) { deletingProject = nil }
        } message: {
            Text("This deletes the Project and every recording and file it owns. This can't be undone.")
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

    private var projectGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                alignment: .leading,
                spacing: 22
            ) {
                ForEach(model.projects) { project in
                    Button {
                        destination = ProjectRoute(project: project, newlyCreated: false)
                    } label: {
                        ProjectLibraryCard(
                            project: project,
                            thumbnailURL: model.coverThumbnailURL(for: project)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            beginRename(project)
                        }
                        Button("Delete Project", systemImage: "trash", role: .destructive) {
                            deletingProject = project
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "movieclapper")
        } description: {
            Text("Create a Project to record your next video.")
        } actions: {
            Button("New Project", systemImage: "plus", action: createProject)
                .buttonStyle(.borderedProminent)
        }
    }

    private func createProject() {
        guard let project = model.createProject() else { return }
        destination = ProjectRoute(project: project, newlyCreated: true)
    }

    private func beginRename(_ project: ProjectManifest) {
        draftName = project.name
        renamingProject = project
    }

    private func commitRename() {
        guard let project = renamingProject else { return }
        model.renameProject(id: project.id, name: draftName)
        renamingProject = nil
    }
}

private struct ProjectRoute: Identifiable, Hashable {
    let project: ProjectManifest
    let newlyCreated: Bool

    var id: UUID { project.id }
}

private struct ProjectLibraryCard: View {
    let project: ProjectManifest
    let thumbnailURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay {
                    TakeThumbnailView(
                        url: thumbnailURL,
                        placeholderSystemName: "film.stack",
                        cornerRadius: 18
                    )
                    .font(.largeTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
                }

            Text(project.name)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 5) {
                Text(RecordingDurationFormatter.clock(project.approximateDuration))
                    .monospacedDigit()
                Text("·")
                Text(project.modifiedAt, format: .dateTime.day().month(.abbreviated))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project.name)
        .accessibilityValue(
            "\(RecordingDurationFormatter.clock(project.approximateDuration)), modified \(project.modifiedAt.formatted(date: .abbreviated, time: .omitted))"
        )
        .accessibilityHint("Opens the Project Workspace")
        .accessibilityAddTraits(.isButton)
    }
}
