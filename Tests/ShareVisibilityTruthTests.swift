import XCTest

/// One truth for who sees what: the rule (`Visibility`) against a pure model of
/// the capture filter. The sample list is itself an exhaustive switch, so a new
/// `LayoutPiece.Kind` stops this file compiling until it is covered.
final class ShareVisibilityTruthTests: XCTestCase {
    private let chosenApp = "com.example.keynote"

    private enum Sample: CaseIterable { case meeting, chat, view, browser, otherApp, roomScreen }

    private func piece(_ s: Sample, shown: Bool, startsHidden: Bool = false, app: String? = nil) -> LayoutPiece {
        let kind: LayoutPiece.Kind
        switch s {
        case .meeting: kind = .meeting(fillsDisplay: false, startsHidden: startsHidden)
        case .chat: kind = .chat
        case .view: kind = .view(.gallery, startsHidden: startsHidden)
        case .browser: kind = .app(AppPiece(bundleID: "com.sibhimanyu.greenroom.browser"))
        case .otherApp: kind = .app(AppPiece(bundleID: app ?? chosenApp, opensMinimised: startsHidden))
        case .roomScreen: kind = .roomScreen
        }
        // Compile-time guard: every real kind is named here.
        switch kind { case .meeting, .chat, .view, .app, .roomScreen: break }
        return LayoutPiece(kind: kind, rect: .full, showsToEveryone: shown)
    }

    private var targets: [Visibility.Target] {
        [.wholeScreen, .window(bundleID: chosenApp), .window(bundleID: nil), .whiteboard, .justMe]
    }

    /// A pure model of the capture: our own windows are dropped unless excepted
    /// (the real `ShowOnShare.exceptionIDs`), other apps stay on a display share
    /// unless the filter excludes them (`Visibility.hiddenAppIDs`, what the capture
    /// passes to ScreenCaptureKit), only the chosen window is in a window share,
    /// nothing app-like otherwise.
    private func captured(_ p: LayoutPiece, number: Int, target: Visibility.Target) -> Bool {
        let isBrowser: Bool
        let ownWindow: Bool
        switch p.kind {
        case .meeting, .chat, .view: ownWindow = true; isBrowser = false
        case let .app(a): isBrowser = AppCatalogID.isBuiltInBrowser(a.bundleID); ownWindow = isBrowser
        case .roomScreen: return false
        }
        switch target {
        case .whiteboard, .justMe: return false
        case let .window(id):
            if case let .app(a) = p.kind { return a.bundleID == id }
            return false
        case .wholeScreen:
            guard ownWindow else {
                guard case let .app(a) = p.kind else { return true }
                return !Visibility.hiddenAppIDs(pieces: [p], target: target).contains(a.bundleID)
            }
            let registry: Set<Int> = (p.offersShareSwitch && p.showsToEveryone) ? [number] : []
            let always: Set<Int> = isBrowser ? [number] : []
            return ShowOnShare.exceptionIDs(kind: target.shareKind, registry: registry, alwaysShared: always)?.contains(number) ?? false
        }
    }

    func testRuleAgreesWithTheCaptureForEveryKindTargetAndBadgeState() {
        var cases = 0
        for s in Sample.allCases {
            for target in targets {
                for shown in [true, false] {
                    for hidden in [true, false] {
                        let p = piece(s, shown: shown, startsHidden: hidden)
                        let badge = Visibility.everyoneSees(piece: p, target: target)
                        XCTAssertEqual(badge.isOn, captured(p, number: 7, target: target),
                                       "\(s) shown=\(shown) hidden=\(hidden) on \(target)")
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, Sample.allCases.count * targets.count * 4)
    }

    func testTheExceptionListIsTheRulesOwnWindowsOnAWholeScreen() {
        // Two own windows (numbers 1, 2), the browser (3): the list is exactly the ones the rule turns on.
        let pieces = [piece(.meeting, shown: true), piece(.chat, shown: false), piece(.browser, shown: false)]
        let numbers = [1, 2, 3]
        let registry = Set(zip(pieces, numbers).filter { $0.0.offersShareSwitch && $0.0.showsToEveryone }.map { $0.1 })
        let list = ShowOnShare.exceptionIDs(kind: .display, registry: registry, alwaysShared: [3]) ?? []
        let ruleSays = Set(zip(pieces, numbers).filter { Visibility.everyoneSees(piece: $0.0, target: .wholeScreen).isOn }.map { $0.1 })
        XCTAssertEqual(list, ruleSays)
        XCTAssertEqual(list, [1, 3])
    }

    func testFixedBadgesCarryAReasonAndSwitchesDoNot() {
        for s in Sample.allCases {
            for target in targets {
                let b = Visibility.everyoneSees(piece: piece(s, shown: true), target: target)
                switch b {
                case let .fixedOn(r), let .fixedOff(r): XCTAssertFalse(r.isEmpty); XCTAssertTrue(b.isFixed)
                case .on, .off: XCTAssertFalse(b.isFixed)
                }
            }
        }
    }

    func testTheBrowserIsAlwaysEveryoneOnAWholeScreen() {
        for shown in [true, false] {
            guard case .fixedOn = Visibility.everyoneSees(piece: piece(.browser, shown: shown), target: .wholeScreen)
            else { return XCTFail("browser must be fixed on") }
        }
        // Another app is not fixed: its own switch decides.
        XCTAssertTrue(Visibility.everyoneSees(piece: piece(.otherApp, shown: true), target: .wholeScreen).isOn)
        XCTAssertFalse(Visibility.everyoneSees(piece: piece(.otherApp, shown: false), target: .wholeScreen).isOn)
    }

    func testTheFilterExcludesExactlyTheAppsWhoseBadgeIsOffOnAWholeScreen() {
        let off = piece(.otherApp, shown: false, app: "com.example.off")
        let on = piece(.otherApp, shown: true, app: "com.example.on")
        let browser = piece(.browser, shown: false)
        let chat = piece(.chat, shown: false)
        XCTAssertEqual(Visibility.hiddenAppIDs(pieces: [off, on, browser, chat], target: .wholeScreen), ["com.example.off"])
        // Other targets have no display filter to put an app in.
        for t in targets where t != .wholeScreen {
            XCTAssertTrue(Visibility.hiddenAppIDs(pieces: [off], target: t).isEmpty, "\(t)")
        }
        // Two pieces of one app: it leaves only when every one of them is off.
        let twin = piece(.otherApp, shown: true, app: "com.example.off")
        XCTAssertTrue(Visibility.hiddenAppIDs(pieces: [off, twin], target: .wholeScreen).isEmpty)
    }

    func testTheBrowserCannotBeTakenOutOfThePictureEvenIfSavedOff() {
        XCTAssertTrue(Visibility.hiddenAppIDs(pieces: [piece(.browser, shown: false)], target: .wholeScreen).isEmpty)
    }

    func testOtherAppsOpenMinimisedWhenTheirEyeIsOffAndOnlyThen() {
        XCTAssertEqual(Visibility.onMyScreen(piece: piece(.otherApp, shown: true, startsHidden: true)), .off)
        XCTAssertTrue(Visibility.opensMinimised(piece: piece(.otherApp, shown: true, startsHidden: true)))
        XCTAssertFalse(Visibility.opensMinimised(piece: piece(.otherApp, shown: true, startsHidden: false)))
        // The Greenroom Browser, the chat and views keep their own meaning.
        let browser = LayoutPiece(kind: .app(AppPiece(bundleID: Visibility.builtInBrowserID, opensMinimised: true)), rect: .full)
        XCTAssertTrue(Visibility.onMyScreen(piece: browser).isFixed)
        XCTAssertFalse(Visibility.opensMinimised(piece: browser))
        XCTAssertFalse(Visibility.opensMinimised(piece: piece(.meeting, shown: true, startsHidden: true)))
    }

    func testTheAppBadgeAndMinimisedStateSurviveSavingAndOldFilesDefault() throws {
        let old = #"{"bundleID":"com.example.keynote"}"#.data(using: .utf8)!
        XCTAssertFalse(try JSONDecoder().decode(AppPiece.self, from: old).opensMinimised)
        let oldPiece = try JSONEncoder().encode(LayoutPiece(kind: .app(AppPiece(bundleID: "x")), rect: .full))
        var json = try JSONSerialization.jsonObject(with: oldPiece) as! [String: Any]
        json.removeValue(forKey: "showsToEveryone")
        let decoded = try JSONDecoder().decode(LayoutPiece.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.showsToEveryone, "an old file's app is in everyone's picture")
        let p = LayoutPiece(kind: .app(AppPiece(bundleID: "x", opensMinimised: true)), rect: .full, showsToEveryone: false)
        let back = try JSONDecoder().decode(LayoutPiece.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.kind.app?.opensMinimised, true)
        XCTAssertFalse(back.showsToEveryone)
    }

    func testOnlyOwnWindowsOnAWholeScreenCanBeFlipped() {
        for s in Sample.allCases {
            for target in targets {
                let flippable = !Visibility.everyoneSees(piece: piece(s, shown: true), target: target).isFixed
                let expected: Bool
                if case .wholeScreen = target { expected = [.meeting, .chat, .view, .otherApp].contains(s) } else { expected = false }
                XCTAssertEqual(flippable, expected, "\(s) on \(target)")
            }
        }
    }

    func testOnMyScreenFollowsStartsHiddenAndNothingElse() {
        XCTAssertEqual(Visibility.onMyScreen(piece: piece(.meeting, shown: true, startsHidden: true)), .off)
        XCTAssertEqual(Visibility.onMyScreen(piece: piece(.view, shown: true, startsHidden: false)), .on)
        XCTAssertTrue(Visibility.onMyScreen(piece: piece(.chat, shown: true)).isFixed)
        XCTAssertTrue(Visibility.onMyScreen(piece: piece(.otherApp, shown: true)).isOn)
        XCTAssertFalse(Visibility.onMyScreen(piece: piece(.otherApp, shown: true)).isFixed)
        XCTAssertTrue(Visibility.onMyScreen(piece: piece(.roomScreen, shown: true)).isOn)
    }

    // R6.1, R1: Off and Only me hide the camera from everyone on every share; Just my camera
    // (share Nothing) is the one exception, the camera is then the whole picture.
    func testTheCameraAcrossTheFourStatesAndEveryTarget() {
        for (noCamera, mine, state) in [(false, true, CameraState.everyoneAndMe), (false, false, .onlyEveryone),
                                        (true, true, .onlyMe), (true, false, .off)] {
            XCTAssertEqual(CameraState(noCamera: noCamera, shownOnMyScreen: mine), state)
            XCTAssertEqual(Visibility.cameraOnMyScreen(state: state).isOn, mine)
            for target in targets {
                let expected = target == .justMe ? true : !noCamera
                XCTAssertEqual(Visibility.cameraEveryoneSees(state: state, target: target).isOn, expected, "\(state) \(target)")
            }
        }
    }

    // MARK: Flipping a badge (R2.3)

    private enum Eye { case on, off }
    private func eye(_ p: LayoutPiece) -> Bool { Visibility.onMyScreen(piece: p).isOn }

    // R2.3: a window can't be everyone-but-not-me, so 📡 on brings 👁 on.
    func testTurningBroadcastOnTurnsTheEyeOn() {
        for s in [Sample.meeting, .view, .otherApp] {
            let hiddenAndOff = piece(s, shown: false, startsHidden: true)
            XCTAssertFalse(eye(hiddenAndOff))
            let flipped = Visibility.flipped(hiddenAndOff, side: .everyone)
            XCTAssertTrue(flipped.showsToEveryone, "\(s)")
            XCTAssertTrue(eye(flipped), "\(s): 👁 follows 📡 on")
        }
    }

    // R2.3: the other direction, as before: 👁 off takes the window out of the picture.
    func testTurningTheEyeOffTurnsBroadcastOffForOwnWindows() {
        for s in [Sample.meeting, .view] {
            let shown = piece(s, shown: true, startsHidden: false)
            let flipped = Visibility.flipped(shown, side: .me)
            XCTAssertFalse(eye(flipped))
            XCTAssertFalse(flipped.showsToEveryone, "\(s)")
            // Turning the eye back on leaves 📡 where it is.
            let back = Visibility.flipped(flipped, side: .me)
            XCTAssertTrue(eye(back))
            XCTAssertFalse(back.showsToEveryone)
        }
    }

    // R2.1, R2.2: a badge that can't change is not flipped (Chat's eye, the browser, the Room screen).
    func testFixedBadgesDoNotFlip() {
        for p in [piece(.chat, shown: true), piece(.browser, shown: true), piece(.roomScreen, shown: false)] {
            XCTAssertEqual(Visibility.flipped(p, side: .me), p)
        }
        let browser = piece(.browser, shown: true)
        XCTAssertEqual(Visibility.flipped(browser, side: .everyone), browser)
    }

    func testBroadcastFlipsBackOffForChat() {
        let chat = piece(.chat, shown: true)
        XCTAssertFalse(Visibility.flipped(chat, side: .everyone).showsToEveryone)
    }

    // MARK: The cross-check compares like with like

    // R1.3: the DEBUG cross-check asks the rule about the share the capture really has,
    // so a layout that says "whole screen" while nothing is captured raises no alarm.
    func testCrossCheckUsesTheCapturesOwnKind() {
        XCTAssertEqual(Visibility.Target(captureKind: .display), .wholeScreen)
        XCTAssertEqual(Visibility.Target(captureKind: .window), .window(bundleID: nil))
        XCTAssertEqual(Visibility.Target(captureKind: .app), .window(bundleID: nil))
        XCTAssertEqual(Visibility.Target(captureKind: .other), .justMe)
        let browser = piece(.browser, shown: true)
        let target = Visibility.Target(captureKind: .other)
        XCTAssertTrue(Visibility.mismatches(windows: [(browser, 3)], target: target, exceptionList: []).isEmpty)
    }

    func testCrossCheckFlagsAFixedWindowTheListDisagreesWith() {
        let browser = piece(.browser, shown: true)
        let chat = piece(.chat, shown: true)
        // Browser in the list, chat (switchable) not: agreement is only demanded of fixed badges.
        XCTAssertTrue(Visibility.mismatches(windows: [(browser, 3), (chat, 4)], target: .wholeScreen, exceptionList: [3]).isEmpty)
        XCTAssertEqual(Visibility.mismatches(windows: [(browser, 3)], target: .wholeScreen, exceptionList: []), [browser.id])
        XCTAssertEqual(Visibility.mismatches(windows: [(browser, 3)], target: .whiteboard, exceptionList: [3]), [browser.id])
    }
}

private enum AppCatalogID {
    static func isBuiltInBrowser(_ id: String) -> Bool { id == "com.sibhimanyu.greenroom.browser" }
}
