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

    func testReopenWithTheMiniUpFrontsTheMini() {
        let s = LiveExit.ReopenState(isLive: true, hasMeetingSurfaces: true, meetingShrunk: true, miniOpen: true)
        XCTAssertEqual(LiveExit.reopenTarget(s), .mini)
    }

    func testReopenRecordOnlyShowsMainWindowLiveState() {
        let s = LiveExit.ReopenState(isLive: true, hasMeetingSurfaces: false, meetingShrunk: false)
        XCTAssertEqual(LiveExit.reopenTarget(s), .mainWindow)
        XCTAssertFalse(LiveExit.reopenHandledByMeeting(s))
    }
}
