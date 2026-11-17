import XCTest

final class ShareVisibilityRulesTests: XCTestCase {
    func testWordsAndIconsForEachState() {
        XCTAssertEqual(ShareVisibility.classSees.label, "Class sees this")
        XCTAssertEqual(ShareVisibility.onlyYou.label, "Only you")
        XCTAssertEqual(ShareVisibility.classSees.symbol, "eye")
        XCTAssertEqual(ShareVisibility.onlyYou.symbol, "eye.slash")
        XCTAssertEqual(ShowOnShare.borderLabel, "Class sees this")
    }

    func testMarkedMeansTheClassSees() {
        XCTAssertEqual(ShareVisibility(marked: true), .classSees)
        XCTAssertEqual(ShareVisibility(marked: false), .onlyYou)
        // On, but the share is an app: nothing goes out, so it reads "Only you".
        XCTAssertEqual(ShareVisibility(marked: ShowOnShare.marksWindow(on: true, kind: .app)), .onlyYou)
        XCTAssertEqual(ShareVisibility(marked: ShowOnShare.marksWindow(on: true, kind: .display)), .classSees)
    }

    func testFrostedWhenHiddenSolidWithEdgeWhenSeen() {
        XCTAssertEqual(ShareVisibility.onlyYou.backdrop, .frosted)
        XCTAssertEqual(ShareVisibility.classSees.backdrop, .solid)
        XCTAssertFalse(WindowBackdrop.frosted.hasEdge)
        XCTAssertTrue(WindowBackdrop.solid.hasEdge)
    }

    func testTransitionIsInstantUnderReduceMotion() {
        XCTAssertEqual(WindowBackdrop.transitionDuration(reduceMotion: true), 0)
        XCTAssertGreaterThan(WindowBackdrop.transitionDuration(reduceMotion: false), 0)
    }

    func testToastOnlyOnAChangeAndOnlyOnce() {
        XCTAssertEqual(ShareVisibilityExplainer.toast(was: .onlyYou, now: .classSees, alreadyExplained: false),
                       "The class sees this window.")
        XCTAssertEqual(ShareVisibilityExplainer.toast(was: .classSees, now: .onlyYou, alreadyExplained: false),
                       "Hidden from the class. Only you see this window.")
        XCTAssertNil(ShareVisibilityExplainer.toast(was: .onlyYou, now: .onlyYou, alreadyExplained: false))
        XCTAssertNil(ShareVisibilityExplainer.toast(was: .onlyYou, now: .classSees, alreadyExplained: true))
    }

    func testExplainedFlagIsPerMac() {
        let defaults = UserDefaults(suiteName: "ShareVisibilityRulesTests")!
        defaults.removePersistentDomain(forName: "ShareVisibilityRulesTests")
        XCTAssertFalse(ShareVisibilityExplainer.hasExplained(defaults))
        ShareVisibilityExplainer.markExplained(defaults)
        XCTAssertTrue(ShareVisibilityExplainer.hasExplained(defaults))
        defaults.removePersistentDomain(forName: "ShareVisibilityRulesTests")
    }

    func testWhichWindowsOfferTheSwitch() {
        let offered: [ShareableWindow] = [.main, .settings, .meetingChat, .participants, .meetingWindow, .meetingView, .mini]
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
        XCTAssertEqual(state.help, "Only you: the class can't see this window. Click to show it to the class.")
        XCTAssertEqual(state.accessibilityValue, "Only you")
        XCTAssertEqual(state.accessibilityLabel, "Show to class")
    }

    func testSwitchStateShownOnADisplayShare() {
        let state = ShareSwitchState(on: true, kind: .display)
        XCTAssertEqual(state.visibility, .classSees)
        XCTAssertEqual(state.help, "The class sees this window. Click to hide it.")
        XCTAssertEqual(state.accessibilityValue, "Class sees this")
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
}
