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
        case .otherApp: kind = .app(AppPiece(bundleID: app ?? chosenApp))
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
    /// (the real `ShowOnShare.exceptionIDs`), other apps stay on a display share,
    /// only the chosen window is in a window share, nothing app-like otherwise.
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
            guard ownWindow else { return true }
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
        XCTAssertTrue(Visibility.everyoneSees(piece: piece(.otherApp, shown: false), target: .wholeScreen).isOn)
    }

    func testOnlyOwnWindowsOnAWholeScreenCanBeFlipped() {
        for s in Sample.allCases {
            for target in targets {
                let flippable = !Visibility.everyoneSees(piece: piece(s, shown: true), target: target).isFixed
                let expected: Bool
                if case .wholeScreen = target { expected = [.meeting, .chat, .view].contains(s) } else { expected = false }
                XCTAssertEqual(flippable, expected, "\(s) on \(target)")
            }
        }
    }

    func testOnMyScreenFollowsStartsHiddenAndNothingElse() {
        XCTAssertEqual(Visibility.onMyScreen(piece: piece(.meeting, shown: true, startsHidden: true)), .off)
        XCTAssertEqual(Visibility.onMyScreen(piece: piece(.view, shown: true, startsHidden: false)), .on)
        XCTAssertTrue(Visibility.onMyScreen(piece: piece(.chat, shown: true)).isFixed)
        XCTAssertTrue(Visibility.onMyScreen(piece: piece(.otherApp, shown: true)).isOn)
        XCTAssertTrue(Visibility.onMyScreen(piece: piece(.roomScreen, shown: true)).isOn)
    }

    func testTheCameraAcrossTheFourStatesAndEveryTarget() {
        for (noCamera, mine, state) in [(false, true, CameraState.everyoneAndMe), (false, false, .onlyEveryone),
                                        (true, true, .onlyMe), (true, false, .off)] {
            XCTAssertEqual(CameraState(noCamera: noCamera, shownOnMyScreen: mine), state)
            XCTAssertEqual(Visibility.cameraOnMyScreen(state: state).isOn, mine)
            for target in targets {
                XCTAssertEqual(Visibility.cameraEveryoneSees(state: state, target: target).isOn, !noCamera, "\(state) \(target)")
            }
        }
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
