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
        p.apply(.meetingStartTaskFinished(startID: 1))
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
        p.apply(.recordStartTaskFinished(startID: 1))
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
        var q = run([.recordStartRequested, .recordPictureUp, .takeBegan, .recordStartTaskFinished(startID: 1),
                     .stopRequested, .takeFinishing, .recordPictureDown, .recordStopFinished])
        XCTAssertEqual(flags(q), Flags(saving: true))
        q.apply(.takeSaved)
        XCTAssertEqual(flags(q), Flags())
    }

    func testStopWhileRecordStartIsPending() {
        var p = run([.recordStartRequested, .recordPictureUp, .stopRequested])
        XCTAssertEqual(flags(p), Flags(running: true, stopping: true, recordOnly: true, startingRecord: true))
        p.apply(.recordPictureDown)
        p.apply(.recordStartTaskFinished(startID: 1))
        XCTAssertEqual(flags(p), Flags(stopping: true))
        p.apply(.recordStopFinished)
        XCTAssertEqual(flags(p), Flags())
    }

    func testFailedMeetingStart() {
        var p = run([.meetingStartRequested, .stopRequested])
        XCTAssertEqual(flags(p), Flags(running: true, stopping: true))
        p.apply(.meetingStartTaskFinished(startID: 1))
        XCTAssertEqual(flags(p), Flags(stopping: true))
        p.apply(.meetingTornDown)
        XCTAssertEqual(flags(p), Flags())
    }

    func testFailedRecordStart() {
        let p = run([.recordStartRequested, .recordPictureUp, .recordPictureDown, .recordStartTaskFinished(startID: 1)])
        XCTAssertEqual(flags(p), Flags())
    }

    func testCancelledMeetingStartEitherOrderEndsIdle() {
        let a = run([.meetingStartRequested, .stopRequested, .meetingStartTaskFinished(startID: 1), .meetingTornDown])
        let b = run([.meetingStartRequested, .stopRequested, .meetingTornDown, .meetingStartTaskFinished(startID: 1)])
        XCTAssertEqual(flags(a), Flags())
        XCTAssertEqual(flags(b), Flags())
        // The old race: a late end of the cancelled start used to clear a newer start.
        // Now it is ignored, and the new start's own end still clears it.
        var c = run([.meetingStartRequested, .stopRequested, .meetingTornDown, .meetingStartRequested])
        let older = c.startID - 1
        c.apply(.meetingStartTaskFinished(startID: older))
        XCTAssertTrue(c.isRunning)
        c.apply(.meetingStartTaskFinished(startID: c.startID))
        XCTAssertFalse(c.isRunning)
    }

    func testStaleMeetingFinishAfterNewRecordStartIsIgnored() {
        var p = run([.meetingStartRequested, .stopRequested, .meetingTornDown, .recordStartRequested, .recordPictureUp])
        let older = p.startID - 1
        p.apply(.meetingStartTaskFinished(startID: older))
        XCTAssertTrue(p.isRunning && p.startingRecordOnly)
    }

    func testStaleRecordFinishAfterNewRecordStartIsIgnored() {
        var p = run([.recordStartRequested, .recordPictureUp, .stopRequested, .recordPictureDown, .recordStopFinished,
                     .recordStartRequested])
        let older = p.startID - 1
        p.apply(.recordStartTaskFinished(startID: older))
        XCTAssertTrue(p.isRunning && p.startingRecordOnly)
        p.apply(.recordStartTaskFinished(startID: p.startID))
        XCTAssertFalse(p.isRunning)
    }

    func testNormalFinishStillClears() {
        var p = run([.meetingStartRequested, .meetingPictureUp])
        p.apply(.meetingStartTaskFinished(startID: p.startID))
        XCTAssertFalse(p.isRunning)
        XCTAssertTrue(p.stageLive)
    }

    func testTakeDuringAMeeting() {
        var p = run([.meetingStartRequested, .meetingPictureUp, .meetingStartTaskFinished(startID: 1), .takeBegan])
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
        let p = run([.meetingStartRequested, .meetingPictureUp, .takeBegan, .meetingStartTaskFinished(startID: 1)])
        XCTAssertFalse(p.isRunning)
        XCTAssertTrue(p.stageLive)
        XCTAssertTrue(p.isRecording)
        XCTAssertEqual(p.session, .live(.meeting))
        XCTAssertEqual(p.take, .rolling)
    }

    func testRecordingCanContinueWhileStopping() {
        // End Session: the take is still rolling when Stop is requested.
        var p = run([.meetingStartRequested, .meetingPictureUp, .meetingStartTaskFinished(startID: 1),
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
        var p = run([.recordStartRequested, .recordPictureUp, .takeBegan, .recordStartTaskFinished(startID: 1)])
        p.apply(.recorderStoppedItself)
        XCTAssertEqual(flags(p), Flags(recordOnly: true))
        // Not rolling: nothing to do.
        p.apply(.recorderStoppedItself)
        XCTAssertEqual(flags(p), Flags(recordOnly: true))
    }

    func testSessionOrTakeOnScreenCountsRecordSessionBetweenTakes() {
        XCTAssertFalse(SessionPhase().hasSessionOrTakeOnScreen)
        // Record session up, start task finished, no take rolling: the old check missed this.
        let between = run([.recordStartRequested, .recordPictureUp, .recordStartTaskFinished(startID: 1)])
        XCTAssertTrue(between.recordOnlyActive)
        XCTAssertFalse(between.isRunning || between.stageLive || between.isRecording)
        XCTAssertTrue(between.hasSessionOrTakeOnScreen)
        XCTAssertTrue(run([.meetingStartRequested]).hasSessionOrTakeOnScreen)
        XCTAssertTrue(run([.meetingStartRequested, .meetingPictureUp, .meetingStartTaskFinished(startID: 1)]).hasSessionOrTakeOnScreen)
        XCTAssertTrue(run([.recordStartRequested, .recordPictureUp, .takeBegan, .recordStartTaskFinished(startID: 1)]).hasSessionOrTakeOnScreen)
        let done = run([.recordStartRequested, .recordPictureUp, .recordStartTaskFinished(startID: 1), .stopRequested, .recordPictureDown, .recordStopFinished])
        XCTAssertFalse(done.hasSessionOrTakeOnScreen)
    }

    // MARK: Named questions against the expressions they replaced

    /// Every state reachable by any sequence of events (a superset of the
    /// sequences the coordinator produces), found by breadth-first search. The
    /// finish events are tried with the current start number and a stale one.
    private func reachableStates() -> [SessionPhase] {
        func key(_ p: SessionPhase) -> String { "\(p.session)|\(p.take)|\(p.isRecordingPaused)" }
        var seen: [String: SessionPhase] = [:]
        var queue = [SessionPhase()]
        seen[key(queue[0])] = queue[0]
        while !queue.isEmpty {
            let p = queue.removeFirst()
            let events: [SessionPhase.Event] = [
                .meetingStartRequested, .meetingPictureUp,
                .meetingStartTaskFinished(startID: p.startID), .meetingStartTaskFinished(startID: p.startID - 1),
                .recordStartRequested, .recordPictureUp, .recordPictureDown,
                .recordStartTaskFinished(startID: p.startID), .recordStartTaskFinished(startID: p.startID - 1),
                .stopRequested, .meetingTornDown, .recordStopFinished,
                .takeBegan, .takePaused, .takeResumed, .takeFinishing, .takeFinishingAtMeetingEnd,
                .takeSaved, .recorderStoppedItself, .takeDroppedAtQuit,
            ]
            for e in events {
                var n = p
                n.apply(e)
                if seen[key(n)] == nil { seen[key(n)] = n; queue.append(n) }
            }
        }
        return Array(seen.values)
    }

    func testReachableStatesAreEnumerated() {
        XCTAssertGreaterThan(reachableStates().count, 30)
    }

    func testInMeetingMatchesOldExpression() {
        for p in reachableStates() {
            XCTAssertEqual(p.isInMeeting, p.isRunning || p.stageLive, "\(p.session) \(p.take)")
        }
    }

    func testCameraBusyMatchesBothOldSpellings() {
        for p in reachableStates() {
            XCTAssertEqual(p.sceneInUse, p.stageLive || p.recordOnlyActive)
            XCTAssertEqual(p.isCameraBusy, p.sceneInUse || p.isRunning, "\(p.session)")
            XCTAssertEqual(p.isCameraBusy, p.stageLive || p.recordOnlyActive || p.isRunning, "\(p.session)")
        }
    }

    func testCanStartMatchesOldExpressions() {
        for p in reachableStates() {
            XCTAssertEqual(p.canStart, !p.isRunning && !p.sceneInUse && !p.isStopping, "\(p.session)")
            // startActionDisabled's spelling is the exact negation.
            XCTAssertEqual(!p.canStart, p.isRunning || p.sceneInUse || p.isStopping)
            // toggleRecording's variant: ignores isStopping (guarded earlier) and asks about the take.
            XCTAssertEqual(!p.hasSessionOrTakeOnScreen, !p.isRunning && !p.sceneInUse && !p.isRecording, "\(p.session)")
        }
    }
}
