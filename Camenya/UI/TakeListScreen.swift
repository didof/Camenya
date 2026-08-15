import SwiftUI

struct TakeEdgeCleanupPresentation: Equatable, Sendable {
    let label: String
    let systemImage: String
    let actionTitle: String

    init(label: String, systemImage: String, actionTitle: String) {
        self.label = label
        self.systemImage = systemImage
        self.actionTitle = actionTitle
    }

    init(take: ProjectTake, clips: [TimelineClip] = []) {
        let takeClips = clips.filter { $0.takeID == take.id }
        if takeClips.contains(where: { $0.selection != $0.availableRange }) {
            self = Self(
                label: "Storyline Clip trimmed",
                systemImage: "crop",
                actionTitle: "Edit Storyline Trim"
            )
            return
        }
        switch take.trimAnalysis {
        case .suggestion:
            self = Self(label: "Cleanup review needed", systemImage: "waveform.badge.magnifyingglass", actionTitle: "Review Silence Trim")
        case .noSuggestion:
            self = Self(label: "No edge trim suggested", systemImage: "waveform.slash", actionTitle: "Adjust Silence Trim")
        case .failed:
            self = Self(label: "Cleanup unavailable", systemImage: "exclamationmark.triangle", actionTitle: "Retry Silence Analysis")
        case nil:
            self = Self(label: "Original range", systemImage: "rectangle", actionTitle: "Analyze Silence")
        }
    }
}

struct TakeCaptionPresentation: Equatable, Sendable {
    let label: String
    let systemImage: String
    let requiresAttention: Bool
    let actionTitle: String

    init(label: String, systemImage: String, requiresAttention: Bool, actionTitle: String) {
        self.label = label
        self.systemImage = systemImage
        self.requiresAttention = requiresAttention
        self.actionTitle = actionTitle
    }

    init(take: ProjectTake, configuration: ProjectCaptionConfiguration?) {
        guard let captions = take.captions else {
            self = Self(label: "No captions", systemImage: "captions.bubble", requiresAttention: false, actionTitle: "Create Captions")
            return
        }
        let matchesProject = configuration?.localeIdentifier == captions.localeIdentifier
        let matchesRange = take.concreteEffectiveRange == captions.sourceRange
        if captions.reviewState == .stale || !matchesProject || !matchesRange {
            self = Self(
                label: "Captions need update",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                requiresAttention: true,
                actionTitle: "Regenerate Captions"
            )
        } else if captions.reviewState == .needsReview {
            self = Self(
                label: "Captions to review",
                systemImage: "exclamationmark.bubble",
                requiresAttention: true,
                actionTitle: "Review Captions"
            )
        } else {
            self = Self(label: "Captions approved", systemImage: "checkmark.bubble", requiresAttention: false, actionTitle: "Edit Captions")
        }
    }
}

struct TakeListScreen: View {
    @ObservedObject var model: AppModel
    let onRequestProjectAction: (TakeListProjectAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reviewingTake: ProjectTake?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(model.project.takes.enumerated()), id: \.element.id) { index, take in
                        let cleanup = TakeEdgeCleanupPresentation(
                            take: take,
                            clips: model.project.primaryStoryline.clips
                        )
                        takeRow(take, index: index)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button(cleanup.actionTitle, systemImage: "waveform.badge.magnifyingglass") {
                                    requestSilenceTrim(for: take)
                                }
                                .tint(.indigo)
                                .disabled(!model.canManageTakes)
                            }
                    }
                } header: {
                    Text("Recorded Takes")
                } footer: {
                    Text("Finalized Takes are kept as source media. Edit their Clips and order in the Primary Storyline.")
                }

            }
            .navigationTitle("Takes")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("take-list")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                projectControls
            }
        }
        .sheet(item: $reviewingTake) { take in
            TakeReviewScreen(
                url: model.movieURL(for: take),
                title: "Take \((model.project.takes.firstIndex(of: take) ?? 0) + 1)",
                format: model.project.format ?? .portrait
            )
        }
    }

    private func takeRow(_ take: ProjectTake, index: Int) -> some View {
        let cleanup = TakeEdgeCleanupPresentation(
            take: take,
            clips: model.project.primaryStoryline.clips
        )
        let captions = TakeCaptionPresentation(
            take: take,
            configuration: model.captionConfiguration
        )
        return HStack(spacing: 10) {
            Button {
                reviewingTake = take
            } label: {
                HStack(spacing: 14) {
                TakeThumbnailView(
                    url: take.thumbnailFileName == nil ? nil : model.thumbnailURL(for: take),
                    placeholderSystemName: "play.fill",
                    cornerRadius: 10
                )
                .frame(width: 92, height: 58)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Take \(index + 1)")
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text(duration(take.effectiveDuration))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(take.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(cleanup.label, systemImage: cleanup.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(captions.label, systemImage: captions.systemImage)
                        .font(.caption.weight(captions.requiresAttention ? .semibold : .regular))
                        .foregroundStyle(captions.requiresAttention ? .orange : .secondary)
                }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Review Take", systemImage: "play.rectangle") {
                    reviewingTake = take
                }
                Button(cleanup.actionTitle, systemImage: "waveform.badge.magnifyingglass") {
                    requestSilenceTrim(for: take)
                }
                .disabled(!model.canManageTakes)
                Button(captions.actionTitle, systemImage: "captions.bubble") {
                    onRequestProjectAction(.manageCaptions(takeID: take.id))
                }
                .disabled(!model.canManageTakes)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for Take \(index + 1)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("take-row-\(take.id.uuidString)")
    }

    private var projectControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onRequestProjectAction(.playProject)
                } label: {
                    Label("Play", systemImage: "play.rectangle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                Menu {
                    if !model.trimReviewTakeIDs.isEmpty {
                        Button("Review Pending Trims", systemImage: "slider.horizontal.3") {
                            onRequestProjectAction(.reviewEdges)
                        }
                    }
                    Button("Analyze Take Edges", systemImage: "waveform.badge.magnifyingglass") {
                        onRequestProjectAction(.analyzeEdges)
                    }
                    .disabled(!model.hasTakesNeedingEdgeAnalysis)
                } label: {
                    Label(
                        "Clean Edges",
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                Menu {
                    if model.hasReviewableCaptions {
                        Button("Review & Edit Captions", systemImage: "text.bubble") {
                            onRequestProjectAction(.reviewCaptions)
                        }
                    }
                    Button("Language, Position & Regenerate", systemImage: "gearshape") {
                        onRequestProjectAction(.captionSettings)
                    }
                } label: {
                    Label(
                        "Captions",
                        systemImage: "captions.bubble.fill"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity)
            Button {
                onRequestProjectAction(.exportProject)
            } label: {
                Label(
                    model.canRetryProjectExportSave ? "Save Export to Photos" : "Export Project to Photos",
                    systemImage: model.canRetryProjectExportSave
                        ? "photo.badge.arrow.down"
                        : "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canExportProject)
            .accessibilityHint(model.canExportProject
                ? "Creates the explicit finalized Project Export before saving to Photos."
                : "Add at least one Clip to the Primary Storyline before exporting.")
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canManageTakes)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityIdentifier("take-project-controls")
    }

    private func duration(_ interval: TimeInterval) -> String {
        RecordingDurationFormatter.clock(interval)
    }

    private func requestSilenceTrim(for take: ProjectTake) {
        onRequestProjectAction(.manageEdges(takeID: take.id))
        dismiss()
    }
}
