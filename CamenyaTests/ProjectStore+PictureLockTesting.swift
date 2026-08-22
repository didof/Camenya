import Foundation
@testable import Camenya

extension ProjectStore {
    /// Test fixture convenience. Shipping code cannot create Picture Lock without the
    /// validated-and-saved Clean Master checkpoint.
    @discardableResult
    func createPictureLockForTesting(
        projectID: UUID,
        configuration: ProjectCaptionConfiguration,
        createdAt: Date = Date()
    ) throws -> ProjectManifest {
        let project = try load(id: projectID)
        let revision = project.primaryStoryline.revision
        let url = cleanMasterURL(projectID: projectID, revision: revision)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test-only validated clean master".utf8).write(to: url, options: .atomic)
        try recordValidatedCleanMaster(
            projectID: projectID,
            expectedRevision: revision,
            cleanMasterURL: url,
            duration: project.approximateDuration
        )
        try recordCleanMasterPhotosSaveStarted(
            projectID: projectID,
            expectedRevision: revision
        )
        try recordCleanMasterSavedToPhotos(
            projectID: projectID,
            expectedRevision: revision,
            savedAt: createdAt
        )
        _ = try commitPictureLockAfterCleanMaster(
            projectID: projectID,
            expectedRevision: revision
        )
        return try createProjectCaptionTrack(
            projectID: projectID,
            configuration: configuration,
            createdAt: createdAt
        )
    }
}
