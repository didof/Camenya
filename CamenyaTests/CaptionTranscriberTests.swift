import XCTest
@testable import Camenya

final class CaptionTranscriberTests: XCTestCase {
    func testFactorySelectsTheRecognizerGenerationForTheRunningIOS() {
        let generation = CaptionRecognizerFactory.make().generation
        if #available(iOS 26.0, *) {
            XCTAssertEqual(generation, .speechAnalyzerIOS26)
        } else {
            XCTAssertEqual(generation, .speechRecognizerIOS18)
        }
    }

    func testUnavailableOnDeviceRecognitionReturnsTypedFailureWithoutFallback() async {
        let transcriber = CaptionTranscriber(
            recognizer: UnavailableCaptionRecognizer(localeIdentifier: "it-IT")
        )

        do {
            _ = try await transcriber.transcribe(
                movieAt: URL(fileURLWithPath: "/tmp/take.mov"),
                sourceRange: TakeRange(startSeconds: 0, endSeconds: 10),
                localeIdentifier: "it-IT"
            )
            XCTFail("Expected strict local recognition to remain unavailable")
        } catch {
            XCTAssertEqual(
                error as? CaptionTranscriptionError,
                .unavailable(.onDeviceRecognitionUnavailable(localeIdentifier: "it-IT"))
            )
        }
    }

    func testLongTakeChunkPlanAddsContextWithoutOverlappingOwnedTime() throws {
        let plan = try CaptionRecognitionChunkPlan(
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 125),
            coreDuration: 50,
            contextPadding: 1
        )

        XCTAssertEqual(plan.chunks, [
            CaptionRecognitionChunk(
                coreRange: TakeRange(startSeconds: 0, endSeconds: 50),
                extractionRange: TakeRange(startSeconds: 0, endSeconds: 51)
            ),
            CaptionRecognitionChunk(
                coreRange: TakeRange(startSeconds: 50, endSeconds: 100),
                extractionRange: TakeRange(startSeconds: 49, endSeconds: 101)
            ),
            CaptionRecognitionChunk(
                coreRange: TakeRange(startSeconds: 100, endSeconds: 125),
                extractionRange: TakeRange(startSeconds: 99, endSeconds: 125),
                includesUpperBound: true
            )
        ])
    }

    func testChunkReconciliationKeepsOneBoundaryUnitUsingTheBestConfidence() throws {
        let plan = try CaptionRecognitionChunkPlan(
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 100),
            coreDuration: 50,
            contextPadding: 1
        )
        let lowerConfidence = CaptionRecognizedUnit(
            range: TakeRange(startSeconds: 49.6, endSeconds: 50.2),
            text: "confine",
            confidence: 0.5,
            alternatives: [],
            granularity: .word
        )
        let higherConfidence = CaptionRecognizedUnit(
            range: TakeRange(startSeconds: 49.9, endSeconds: 50.4),
            text: "Confine",
            confidence: 0.9,
            alternatives: [],
            granularity: .word
        )

        let units = CaptionRecognitionChunkReconciler().reconcile([
            CaptionRecognitionChunkResult(chunk: plan.chunks[0], units: [lowerConfidence]),
            CaptionRecognitionChunkResult(chunk: plan.chunks[1], units: [higherConfidence])
        ])

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.confidence, 0.9)
    }

    func testChunkReconciliationPrefersRealWordsOverAnOverlappingComposite() throws {
        let plan = try CaptionRecognitionChunkPlan(
            sourceRange: TakeRange(startSeconds: 0, endSeconds: 100),
            coreDuration: 50,
            contextPadding: 1
        )
        let hello = CaptionRecognizedUnit(
            range: TakeRange(startSeconds: 49.4, endSeconds: 49.9),
            text: "hello",
            confidence: 0.8,
            alternatives: [],
            granularity: .word
        )
        let composite = CaptionRecognizedUnit(
            range: TakeRange(startSeconds: 49.4, endSeconds: 50.6),
            text: "hello world",
            confidence: 0.9,
            alternatives: [],
            granularity: .segment
        )
        let world = CaptionRecognizedUnit(
            range: TakeRange(startSeconds: 50, endSeconds: 50.5),
            text: "world",
            confidence: 0.8,
            alternatives: [],
            granularity: .word
        )

        let units = CaptionRecognitionChunkReconciler().reconcile([
            CaptionRecognitionChunkResult(chunk: plan.chunks[0], units: [hello, composite]),
            CaptionRecognitionChunkResult(chunk: plan.chunks[1], units: [composite, world])
        ])

        XCTAssertEqual(units.map(\.text), ["hello", "world"])
    }

    func testTimedUnitsBecomeReadableCuesWithoutLosingWordTiming() {
        let units = [
            CaptionRecognizedUnit(
                range: TakeRange(startSeconds: 0, endSeconds: 0.4),
                text: "Ciao",
                confidence: 0.9,
                alternatives: [],
                granularity: .word
            ),
            CaptionRecognizedUnit(
                range: TakeRange(startSeconds: 0.5, endSeconds: 1),
                text: "mondo.",
                confidence: 0.8,
                alternatives: ["mondo"],
                granularity: .word
            ),
            CaptionRecognizedUnit(
                range: TakeRange(startSeconds: 2.2, endSeconds: 2.8),
                text: "Nuova frase",
                confidence: 0.7,
                alternatives: [],
                granularity: .segment
            )
        ]

        let cues = CaptionCueAssembler().assemble(units)

        XCTAssertEqual(cues.map(\.text), ["Ciao mondo.", "Nuova frase"])
        XCTAssertEqual(cues.first?.range, TakeRange(startSeconds: 0, endSeconds: 1))
        XCTAssertEqual(cues.first?.timedSpans.count, 2)
        XCTAssertEqual(cues.last?.timedSpans.first?.granularity, .segment)
        XCTAssertEqual(cues.first?.alternatives, [])
        XCTAssertEqual(cues.first?.timedSpans.last?.alternatives, ["mondo"])
    }

    func testResultScopedAlternativesRemainAttachedToTheirCue() {
        let groupID = UUID()
        let units = [
            CaptionRecognizedUnit(
                range: TakeRange(startSeconds: 0, endSeconds: 0.5),
                text: "hello",
                confidence: nil,
                alternatives: [],
                granularity: .word,
                cueAlternativeGroupID: groupID,
                cueAlternatives: ["yellow world"]
            ),
            CaptionRecognizedUnit(
                range: TakeRange(startSeconds: 0.5, endSeconds: 1),
                text: "world",
                confidence: nil,
                alternatives: [],
                granularity: .word,
                cueAlternativeGroupID: groupID,
                cueAlternatives: ["yellow world"]
            )
        ]

        XCTAssertEqual(CaptionCueAssembler().assemble(units).first?.alternatives, ["yellow world"])
    }

    func testResultScopedAlternativeIsHiddenWhenItsResultSplitsAcrossCues() {
        let groupID = UUID()
        let units = ["one", "two", "three"].enumerated().map { index, text in
            CaptionRecognizedUnit(
                range: TakeRange(startSeconds: Double(index), endSeconds: Double(index) + 0.5),
                text: text,
                confidence: nil,
                alternatives: [],
                granularity: .word,
                cueAlternativeGroupID: groupID,
                cueAlternatives: ["whole result alternative"]
            )
        }

        let cues = CaptionCueAssembler(maximumCharacters: 7).assemble(units)

        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertTrue(cues.allSatisfy { $0.alternatives.isEmpty })
    }
}

private struct UnavailableCaptionRecognizer: CaptionRecognizing {
    let localeIdentifier: String
    let generation = CaptionRecognizerGeneration.speechRecognizerIOS18

    func availability(for localeIdentifier: String) async -> CaptionRecognitionAvailability {
        .unavailable(.onDeviceRecognitionUnavailable(localeIdentifier: localeIdentifier))
    }

    func recognize(
        movieAt url: URL,
        sourceRange: TakeRange,
        localeIdentifier: String
    ) async throws -> [CaptionCue] {
        throw CaptionTranscriptionError.recognitionFailed("Recognition must not start when local support is unavailable.")
    }
}
