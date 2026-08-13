import XCTest
@testable import Camenya

final class RecorderStateMachineTests: XCTestCase {
    func testTakeCanRecordPauseFlipResumeAndStop() throws {
        var machine = RecorderStateMachine(initialPhase: .idle)
        try machine.apply(.recordRequested)
        XCTAssertEqual(machine.phase, .startingSegment)
        try machine.apply(.segmentStarted)
        try machine.apply(.pauseRequested)
        try machine.apply(.segmentFinished)
        XCTAssertEqual(machine.phase, .paused)
        try machine.apply(.flipRequested)
        try machine.apply(.cameraSwitchCompleted)
        XCTAssertEqual(machine.phase, .paused)
        try machine.apply(.resumeRequested)
        try machine.apply(.segmentStarted)
        try machine.apply(.stopRequested)
        try machine.apply(.segmentFinished)
        XCTAssertEqual(machine.phase, .finalizing)
    }

    func testFlipWhileRecordingIsRejectedWithoutChangingState() throws {
        var machine = RecorderStateMachine(initialPhase: .recording)
        XCTAssertThrowsError(try machine.apply(.flipRequested))
        XCTAssertEqual(machine.phase, .recording)
    }

    func testStopWhilePausedStartsFinalizationImmediately() throws {
        var machine = RecorderStateMachine(initialPhase: .paused)
        try machine.apply(.stopRequested)
        XCTAssertEqual(machine.phase, .finalizing)
    }

    func testFinalizingRejectsRecord() {
        var machine = RecorderStateMachine(initialPhase: .finalizing)
        XCTAssertThrowsError(try machine.apply(.recordRequested))
        XCTAssertEqual(machine.phase, .finalizing)
    }

    func testSuccessfulFinalizationAndSaveCompleteTheTake() throws {
        var machine = RecorderStateMachine(initialPhase: .finalizing)
        try machine.apply(.finalizationSucceeded)
        XCTAssertEqual(machine.phase, .storingTake)
        try machine.apply(.takeStored)
        XCTAssertEqual(machine.phase, .completed)
    }
}
