@preconcurrency import AVFoundation
import Foundation
import OSLog
@preconcurrency import Speech

final class LegacySpeechCaptionRecognizer: CaptionRecognizing, @unchecked Sendable {
    let generation = CaptionRecognizerGeneration.speechRecognizerIOS18

    private let logger = Logger(subsystem: "org.camenya.app", category: "Captions")
    private let lock = NSLock()
    private var activeRecognitionTask: SFSpeechRecognitionTask?

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

        let requested = Locale(identifier: localeIdentifier).identifier.lowercased()
        guard SFSpeechRecognizer.supportedLocales().contains(where: {
            $0.identifier.lowercased() == requested
        }), let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            return .unavailable(.unsupportedLocale(localeIdentifier: localeIdentifier))
        }
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            return .unavailable(.onDeviceRecognitionUnavailable(localeIdentifier: localeIdentifier))
        }
        return .available
    }

    func recognize(
        movieAt url: URL,
        sourceRange: TakeRange,
        localeIdentifier: String
    ) async throws -> [CaptionCue] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable else {
            throw CaptionTranscriptionError.unavailable(
                .onDeviceRecognitionUnavailable(localeIdentifier: localeIdentifier)
            )
        }
        let plan = try CaptionRecognitionChunkPlan(sourceRange: sourceRange)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CamenyaCaptions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var chunkResults: [CaptionRecognitionChunkResult] = []
        for (index, chunk) in plan.chunks.enumerated() {
            try Task.checkCancellation()
            let audioURL = temporaryDirectory.appendingPathComponent("chunk-\(index).m4a")
            try await CaptionAudioExtractor().extract(
                from: url,
                range: chunk.extractionRange,
                to: audioURL
            )
            let chunkUnits = try await recognizeFile(
                at: audioURL,
                recognizer: recognizer,
                chunk: chunk
            )
            chunkResults.append(CaptionRecognitionChunkResult(chunk: chunk, units: chunkUnits))
        }
        let units = CaptionRecognitionChunkReconciler().reconcile(chunkResults)
        let cues = CaptionCueAssembler().assemble(units)
        logger.info("On-device legacy transcription completed with \(cues.count) timed segments")
        return cues.sorted { $0.range.start.seconds < $1.range.start.seconds }
    }

    private func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func recognizeFile(
        at audioURL: URL,
        recognizer: SFSpeechRecognizer,
        chunk: CaptionRecognitionChunk
    ) async throws -> [CaptionRecognizedUnit] {
        let completion = SpeechRecognitionCompletion()
        defer { setActiveRecognitionTask(nil) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let request = SFSpeechURLRecognitionRequest(url: audioURL)
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = false
                request.addsPunctuation = true
                request.taskHint = .dictation
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        completion.resume(.failure(CaptionTranscriptionError.recognitionFailed(
                            error.localizedDescription
                        )))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let units = result.bestTranscription.segments.compactMap { segment -> CaptionRecognizedUnit? in
                        let absoluteRange = TakeRange(
                            startSeconds: chunk.extractionRange.start.seconds + segment.timestamp,
                            endSeconds: chunk.extractionRange.start.seconds + segment.timestamp + segment.duration
                        )
                        let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        let granularity: CaptionTimingGranularity = text.split(whereSeparator: { $0.isWhitespace }).count == 1
                            ? .word
                            : .segment
                        return CaptionRecognizedUnit(
                            range: absoluteRange,
                            text: text,
                            confidence: Double(segment.confidence),
                            alternatives: segment.alternativeSubstrings,
                            granularity: granularity
                        )
                    }
                    completion.resume(.success(units))
                }
                self.setActiveRecognitionTask(task)
            }
        } onCancel: {
            self.cancelActiveRecognition()
            completion.resume(.failure(CaptionTranscriptionError.cancelled))
        }
    }

    private func setActiveRecognitionTask(_ task: SFSpeechRecognitionTask?) {
        lock.lock()
        activeRecognitionTask = task
        lock.unlock()
    }

    private func cancelActiveRecognition() {
        lock.lock()
        let task = activeRecognitionTask
        activeRecognitionTask = nil
        lock.unlock()
        task?.cancel()
    }
}

private final class SpeechRecognitionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[CaptionRecognizedUnit], Error>?
    private var pendingResult: Result<[CaptionRecognizedUnit], Error>?

    func install(_ continuation: CheckedContinuation<[CaptionRecognizedUnit], Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(_ result: Result<[CaptionRecognizedUnit], Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else if pendingResult == nil {
            pendingResult = result
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}
