import XCTest

final class PresenceVisibilityTests: XCTestCase {
    private func decide(_ edit: (inout PresenceVisibility.Inputs) -> Void = { _ in }) -> PresenceVisibility.Decision {
        var i = PresenceVisibility.Inputs()
        edit(&i)
        return PresenceVisibility.decide(i)
    }

    func testShowsWhenEverythingIsInPlace() { XCTAssertEqual(decide(), .show) }
    func testHiddenOnMyScreenOnlyStartsTheBubbleHidden() {
        XCTAssertTrue(PresenceVisibility.bubbleStartsHidden(shownOnMyScreen: false))
        XCTAssertFalse(PresenceVisibility.bubbleStartsHidden(shownOnMyScreen: true))
        // The Stage keeps the camera (layoutPlaceable follows noCamera, not this): the bubble is only hidden by the presenter flag.
        XCTAssertEqual(decide { $0.hiddenByPresenter = true }, .hideKeepingPlacement)
    }
    func testHidesWhenNotLive() { XCTAssertEqual(decide { $0.live = false }, .hide) }
    func testHidesWhenTheLookHasNoBoxToMove() { XCTAssertEqual(decide { $0.layoutPlaceable = false }, .hide) }
    func testHidesUntilTheCameraHasAFrame() { XCTAssertEqual(decide { $0.hasCapturedFrame = false }, .hide) }
    func testHidesUntilTheContentWasDrawn() { XCTAssertEqual(decide { $0.hasContentRect = false }, .hide) }
    func testHidesForWhiteboardAndNothingShared() {
        XCTAssertEqual(decide { $0.shareKind = .whiteboard }, .hide)
        XCTAssertEqual(decide { $0.shareKind = .nothing }, .hide)
    }
    func testVideoOffHidesButKeepsThePlacement() { XCTAssertEqual(decide { $0.cameraOn = false }, .hideKeepingPlacement) }
    func testHideFlagHidesButKeepsThePlacement() { XCTAssertEqual(decide { $0.hiddenByPresenter = true }, .hideKeepingPlacement) }
    func testNativeZoomShareHidesButKeepsThePlacement() {
        XCTAssertEqual(decide { $0.nativeZoomShareActive = true }, .hideKeepingPlacement)
    }
    func testWindowAndAppSharesNeedTheirWindowOnScreen() {
        for kind in [PresenceVisibility.ShareKind.window, .app] {
            XCTAssertEqual(decide { $0.shareKind = kind }, .show)
            XCTAssertEqual(decide { $0.shareKind = kind; $0.sharedWindowVisible = false }, .hideKeepingPlacement)
        }
    }
    func testADisplayShareIgnoresWindowVisibility() {
        XCTAssertEqual(decide { $0.shareKind = .display; $0.sharedWindowVisible = false }, .show)
    }
    func testNothingToShowBeatsKeepingPlacement() {
        XCTAssertEqual(decide { $0.live = false; $0.hiddenByPresenter = true }, .hide)
    }
    func testPollsQuickerOnlyWhileAFollowedWindowHasABubbleUp() {
        XCTAssertEqual(PresenceVisibility.pollInterval(shareKind: .window, bubbleUp: true), 0.25)
        XCTAssertEqual(PresenceVisibility.pollInterval(shareKind: .app, bubbleUp: true), 0.25)
        XCTAssertEqual(PresenceVisibility.pollInterval(shareKind: .window, bubbleUp: false), 1)
        XCTAssertEqual(PresenceVisibility.pollInterval(shareKind: .display, bubbleUp: true), 1)
    }
}
