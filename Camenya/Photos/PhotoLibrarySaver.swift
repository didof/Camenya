import Foundation
import OSLog
import Photos

enum PhotoLibrarySaveError: Error, LocalizedError, Equatable {
    case permissionDenied
    case creationRequestFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Photo Library add access is required to save the video."
        case .creationRequestFailed: "Photos could not create the video asset."
        }
    }
}

enum PhotoLibrarySaveCompletion {
    static func validate(
        assetRequestCreated: Bool,
        transactionSucceeded: Bool,
        error: Error?
    ) throws {
        if let error { throw error }
        guard assetRequestCreated, transactionSucceeded else {
            throw PhotoLibrarySaveError.creationRequestFailed
        }
    }
}

private final class PhotoLibraryAssetRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var created = false

    func recordCreatedRequest(_ value: Bool) {
        lock.lock()
        created = value
        lock.unlock()
    }

    var wasCreated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return created
    }
}

struct PhotoLibrarySaver {
    private let logger = Logger(subsystem: "org.camenya.app", category: "Photos")

    func saveVideo(at url: URL) async throws {
        logger.info("Photos save started")
        let status = await authorizationStatus()
        guard status == .authorized || status == .limited else { throw PhotoLibrarySaveError.permissionDenied }
        let requestState = PhotoLibraryAssetRequestState()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                requestState.recordCreatedRequest(request != nil)
            } completionHandler: { success, error in
                do {
                    try PhotoLibrarySaveCompletion.validate(
                        assetRequestCreated: requestState.wasCreated,
                        transactionSucceeded: success,
                        error: error
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        logger.info("Photos save completed")
    }

    private func authorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
    }
}
