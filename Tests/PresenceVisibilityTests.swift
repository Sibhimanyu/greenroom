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
    // R1, R6 (owner, 2026-11-25): the camera's state decides whether the bubble shows, never the share kind.
    func testShowsForWhiteboardWhenCameraIsOnMyScreen() {
        XCTAssertEqual(decide { $0.shareKind = .whiteboard }, .show)
        XCTAssertEqual(decide { $0.shareKind = .whiteboard; $0.hiddenByPresenter = true }, .hideKeepingPlacement)
    }
    func testShowsForJustMyCameraWhenCameraIsOnMyScreen() {
        XCTAssertEqual(decide { $0.shareKind = .nothing }, .show)
        XCTAssertEqual(decide { $0.shareKind = .nothing; $0.hiddenByPresenter = true }, .hideKeepingPlacement)
    }
    // R1, R6: every share kind x the four camera states: the bubble follows `Visibility.cameraOnMyScreen`.
    func testTheBubbleAgreesWithTheMenuForEveryShareKindAndCameraState() {
        let kinds: [PresenceVisibility.ShareKind] = [.display, .app, .window, .whiteboard, .nothing]
        for kind in kinds {
            for state in CameraState.allCases {
                let seen = Visibility.cameraOnMyScreen(state: state).isOn
                let got = decide {
                    $0.shareKind = kind
                    $0.hiddenByPresenter = PresenceVisibility.bubbleStartsHidden(state: state)
                }
                XCTAssertEqual(got == .show, seen, "\(kind) \(state)")
            }
        }
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
