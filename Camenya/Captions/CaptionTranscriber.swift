import Foundation

enum CaptionRecognitionUnavailableReason: Equatable, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case unsupportedLocale(localeIdentifier: String)
    case onDeviceRecognitionUnavailable(localeIdentifier: String)
    case modelUnavailable(localeIdentifier: String)
}

enum CaptionRecognitionAvailability: Equatable, Sendable {
    case available
    case unavailable(CaptionRecognitionUnavailableReason)
}

enum CaptionTranscriptionError: Error, Equatable, LocalizedError {
    case unavailable(CaptionRecognitionUnavailableReason)
    case invalidSourceRange
    case missingAudio
    case recognitionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason):
            switch reason {
            case .authorizationDenied:
                "Speech Recognition access is required to create captions."
            case .authorizationRestricted:
                "Speech Recognition is restricted on this device."
            case let .unsupportedLocale(localeIdentifier):
                "Captions are not supported for \(localeIdentifier)."
            case let .onDeviceRecognitionUnavailable(localeIdentifier):
                "On-device captions are unavailable for \(localeIdentifier). No audio was sent to a server."
            case let .modelUnavailable(localeIdentifier):
                "The on-device speech model for \(localeIdentifier) is not installed."
            }
        case .invalidSourceRange:
            "The Take range for captioning is invalid."
        case .missingAudio:
            "This Take has no readable audio for captions."
        case let .recognitionFailed(message):
            message
        case .cancelled:
            "Caption transcription was cancelled."
        }
    }
}

protocol CaptionRecognizing: Sendable {
    var generation: CaptionRecognizerGeneration { get }

    func availability(for localeIdentifier: String) async -> CaptionRecognitionAvailability

    func recognize(
        movieAt url: URL,
        sourceRange: TakeRange,
        localeIdentifier: String
    ) async throws -> [CaptionCue]
}

enum CaptionRecognizerFactory {
    static func make() -> any CaptionRecognizing {
        if #available(iOS 26.0, *) {
            return SpeechAnalyzerCaptionRecognizer()
        }
        return LegacySpeechCaptionRecognizer()
    }
}

struct CaptionTranscriber: Sendable {
    private let recognizer: any CaptionRecognizing

    init(recognizer: any CaptionRecognizing) {
        self.recognizer = recognizer
    }

    func transcribe(
        movieAt url: URL,
        sourceRange: TakeRange,
        localeIdentifier: String
    ) async throws -> TakeCaptionTrack {
        guard sourceRange.start.seconds.isFinite,
              sourceRange.end.seconds.isFinite,
              sourceRange.start.seconds >= 0,
              sourceRange.duration > 0 else {
            throw CaptionTranscriptionError.invalidSourceRange
        }
        switch await recognizer.availability(for: localeIdentifier) {
        case .available:
            break
        case let .unavailable(reason):
            throw CaptionTranscriptionError.unavailable(reason)
        }
        let cues = try await recognizer.recognize(
            movieAt: url,
            sourceRange: sourceRange,
            localeIdentifier: localeIdentifier
        )
        return TakeCaptionTrack(
            localeIdentifier: localeIdentifier,
            sourceRange: sourceRange,
            recognizer: recognizer.generation,
            reviewState: .needsReview,
            cues: cues
        )
    }
}
