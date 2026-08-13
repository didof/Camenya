@preconcurrency import AVFoundation
import Foundation
import OSLog
@preconcurrency import Speech

@available(iOS 26.0, *)
final class SpeechAnalyzerCaptionRecognizer: CaptionRecognizing, @unchecked Sendable {
    let generation = CaptionRecognizerGeneration.speechAnalyzerIOS26

    private let logger = Logger(subsystem: "org.camenya.app", category: "Captions")

    func availability(for localeIdentifier: String) async -> CaptionRecognitionAvailability {
        switch await authorizationStatus() {
        case .authorized:
            break
        case .denied:
            return .unavailable(.authorizationDenied)
        case .restricted:
            return .unavailable(.authorizationRestricted)
        case .notDetermined:
            return .unavailable(.authorizationDenied)
        @unknown default:
            return .unavailable(.authorizationRestricted)
        }
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: localeIdentifier)
              ) != nil else {
            return .unavailable(.unsupportedLocale(localeIdentifier: localeIdentifier))
        }
        return .available
    }

    func recognize(
        movieAt url: URL,
        sourceRange: TakeRange,
        localeIdentifier: String
    ) async throws -> [CaptionCue] {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            throw CaptionTranscriptionError.unavailable(
                .unsupportedLocale(localeIdentifier: localeIdentifier)
            )
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )
        try await ensureInstalled(transcriber: transcriber, localeIdentifier: localeIdentifier)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CamenyaCaptions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let audioURL = temporaryDirectory.appendingPathComponent("take.m4a")
        try await CaptionAudioExtractor().extract(from: url, range: sourceRange, to: audioURL)
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw CaptionTranscriptionError.missingAudio
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let sourceOffset = sourceRange.start.seconds
        do {
            let units = try await withTaskCancellationHandler {
                async let analysis: Void = analyzer.start(
                    inputAudioFile: audioFile,
                    finishAfterFile: true
                )
                var units: [CaptionRecognizedUnit] = []
                for try await result in transcriber.results where result.isFinal {
                    units.append(contentsOf: recognizedUnits(from: result, sourceOffset: sourceOffset))
                }
                try await analysis
                return units
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            let cues = CaptionCueAssembler().assemble(units)
            logger.info("On-device SpeechAnalyzer transcription completed with \(cues.count) timed cues")
            return cues.sorted { $0.range.start.seconds < $1.range.start.seconds }
        } catch is CancellationError {
            throw CaptionTranscriptionError.cancelled
        } catch let error as CaptionTranscriptionError {
            throw error
        } catch {
            throw CaptionTranscriptionError.recognitionFailed(error.localizedDescription)
        }
    }

    private func ensureInstalled(
        transcriber: SpeechTranscriber,
        localeIdentifier: String
    ) async throws {
        let modules: [any SpeechModule] = [transcriber]
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .unsupported:
            throw CaptionTranscriptionError.unavailable(
                .modelUnavailable(localeIdentifier: localeIdentifier)
            )
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) else {
                guard await AssetInventory.status(forModules: modules) == .installed else {
                    throw CaptionTranscriptionError.unavailable(
                        .modelUnavailable(localeIdentifier: localeIdentifier)
                    )
                }
                return
            }
            do {
                try await request.downloadAndInstall()
            } catch is CancellationError {
                throw CaptionTranscriptionError.cancelled
            } catch {
                throw CaptionTranscriptionError.unavailable(
                    .modelUnavailable(localeIdentifier: localeIdentifier)
                )
            }
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw CaptionTranscriptionError.unavailable(
                    .modelUnavailable(localeIdentifier: localeIdentifier)
                )
            }
        @unknown default:
            throw CaptionTranscriptionError.unavailable(
                .modelUnavailable(localeIdentifier: localeIdentifier)
            )
        }
    }

    private func recognizedUnits(
        from result: SpeechTranscriber.Result,
        sourceOffset: TimeInterval
    ) -> [CaptionRecognizedUnit] {
        let alternatives = result.alternatives.map { String($0.characters) }
        let alternativeGroupID = alternatives.isEmpty ? nil : UUID()
        var units: [CaptionRecognizedUnit] = []
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let audioRange = run.audioTimeRange else { continue }
            let range = TakeRange(
                startSeconds: sourceOffset + audioRange.start.seconds,
                endSeconds: sourceOffset + audioRange.end.seconds
            )
            let granularity: CaptionTimingGranularity = text.split(whereSeparator: { $0.isWhitespace }).count == 1
                ? .word
                : .segment
            units.append(CaptionRecognizedUnit(
                range: range,
                text: text,
                confidence: run.transcriptionConfidence,
                alternatives: [],
                granularity: granularity,
                cueAlternativeGroupID: alternativeGroupID,
                cueAlternatives: alternatives
            ))
        }
        if units.isEmpty {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            units.append(CaptionRecognizedUnit(
                range: TakeRange(
                    startSeconds: sourceOffset + result.range.start.seconds,
                    endSeconds: sourceOffset + result.range.end.seconds
                ),
                text: text,
                confidence: nil,
                alternatives: alternatives,
                granularity: .segment,
                cueAlternativeGroupID: alternativeGroupID,
                cueAlternatives: alternatives
            ))
        }
        return units
    }

    private func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}
