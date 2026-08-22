import AVFoundation
import XCTest
@testable import Camenya

final class CameraControllerTests: XCTestCase {
    func testRecordingOutputSettingsUseOnlyTheSupportedCodecKey() throws {
        let settings = try XCTUnwrap(CaptureRecordingOutputPolicy.settings(
            availableVideoCodecTypes: [.h264, .hevc]
        ))

        XCTAssertEqual(settings.count, 1)
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
        XCTAssertNil(settings[AVVideoColorPropertiesKey])
    }

    func testStartingAnUnconfiguredSessionReportsThatItIsNotUsable() async {
        let controller = CameraController()

        let isRunning = await withCheckedContinuation { continuation in
            controller.startSession { isRunning in
                continuation.resume(returning: isRunning)
            }
        }

        XCTAssertFalse(isRunning)
    }

    func testStoppingAnIdleSessionStillCompletesTheProjectExit() async {
        let controller = CameraController()

        await withCheckedContinuation { continuation in
            controller.stopSession { continuation.resume() }
        }
    }

    @MainActor
    func testConfiguredPhysicalCameraStartsMovieRecordingWithoutException() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone only: this regression test exercises the real capture connection.")
#else
        let controller = CameraController()
        let configured = expectation(description: "Capture session configured")
        var configurationError: Error?
        controller.configure { result in
            if case let .failure(error) = result {
                configurationError = error
            }
            configured.fulfill()
        }
        await fulfillment(of: [configured], timeout: 15)
        XCTAssertNil(configurationError)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let started = expectation(description: "Movie recording started")
        let finished = expectation(description: "Movie recording finished")
        var recordingError: Error?
        controller.onRecordingStarted = {
            started.fulfill()
            controller.stopRecording()
        }
        controller.onRecordingFinished = { _, error in
            recordingError = error
            finished.fulfill()
        }

        controller.startRecording(to: output, rotationAngle: 90)
        await fulfillment(of: [started, finished], timeout: 15, enforceOrder: true)

        XCTAssertNil(recordingError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        await withCheckedContinuation { continuation in
            controller.stopSession { continuation.resume() }
        }
#endif
    }
}
