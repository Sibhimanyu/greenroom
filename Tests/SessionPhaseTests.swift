import XCTest

/// SessionPhase through events only; the answers are the eight old flags.
final class SessionPhaseTests: XCTestCase {

    private struct Flags: Equatable {
        var running = false, live = false, stopping = false
        var recordOnly = false, startingRecord = false
        var recording = false, paused = false, saving = false
    }

    private func flags(_ p: SessionPhase) -> Flags {
        Flags(running: p.isRunning, live: p.stageLive, stopping: p.isStopping,
              recordOnly: p.recordOnlyActive, startingRecord: p.startingRecordOnly,
              recording: p.isRecording, paused: p.isRecordingPaused, saving: p.isSavingRecording)
    }

    private func run(_ events: [SessionPhase.Event], from start: SessionPhase = SessionPhase()) -> SessionPhase {
        var p = start
        for e in events { p.apply(e) }
        return p
    }

    func testStartsIdle() {
        XCTAssertEqual(flags(SessionPhase()), Flags())
    }

    func testMeetingStartLiveStop() {
        var p = SessionPhase()
        p.apply(.meetingStartRequested)
        XCTAssertEqual(flags(p), Flags(running: true))
        p.apply(.meetingPictureUp)
        XCTAssertEqual(flags(p), Flags(running: true, live: true))
        p.apply(.meetingStartTaskFinished)
        XCTAssertEqual(flags(p), Flags(live: true))
        p.apply(.stopRequested)
        XCTAssertEqual(flags(p), Flags(live: true, stopping: true))
        p.apply(.meetingTornDown)
        XCTAssertEqual(flags(p), Flags())
        XCTAssertEqual(p.session, .idle)
    }

    func testRecordStartCountdownTakeStopWithSavingAfterStop() {
        var p = SessionPhase()
        p.apply(.recordStartRequested)
        XCTAssertEqual(flags(p), Flags(running: true, startingRecord: true))
        p.apply(.recordPictureUp)
        XCTAssertEqual(flags(p), Flags(running: true, recordOnly: true, startingRecord: true))
        // Countdown, then the take: isRunning is still true.
        p.apply(.takeBegan)
        XCTAssertEqual(flags(p), Flags(running: true, recordOnly: true, startingRecord: true, recording: true))
        p.apply(.recordStartTaskFinished)
        XCTAssertEqual(flags(p), Flags(recordOnly: true, recording: true))
        // Stop: the take finishes, the picture goes, the file is still closing.
        p.apply(.stopRequested)
        p.apply(.takeFinishing)
        XCTAssertEqual(flags(p), Flags(stopping: true, recordOnly: true, saving: true))
        p.apply(.recordPictureDown)
        p.apply(.takeSaved)
        p.apply(.recordStopFinished)
        XCTAssertEqual(flags(p), Flags())
        // Saving outliving the session.
        var q = run([.recordStartRequested, .recordPictureUp, .takeBegan, .recordStartTaskFinished,
                     .stopRequested, .takeFinishing, .recordPictureDown, .recordStopFinished])
        XCTAssertEqual(flags(q), Flags(saving: true))
        q.apply(.takeSaved)
        XCTAssertEqual(flags(q), Flags())
    }

    func testStopWhileRecordStartIsPending() {
        var p = run([.recordStartRequested, .recordPictureUp, .stopRequested])
        XCTAssertEqual(flags(p), Flags(running: true, stopping: true, recordOnly: true, startingRecord: true))
        p.apply(.recordPictureDown)
        p.apply(.recordStartTaskFinished)
        XCTAssertEqual(flags(p), Flags(stopping: true))
        p.apply(.recordStopFinished)
        XCTAssertEqual(flags(p), Flags())
    }

    func testFailedMeetingStart() {
        var p = run([.meetingStartRequested, .stopRequested])
        XCTAssertEqual(flags(p), Flags(running: true, stopping: true))
        p.apply(.meetingStartTaskFinished)
        XCTAssertEqual(flags(p), Flags(stopping: true))
        p.apply(.meetingTornDown)
        XCTAssertEqual(flags(p), Flags())
    }

    func testFailedRecordStart() {
        let p = run([.recordStartRequested, .recordPictureUp, .recordPictureDown, .recordStartTaskFinished])
        XCTAssertEqual(flags(p), Flags())
    }

    func testCancelledMeetingStartEitherOrderEndsIdle() {
        let a = run([.meetingStartRequested, .stopRequested, .meetingStartTaskFinished, .meetingTornDown])
        let b = run([.meetingStartRequested, .stopRequested, .meetingTornDown, .meetingStartTaskFinished])
        XCTAssertEqual(flags(a), Flags())
        XCTAssertEqual(flags(b), Flags())
        // Today's quirk, reproduced: a late task end clears a newer start.
        let c = run([.meetingStartRequested, .stopRequested, .meetingTornDown,
                     .meetingStartRequested, .meetingStartTaskFinished])
        XCTAssertEqual(flags(c), Flags())
    }

    func testTakeDuringAMeeting() {
        var p = run([.meetingStartRequested, .meetingPictureUp, .meetingStartTaskFinished, .takeBegan])
        XCTAssertEqual(flags(p), Flags(live: true, recording: true))
        p.apply(.takeFinishing)
        XCTAssertEqual(flags(p), Flags(live: true, saving: true))
        p.apply(.takeSaved)
        XCTAssertEqual(flags(p), Flags(live: true))
    }

    /// The old REC bug: the guard checked only isRunning, which is false once
    /// the start task is done. The module must still say a meeting is live
    /// with a take rolling.
    func testLiveMeetingWithRollingTakeAfterStartTaskFinished() {
        let p = run([.meetingStartRequested, .meetingPictureUp, .takeBegan, .meetingStartTaskFinished])
        XCTAssertFalse(p.isRunning)
        XCTAssertTrue(p.stageLive)
        XCTAssertTrue(p.isRecording)
        XCTAssertEqual(p.session, .live(.meeting))
        XCTAssertEqual(p.take, .rolling)
    }

    func testRecordingCanContinueWhileStopping() {
        // End Session: the take is still rolling when Stop is requested.
        var p = run([.meetingStartRequested, .meetingPictureUp, .meetingStartTaskFinished,
                     .takeBegan, .stopRequested])
        XCTAssertEqual(flags(p), Flags(live: true, stopping: true, recording: true))
        p.apply(.takeFinishingAtMeetingEnd)
        p.apply(.meetingTornDown)
        XCTAssertEqual(flags(p), Flags(saving: true))
        p.apply(.takeSaved)
        XCTAssertEqual(flags(p), Flags())
    }

    func testPauseAndResume() {
        var p = run([.takeBegan, .takePaused])
        XCTAssertEqual(flags(p), Flags(recording: true, paused: true))
        p.apply(.takeResumed)
        XCTAssertEqual(flags(p), Flags(recording: true))
        // The old paused flag survived the end of a paused take until the next one.
        p.apply(.takePaused)
        p.apply(.takeFinishing)
        p.apply(.takeSaved)
        XCTAssertEqual(flags(p), Flags(paused: true))
        p.apply(.takeBegan)
        XCTAssertEqual(flags(p), Flags(recording: true))
    }

    func testRecorderStoppedItself() {
        var p = run([.recordStartRequested, .recordPictureUp, .takeBegan, .recordStartTaskFinished])
        p.apply(.recorderStoppedItself)
        XCTAssertEqual(flags(p), Flags(recordOnly: true))
        // Not rolling: nothing to do.
        p.apply(.recorderStoppedItself)
        XCTAssertEqual(flags(p), Flags(recordOnly: true))
    }
}
