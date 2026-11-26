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
        let offered: [ShareableWindow] = [.main, .settings, .meetingChat, .participants, .meetingWindow, .meetingView, .localWhiteboard]
        for window in ShareableWindow.allCases {
            XCTAssertEqual(window.offersSwitch, offered.contains(window), "\(window)")
            XCTAssertEqual(window.exclusionReason == nil, window.offersSwitch, "\(window)")
        }
        XCTAssertFalse(ShareableWindow.setupGuide.offersSwitch)
        XCTAssertFalse(ShareableWindow.controlBar.offersSwitch)
    }

    // Owner bug list R14: the setup guide is visible to other apps' captures; it has no eye only because
    // it is not content, and its reason no longer says credentials are hidden.
    func testSetupGuideReasonIsNotAboutHidingCredentials() {
        let reason = ShareableWindow.setupGuide.exclusionReason ?? ""
        XCTAssertFalse(reason.lowercased().contains("credential"), reason)
        XCTAssertFalse(reason.isEmpty)
    }

    // Owner bug list R14: every secret is dotted. No plain TextField may be titled or bound to a secret.
    func testNoSecretIsEverInAPlainTextField() throws {
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/UI")
        let files = try FileManager.default.contentsOfDirectory(at: ui, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var secretFields = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                if line.contains("TextField(") && !line.contains("SecureField(")
                    && line.range(of: "secret|token", options: [.regularExpression, .caseInsensitive]) != nil {
                    XCTFail("\(file.lastPathComponent):\(n + 1) puts a secret in a plain TextField")
                }
                if line.contains("SecureField(") { secretFields += 1 }
            }
        }
        // The Zoom keys and the YouTube client moved out of Settings into the setup guide (2026-11-26):
        // the guide's Zoom field helper (both Zoom secrets) and the guide's own field helper (YouTube).
        XCTAssertGreaterThanOrEqual(secretFields, 2)
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
