import XCTest

final class LiveExitRulesTests: XCTestCase {

    private func state(_ kind: LiveExitState.Kind, recording: Bool = false, shrink: Bool = true) -> LiveExitState {
        LiveExitState(kind: kind, isRecording: recording, canShrink: shrink)
    }

    // Close

    func testIdleClosesWithoutAsking() {
        XCTAssertNil(LiveExit.closePrompt(state(.idle)))
    }

    func testHostCloseOffersEndShrinkCancel() {
        let p = LiveExit.closePrompt(state(.host))
        XCTAssertEqual(p?.choices, [.endMeetingForAll, .shrinkToControlBar, .cancel])
    }

    func testParticipantCloseOffersLeaveShrinkCancel() {
        XCTAssertEqual(LiveExit.closePrompt(state(.participant))?.choices, [.leaveMeeting, .shrinkToControlBar, .cancel])
    }

    func testNoShrinkWhenTheWindowCannotShrink() {
        XCTAssertEqual(LiveExit.closePrompt(state(.host, shrink: false))?.choices, [.endMeetingForAll, .cancel])
    }

    func testCancelIsAlwaysLast() {
        for kind in [LiveExitState.Kind.host, .participant] {
            XCTAssertEqual(LiveExit.closePrompt(state(kind))?.choices.last, .cancel)
            XCTAssertEqual(LiveExit.quitPrompt(state(kind))?.choices.last, .cancel)
        }
    }

    func testRecordingIsMentionedOnlyWhenRecording() {
        XCTAssertTrue(LiveExit.closePrompt(state(.host, recording: true))!.message.contains("Recording will stop and be saved."))
        XCTAssertFalse(LiveExit.closePrompt(state(.host))!.message.contains("Recording"))
        XCTAssertTrue(LiveExit.quitPrompt(state(.participant, recording: true))!.message.contains("Recording will stop and be saved."))
    }

    func testRecordOnlyHasNoMeetingWindowClosePrompt() {
        XCTAssertNil(LiveExit.closePrompt(state(.recordOnly, recording: true)))
    }

    func testOnlyTheEndingChoicesAreDestructive() {
        XCTAssertTrue(LiveExitChoice.endMeetingForAll.isDestructive)
        XCTAssertFalse(LiveExitChoice.shrinkToControlBar.isDestructive)
        XCTAssertFalse(LiveExitChoice.cancel.isDestructive)
    }

    // Quit

    func testQuitIdleIsSilent() {
        XCTAssertNil(LiveExit.quitPrompt(state(.idle)))
    }

    func testQuitChoicesByRole() {
        XCTAssertEqual(LiveExit.quitPrompt(state(.host))?.choices, [.endMeetingAndQuit, .cancel])
        XCTAssertEqual(LiveExit.quitPrompt(state(.participant))?.choices, [.leaveAndQuit, .cancel])
        XCTAssertEqual(LiveExit.quitPrompt(state(.recordOnly, recording: true))?.choices, [.stopRecordingAndQuit, .cancel])
        XCTAssertEqual(LiveExit.quitPrompt(state(.recordOnly))?.choices, [.quit, .cancel])
    }

    func testQuitButtonTitles() {
        XCTAssertEqual(LiveExitChoice.endMeetingAndQuit.title, "End Meeting & Quit")
        XCTAssertEqual(LiveExitChoice.leaveAndQuit.title, "Leave & Quit")
        XCTAssertEqual(LiveExitChoice.stopRecordingAndQuit.title, "Stop Recording & Quit")
    }

    func testSystemEndNeverAsks() {
        XCTAssertNil(LiveExit.quitPrompt(state(.host, recording: true), systemEnding: true))
    }

    func testQuitReasons() {
        func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
        XCTAssertTrue(LiveExit.isSystemEnd(quitReason: code("shut")))
        XCTAssertTrue(LiveExit.isSystemEnd(quitReason: code("rlgo")))
        XCTAssertTrue(LiveExit.isSystemEnd(quitReason: code("rest")))
        XCTAssertFalse(LiveExit.isSystemEnd(quitReason: nil))
        XCTAssertFalse(LiveExit.isSystemEnd(quitReason: code("abcd")))
    }

    // Reopen

    func testReopenIdleShowsMainWindow() {
        XCTAssertEqual(LiveExit.reopenTarget(.init()), .mainWindow)
        XCTAssertFalse(LiveExit.reopenHandledByMeeting(.init()))
    }

    func testReopenLiveMeetingRestoresWindow() {
        let s = LiveExit.ReopenState(isLive: true, hasMeetingSurfaces: true, meetingShrunk: false)
        XCTAssertEqual(LiveExit.reopenTarget(s), .meetingWindow)
        XCTAssertTrue(LiveExit.reopenHandledByMeeting(s))
    }

    func testReopenShrunkMeetingFrontsTheControlBar() {
        let s = LiveExit.ReopenState(isLive: true, hasMeetingSurfaces: true, meetingShrunk: true)
        XCTAssertEqual(LiveExit.reopenTarget(s), .controlBar)
    }

    func testReopenRecordOnlyShowsMainWindowLiveState() {
        let s = LiveExit.ReopenState(isLive: true, hasMeetingSurfaces: false, meetingShrunk: false)
        XCTAssertEqual(LiveExit.reopenTarget(s), .mainWindow)
        XCTAssertFalse(LiveExit.reopenHandledByMeeting(s))
    }
}

final class EndConfirmTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testFirstPressArmsSecondEnds() {
        var c = EndConfirm()
        XCTAssertEqual(c.press(now: t0), .arm)
        XCTAssertTrue(c.isConfirming)
        XCTAssertEqual(c.press(now: t0.addingTimeInterval(0.1)), .end)
        XCTAssertTrue(c.isEnding)
        XCTAssertEqual(c.press(now: t0.addingTimeInterval(0.2)), .none)
    }

    func testCancelReturnsToIdleButNotWhileEnding() {
        var c = EndConfirm()
        _ = c.press(now: t0)
        c.cancel()
        XCTAssertEqual(c.phase, .idle)
        _ = c.press(now: t0); _ = c.press(now: t0)
        c.cancel()
        XCTAssertTrue(c.isEnding)
    }

    func testExpiresAfterTimeoutOnly() {
        var c = EndConfirm()
        _ = c.press(now: t0)
        XCTAssertFalse(c.expire(now: t0.addingTimeInterval(EndConfirm.timeout - 0.1)))
        XCTAssertTrue(c.expire(now: t0.addingTimeInterval(EndConfirm.timeout)))
        XCTAssertEqual(c.phase, .idle)
        XCTAssertFalse(c.expire(now: t0.addingTimeInterval(100)))
    }

    func testCountdownFillRunsFromOneToZero() {
        var c = EndConfirm()
        XCTAssertEqual(c.remaining(now: t0), 0)
        _ = c.press(now: t0)
        XCTAssertEqual(c.remaining(now: t0), 1, accuracy: 0.001)
        XCTAssertEqual(c.remaining(now: t0.addingTimeInterval(EndConfirm.timeout / 2)), 0.5, accuracy: 0.001)
        XCTAssertEqual(c.remaining(now: t0.addingTimeInterval(99)), 0)
    }
}
