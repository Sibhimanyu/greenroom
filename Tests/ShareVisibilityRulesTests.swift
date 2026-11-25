import XCTest

final class ShareVisibilityRulesTests: XCTestCase {
    func testWordsAndIconsForEachState() {
        XCTAssertEqual(ShareVisibility.classSees.label, "Everyone sees this")
        XCTAssertEqual(ShareVisibility.onlyYou.label, "Only you")
        XCTAssertEqual(ShareVisibility.classSees.symbol, "eye")
        XCTAssertEqual(ShareVisibility.onlyYou.symbol, "eye.slash")
    }

    func testMarkedMeansTheClassSees() {
        XCTAssertEqual(ShareVisibility(marked: true), .classSees)
        XCTAssertEqual(ShareVisibility(marked: false), .onlyYou)
        // On, but the share is an app: nothing goes out, so it reads "Only you".
        XCTAssertEqual(ShareVisibility(marked: ShowOnShare.marksWindow(on: true, kind: .app)), .onlyYou)
        XCTAssertEqual(ShareVisibility(marked: ShowOnShare.marksWindow(on: true, kind: .display)), .classSees)
    }

    func testFrostedWhenHiddenSolidWhenSeen() {
        XCTAssertEqual(ShareVisibility.onlyYou.backdrop, .frosted)
        XCTAssertEqual(ShareVisibility.classSees.backdrop, .solid)
    }

    func testTransitionIsInstantUnderReduceMotion() {
        XCTAssertEqual(WindowBackdrop.transitionDuration(reduceMotion: true), 0)
        XCTAssertGreaterThan(WindowBackdrop.transitionDuration(reduceMotion: false), 0)
    }

    func testWhichWindowsOfferTheSwitch() {
        let offered: [ShareableWindow] = [.main, .settings, .meetingChat, .participants, .meetingWindow, .meetingView]
        for window in ShareableWindow.allCases {
            XCTAssertEqual(window.offersSwitch, offered.contains(window), "\(window)")
            XCTAssertEqual(window.exclusionReason == nil, window.offersSwitch, "\(window)")
        }
        XCTAssertFalse(ShareableWindow.setupGuide.offersSwitch)
        XCTAssertFalse(ShareableWindow.controlBar.offersSwitch)
    }

    func testSwitchStateHiddenByDefault() {
        let state = ShareSwitchState(on: false, kind: .display)
        XCTAssertEqual(state.visibility, .onlyYou)
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.help, "Only you: the meeting can't see this window. Click to show it to everyone.")
        XCTAssertEqual(state.accessibilityValue, "Only you")
        XCTAssertEqual(state.accessibilityLabel, "Show to everyone")
    }

    func testSwitchStateShownOnADisplayShare() {
        let state = ShareSwitchState(on: true, kind: .display)
        XCTAssertEqual(state.visibility, .classSees)
        XCTAssertEqual(state.help, "Everyone in the meeting sees this window. Click to hide it.")
        XCTAssertEqual(state.accessibilityValue, "Everyone sees this")
    }

    func testSwitchDisabledUnlessAWholeDisplayIsShared() {
        for kind: ShowOnShare.ShareKind in [.app, .window, .other] {
            for on in [false, true] {
                let state = ShareSwitchState(on: on, kind: kind)
                XCTAssertFalse(state.isEnabled)
                XCTAssertEqual(state.visibility, .onlyYou)
                XCTAssertEqual(state.help, ShowOnShare.unavailableTip)
            }
        }
    }

    func testOnlyTheBrowserIsAlwaysShared() {
        for kind in ShareableWindow.allCases {
            XCTAssertEqual(ShareVisibilityRules.alwaysShared(windowKind: kind), kind == .browser, "\(kind)")
        }
        XCTAssertFalse(ShareVisibilityRules.alwaysShared(windowKind: .setupGuide))
    }

    func testAlwaysSharedWindowsAreExceptedOnAWholeDisplayWithNoSwitch() {
        XCTAssertEqual(ShowOnShare.exceptionIDs(kind: .display, registry: [], alwaysShared: [7]), [7])
        XCTAssertEqual(ShowOnShare.exceptionIDs(kind: .display, registry: [3], alwaysShared: [7]), [3, 7])
        XCTAssertNil(ShowOnShare.exceptionIDs(kind: .app, registry: [], alwaysShared: [7]))
    }

    // R6.1: one named question for "is Just my camera chosen", instead of three spellings of it.
    func testSharesNothingIsTheJustMyCameraChoice() {
        var t = ShareTarget()
        XCTAssertFalse(t.sharesNothing)
        t.kind = .nothing
        XCTAssertTrue(t.sharesNothing)
        t.kind = .whiteboard
        XCTAssertFalse(t.sharesNothing)
    }

    // R7.2: a newly launched hidden app that ScreenCaptureKit hasn't listed yet is retried, not recorded as done.
    func testAHiddenAppTheCaptureCannotSeeYetIsRetried() {
        let unresolved = ExclusionResolution.unresolved(hidden: ["a.safari", "b.mail"], running: ["a.safari", "b.mail"],
                                                        listed: ["b.mail"])
        XCTAssertEqual(unresolved, ["a.safari"])
        XCTAssertFalse(ExclusionResolution.isSettled(hidden: ["a.safari"], running: ["a.safari"], listed: []))
        XCTAssertTrue(ExclusionResolution.isSettled(hidden: ["a.safari"], running: ["a.safari"], listed: ["a.safari"]))
    }

    // R7.2: a hidden app that is not running has nothing to exclude, so it never blocks "done".
    func testAHiddenAppThatIsNotRunningIsSettled() {
        XCTAssertTrue(ExclusionResolution.isSettled(hidden: ["a.safari"], running: [], listed: []))
    }
}
