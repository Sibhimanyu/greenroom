import XCTest

/// Spec: docs/specs/display-changes.md (R1 to R4).
final class DisplayChangeRulesTests: XCTestCase {

    // Spec: display-changes R1
    func testLogLineSaysWhatWasPluggedOrPulled() {
        XCTAssertEqual(DisplayChange.logLine(removed: 1, added: 0, setChanged: true, now: "A"),
                       "Displays changed (1 unplugged). Now: A.")
        XCTAssertEqual(DisplayChange.logLine(removed: 0, added: 2, setChanged: true, now: "A, B"),
                       "Displays changed (2 connected). Now: A, B.")
        XCTAssertEqual(DisplayChange.logLine(removed: 1, added: 1, setChanged: true, now: "B"),
                       "Displays changed (1 unplugged, 1 connected). Now: B.")
    }
    // Spec: display-changes R1
    func testLogLineForTheSameDisplays() {
        XCTAssertEqual(DisplayChange.logLine(removed: 0, added: 0, setChanged: false, now: "A"),
                       "Display settings changed (resolution or arrangement). Now: A.")
    }

    private func follow(running: Bool = false, live: Bool = true, joined: Bool = true,
                        arranges: Bool = true, setChanged: Bool = true) -> DisplayChange.FollowUp {
        DisplayChange.followUp(isRunning: running, stageLive: live, joined: joined,
                               arranges: arranges, setChanged: setChanged)
    }

    // Spec: display-changes R2
    func testAChangeDuringAStartWaitsForTheStart() {
        XCTAssertEqual(follow(running: true, live: false), .deferToStart)
        XCTAssertEqual(follow(running: true), .deferToStart)
    }
    // Spec: display-changes R2
    func testNothingFollowsWithoutALiveJoinedArrangedSession() {
        XCTAssertEqual(follow(live: false), .nothing)
        XCTAssertEqual(follow(joined: false), .nothing)
        XCTAssertEqual(follow(arranges: false), .nothing)
    }
    // Spec: display-changes R2
    func testAPluggedOrPulledDisplayRetiles() {
        XCTAssertEqual(follow(setChanged: true), .snapBack(.displaysConnectedOrDisconnected))
    }
    // Spec: display-changes R2
    func testNewSettingsOnTheSameDisplaysLeaveWindowsAlone() {
        XCTAssertEqual(follow(setChanged: false), .leaveWindows)
    }

    // Spec: display-changes R3
    func testAStartRetilesAfterwardsOnlyWhenItArrangesAndAChangeHappened() {
        XCTAssertTrue(DisplayChange.snapAfterStart(changedDuringStart: true, arranges: true))
        XCTAssertFalse(DisplayChange.snapAfterStart(changedDuringStart: false, arranges: true))
        XCTAssertFalse(DisplayChange.snapAfterStart(changedDuringStart: true, arranges: false))
    }

    // Spec: display-changes R4
    func testSnapBackReturnsTheLayoutsOwnStartingState() {
        XCTAssertTrue(DisplayChange.hiddenAfterRetile(userInitiated: true, layoutStartsHidden: true, hasPlacedSurface: true, wasHidden: false))
        XCTAssertFalse(DisplayChange.hiddenAfterRetile(userInitiated: true, layoutStartsHidden: false, hasPlacedSurface: false, wasHidden: true))
    }
    // Spec: display-changes R4
    func testADisplayChangeUnhidesWhenThePlacedMeetingIsGone() {
        XCTAssertFalse(DisplayChange.hiddenAfterRetile(userInitiated: false, layoutStartsHidden: true, hasPlacedSurface: false, wasHidden: true))
        XCTAssertTrue(DisplayChange.hiddenAfterRetile(userInitiated: false, layoutStartsHidden: false, hasPlacedSurface: true, wasHidden: true))
        XCTAssertFalse(DisplayChange.hiddenAfterRetile(userInitiated: false, layoutStartsHidden: true, hasPlacedSurface: true, wasHidden: false))
    }
}
