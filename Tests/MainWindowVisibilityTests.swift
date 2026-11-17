import XCTest

final class MainWindowVisibilityTests: XCTestCase {

    func testGoingLiveRemembersTheFrameAndHides() {
        var v = MainWindowVisibility()
        XCTAssertEqual(v.handle(.liveChanged(true)), [.rememberFrame, .hide])
        XCTAssertTrue(v.hiddenByUs)
    }

    func testStillGettingReadyChangesNothing() {
        var v = MainWindowVisibility()
        XCTAssertEqual(v.handle(.liveChanged(false)), [])
        XCTAssertFalse(v.hiddenByUs)
    }

    func testStayingLiveDoesNotHideAgain() {
        var v = MainWindowVisibility()
        _ = v.handle(.liveChanged(true))
        XCTAssertEqual(v.handle(.liveChanged(true)), [])
    }

    func testEndRestoresTheFrameOnHomeAndShows() {
        var v = MainWindowVisibility()
        _ = v.handle(.liveChanged(true))
        XCTAssertEqual(v.handle(.liveChanged(false)), [.restoreFrame, .goHome, .show])
        XCTAssertFalse(v.hiddenByUs)
    }

    func testFailureAfterHidingShowsTheWindow() {
        var v = MainWindowVisibility()
        _ = v.handle(.liveChanged(true))
        XCTAssertEqual(v.handle(.startFailed), [.restoreFrame, .goHome, .show])
    }

    func testFailureThatNeverHidShowsInPlace() {
        var v = MainWindowVisibility()
        XCTAssertEqual(v.handle(.startFailed), [.show])
    }

    func testOpeningOnPurposeStaysOpenUntilTheNextSession() {
        var v = MainWindowVisibility()
        _ = v.handle(.liveChanged(true))
        XCTAssertEqual(v.handle(.openedOnPurpose), [])
        XCTAssertFalse(v.hiddenByUs)
        // Still live: nothing hides it again.
        XCTAssertEqual(v.handle(.liveChanged(true)), [])
        // The end only brings it forward, where it is.
        XCTAssertEqual(v.handle(.liveChanged(false)), [.show])
        // The next session hides it again.
        XCTAssertEqual(v.handle(.liveChanged(true)), [.rememberFrame, .hide])
    }

    func testQuitDoesNotReshow() {
        var v = MainWindowVisibility()
        _ = v.handle(.liveChanged(true))
        XCTAssertEqual(v.handle(.quitting), [])
        XCTAssertEqual(v.handle(.liveChanged(false)), [])
        XCTAssertEqual(v.handle(.startFailed), [])
    }

    // MARK: Home steps aside at the click

    func testTheClickHidesHomeAtOnce() {
        var v = MainWindowVisibility()
        XCTAssertEqual(v.handle(.startBegan), [.rememberFrame, .hideForStart])
        XCTAssertTrue(v.hiddenByUs)
    }

    func testGoingLiveAfterTheClickDoesNotHideAgain() {
        var v = MainWindowVisibility()
        _ = v.handle(.startBegan)
        XCTAssertEqual(v.handle(.liveChanged(true)), [])
        // The end then brings Home back as it always did.
        XCTAssertEqual(v.handle(.liveChanged(false)), [.restoreFrame, .goHome, .show])
    }

    func testAFailedOrCancelledStartBringsHomeBackWhereItWas() {
        var v = MainWindowVisibility()
        _ = v.handle(.startBegan)
        XCTAssertEqual(v.handle(.startFailed), [.showAfterStart], "no goHome: the page is as it was")
        XCTAssertFalse(v.hiddenByUs)
    }

    func testAFailureAfterLiveStillGoesHome() {
        var v = MainWindowVisibility()
        _ = v.handle(.startBegan)
        _ = v.handle(.liveChanged(true))
        XCTAssertEqual(v.handle(.startFailed), [.restoreFrame, .goHome, .show])
    }

    func testOpeningHomeOnPurposeDuringTheStartIsRespected() {
        var v = MainWindowVisibility()
        _ = v.handle(.startBegan)
        XCTAssertEqual(v.handle(.openedOnPurpose), [])
        XCTAssertEqual(v.handle(.startFailed), [.show])
    }

    func testQuitDuringAStartHidesNothing() {
        var v = MainWindowVisibility()
        _ = v.handle(.quitting)
        XCTAssertEqual(v.handle(.startBegan), [])
    }
}
