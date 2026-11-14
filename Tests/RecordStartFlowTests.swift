import XCTest

final class RecordStartFlowTests: XCTestCase {

    func testHappyPathIsPictureThenCountdownThenTape() {
        var flow = RecordStartFlow()
        XCTAssertEqual(flow.handle(.begin), .buildPicture)
        XCTAssertEqual(flow.handle(.pictureReady), .countdown)
        XCTAssertEqual(flow.handle(.countdownFinished), .beginTake)
        XCTAssertEqual(flow.handle(.takeStarted), .finish)
        XCTAssertEqual(flow.stage, .recording)
        XCTAssertFalse(flow.endedWithoutRecording)
    }

    func testCancelDuringCountdownPutsEverythingAwayWithoutAnError() {
        var flow = RecordStartFlow()
        _ = flow.handle(.begin); _ = flow.handle(.pictureReady)
        XCTAssertEqual(flow.handle(.cancelled), .putAway)
        XCTAssertTrue(flow.endedWithoutRecording)
        XCTAssertNil(flow.failureMessage)
    }

    func testFailureAtAnyStepShowsTheMessageOnTheIsland() {
        for steps in 0..<3 {
            var flow = RecordStartFlow()
            _ = flow.handle(.begin)
            if steps > 0 { _ = flow.handle(.pictureReady) }
            if steps > 1 { _ = flow.handle(.countdownFinished) }
            XCTAssertEqual(flow.handle(.failed("no mic")), .showFailure("no mic"))
            XCTAssertEqual(flow.failureMessage, "no mic")
            XCTAssertTrue(flow.endedWithoutRecording)
        }
    }

    func testLateEventsAfterTheFlowEndedChangeNothing() {
        var flow = RecordStartFlow()
        _ = flow.handle(.begin); _ = flow.handle(.cancelled)
        XCTAssertEqual(flow.handle(.countdownFinished), .idle)
        XCTAssertEqual(flow.handle(.takeStarted), .idle)
        XCTAssertEqual(flow.stage, .cancelled)
    }

    func testTheIslandListsPictureThenRecording() {
        XCTAssertEqual(RecordStartFlow.stepLabels, ["Picture", "Recording"])
    }
}
