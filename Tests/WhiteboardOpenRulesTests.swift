import XCTest

final class WhiteboardOpenRulesTests: XCTestCase {
    func testOpeningFromToolsIsLocalWhateverTheMeetingSees() {
        XCTAssertEqual(WhiteboardOpenRules.toolAction(shareIsWhiteboard: false, localIsOpen: false), .openLocal)
    }

    func testToolTogglesTheLocalWindowAway() {
        XCTAssertEqual(WhiteboardOpenRules.toolAction(shareIsWhiteboard: false, localIsOpen: true), .closeLocal)
    }

    func testWhenWhiteboardIsTheShareToolNeverChangesIt() {
        XCTAssertEqual(WhiteboardOpenRules.toolAction(shareIsWhiteboard: true, localIsOpen: false), .raisePresented)
        XCTAssertEqual(WhiteboardOpenRules.toolAction(shareIsWhiteboard: true, localIsOpen: true), .raisePresented)
    }

    func testOnlyAPresentedWhiteboardFeedsTheStage() {
        XCTAssertTrue(WhiteboardOpenRules.feedsStage(shareIsWhiteboard: true))
        XCTAssertFalse(WhiteboardOpenRules.feedsStage(shareIsWhiteboard: false))
    }

    func testBackToScreenReturnsToTheTargetBeforeTheWhiteboard() {
        var r: String? = nil
        r = WhiteboardOpenRules.remembered(r, replaced: "window", oldIsWhiteboard: false, newIsWhiteboard: true)
        XCTAssertEqual(WhiteboardOpenRules.returnTarget(remembered: r, fallback: "default"), "window")
        r = WhiteboardOpenRules.remembered(r, replaced: "whiteboard", oldIsWhiteboard: true, newIsWhiteboard: true)
        XCTAssertEqual(r, "window", "a change while it is the whiteboard keeps it")
        XCTAssertEqual(WhiteboardOpenRules.remembered(r, replaced: "whiteboard", oldIsWhiteboard: true, newIsWhiteboard: false), "window")
        XCTAssertNil(WhiteboardOpenRules.remembered(r, replaced: "display", oldIsWhiteboard: false, newIsWhiteboard: false))
        XCTAssertEqual(WhiteboardOpenRules.returnTarget(remembered: nil, fallback: "default"), "default")
    }

    func testClosingTheLocalWhiteboardAlwaysRestoresTheDrawingStateItFound() {
        XCTAssertEqual(WhiteboardOpenRules.closeOutcome(wasSuspended: true, shareIsWhiteboard: false, shareIsNothing: false), .resumeCanvas)
        XCTAssertEqual(WhiteboardOpenRules.closeOutcome(wasSuspended: false, shareIsWhiteboard: false, shareIsNothing: false), .drawingOff)
        XCTAssertEqual(WhiteboardOpenRules.closeOutcome(wasSuspended: true, shareIsWhiteboard: false, shareIsNothing: true), .drawingOff,
                       "Just me: no screen to draw on, but nothing stays stuck")
        XCTAssertEqual(WhiteboardOpenRules.closeOutcome(wasSuspended: true, shareIsWhiteboard: true, shareIsNothing: false), .untouched)
    }

    // R8.6 (owner bug list, decided 2026-11-25): the Annotations whiteboard opens visible to everyone.
    // The one place that says so is ShareableWindow.startsShown; every other Greenroom window starts hidden.
    func testALocalWhiteboardOpensVisibleToEveryoneAndEveryOtherWindowStaysHidden() {
        XCTAssertTrue(ShareableWindow.localWhiteboard.offersSwitch)
        XCTAssertTrue(ShareableWindow.localWhiteboard.startsShown)
        for window in ShareableWindow.allCases where window != .localWhiteboard {
            XCTAssertFalse(window.startsShown, "\(window) still starts hidden")
        }
        // The presented whiteboard is its own share and never carries the eye.
        XCTAssertFalse(ShareableWindow.whiteboard.offersSwitch)
    }

    // R8.6, R8.5: open, flip off, reopen, as the capture's exception list sees it on a whole-display share.
    func testOpeningFlippingAndReopeningTheLocalWhiteboardFollowsTheEyeInTheExceptionList() {
        let number = 41
        func listed(on: Bool) -> Bool { (ShowOnShare.exceptionIDs(kind: .display, registry: on ? [number] : []) ?? []).contains(number) }
        var on = ShareableWindow.localWhiteboard.startsShown                      // opened
        XCTAssertEqual(Visibility.windowBadge(.localWhiteboard, marked: on, target: .wholeScreen), .on)
        XCTAssertEqual(ShareSwitchState(on: on, kind: .display).visibility, .classSees)
        XCTAssertTrue(listed(on: on))
        on.toggle()                                                                // the owner turns the eye off
        XCTAssertEqual(Visibility.windowBadge(.localWhiteboard, marked: on, target: .wholeScreen), .off)
        XCTAssertFalse(listed(on: on))
        on = ShareableWindow.localWhiteboard.startsShown                          // reopened
        XCTAssertTrue(listed(on: on))
    }

    // R8.1, R8.6: opening it never changes the share; in a window share it is not in the picture.
    func testTheLocalWhiteboardIsNotInAWindowShare() {
        XCTAssertEqual(Visibility.windowBadge(.localWhiteboard, marked: true, target: .window(bundleID: nil)).isOn, false)
        XCTAssertNil(ShowOnShare.exceptionIDs(kind: .app, registry: [41]))
    }
}
