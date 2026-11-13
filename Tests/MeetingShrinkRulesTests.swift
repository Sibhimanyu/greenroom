import XCTest

final class MeetingShrinkRulesTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "MeetingShrinkRulesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Minimise

    func testMinimiseShrinksOnlyWhileAMeetingIsLiveAndCanShrink() {
        XCTAssertEqual(MeetingMinimize.outcome(meetingLive: true, canShrink: true), .shrinkToControlBar)
        XCTAssertEqual(MeetingMinimize.outcome(meetingLive: false, canShrink: true), .minimize)
        XCTAssertEqual(MeetingMinimize.outcome(meetingLive: true, canShrink: false), .minimize)
        XCTAssertEqual(MeetingMinimize.outcome(meetingLive: false, canShrink: false), .minimize)
    }

    // MARK: Tip

    func testTipShowsOnTheFirstWindowThenNeverAfterItIsDone() {
        let d = freshDefaults()
        XCTAssertTrue(MeetingShrinkTip.shouldShow(canShrink: true, defaults: d), "first meeting window on this Mac")
        XCTAssertFalse(MeetingShrinkTip.shouldShow(canShrink: false, defaults: d), "no Control bar button, no tip")
        MeetingShrinkTip.markDone(d) // shrunk once, or the x
        XCTAssertFalse(MeetingShrinkTip.shouldShow(canShrink: true, defaults: d))
        XCTAssertTrue(MeetingShrinkTip.isDone(d))
    }

    func testDebugResetShowsItAgain() {
        let d = freshDefaults()
        MeetingShrinkTip.markDone(d)
        MeetingShrinkTip.reset(d)
        XCTAssertTrue(MeetingShrinkTip.shouldShow(canShrink: true, defaults: d))
    }

    func testTipMessageCarriesTheBoundShortcut() {
        XCTAssertEqual(MeetingShrinkTip.message(shortcut: "\u{2318}M"),
                       "Shrink to the control bar to get back to your slides. \u{2318}M")
        XCTAssertEqual(MeetingShrinkTip.message(shortcut: ""), "Shrink to the control bar to get back to your slides.")
    }
}
