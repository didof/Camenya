import Foundation

struct ProjectRecordingCoordinator: Sendable {
    let projectID: UUID
    let projectStore: ProjectStore

    func complete(
        take: TakeManifest,
        finalizedMovieAt url: URL,
        completedAt: Date = Date()
    ) throws -> ProjectManifest {
        let project = try projectStore.addTake(
            projectID: projectID,
            takeID: take.id,
            movieAt: url,
            orientation: take.orientation,
            duration: take.approximateDuration,
            createdAt: take.createdAt,
            modifiedAt: completedAt
        )
        try projectStore.cleanCompletedTakeArtifacts(projectID: projectID, takeID: take.id)
        return project
    }
}
