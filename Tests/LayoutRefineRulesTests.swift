import XCTest

/// R32 to R36 (docs/specs/layouts-builder.md): the share pop-out, canvas honesty, the simple inspectors,
/// and Home's share hint.
final class SharePopoutRulesTests: XCTestCase {
    private func sections(_ c: SharePopoutContext, _ kind: ShareTarget.Kind = .display, displays: Int = 1,
                          two: Bool = false, browsing: Bool = false, gone: Bool = false, perm: Bool = false) -> [SharePopoutRules.Section] {
        SharePopoutRules.sections(context: c, kind: kind, displayCount: displays, hasTwoDisplays: two,
                                  browsingWindows: browsing, gone: gone, permissionMissing: perm)
    }

    // R32.2
    func testTheHeaderSaysWhichContext() {
        XCTAssertEqual(SharePopoutRules.title(.thisMeeting), "Screen \u{00B7} this meeting")
        XCTAssertEqual(SharePopoutRules.title(.atStart), "Screen \u{00B7} at start")
    }

    // R32.3
    func testSharedDisplayOnlyAtStartWithTwoDisplays() {
        XCTAssertEqual(sections(.atStart, two: true), [.share, .sharedDisplay])
        XCTAssertEqual(sections(.atStart, two: false), [.share])
        XCTAssertFalse(sections(.thisMeeting, displays: 2, two: true).contains(.sharedDisplay))
    }

    // R32.3
    func testAtStartHasNothingLive() {
        let s = sections(.atStart, .display, displays: 3, two: true, gone: true, perm: true)
        XCTAssertFalse(s.contains(.displays)); XCTAssertFalse(s.contains(.gone)); XCTAssertFalse(s.contains(.permission))
        let live = sections(.thisMeeting, .display, displays: 3, gone: true, perm: true)
        XCTAssertEqual(live, [.share, .gone, .permission, .displays])
    }

    // R32.3
    func testWindowsAndFollowForOneWindow() {
        XCTAssertEqual(sections(.atStart, .window, two: true), [.share, .sharedDisplay, .windows, .follow])
        XCTAssertEqual(sections(.atStart, .display, two: false, browsing: true), [.share, .windows])
        XCTAssertEqual(sections(.thisMeeting, .window), [.share, .windows, .follow])
    }

    // R32.4
    func testTilesSetTheKindAndKeepTheRest() {
        var s = ShareTarget(); s.kind = .window; s.appBundleID = "a.b"; s.appName = "Notes"; s.followsSlideShow = false
        for (tile, kind) in [(ScreenPanelRules.Tile.screen, ShareTarget.Kind.display), (.whiteboard, .whiteboard), (.camera, .nothing)] {
            let out = SharePopoutRules.applying(tile, to: s)
            XCTAssertEqual(out?.kind, kind)
            XCTAssertEqual(out?.appBundleID, "a.b"); XCTAssertEqual(out?.followsSlideShow, false)
        }
        XCTAssertNil(SharePopoutRules.applying(.window, to: s), "a window tile waits for a pick")
    }

    // R32.4
    func testPickingAWindowSetsItAndKeepsFollow() {
        var s = ShareTarget(); s.followsSlideShow = false
        let out = SharePopoutRules.picking(bundleID: "com.apple.Notes", appName: "Notes", title: "Todo", in: s)
        XCTAssertEqual(out.kind, .window); XCTAssertEqual(out.appBundleID, "com.apple.Notes")
        XCTAssertEqual(out.appName, "Notes"); XCTAssertEqual(out.windowTitle, "Todo"); XCTAssertFalse(out.followsSlideShow)
    }

    // R32.4
    func testAnOldOneAppReadsBackAsTheWholeScreen() {
        var s = ShareTarget(); s.kind = .app
        XCTAssertEqual(SharePopoutRules.readBack(s).kind, .display)
        s.kind = .window
        XCTAssertEqual(SharePopoutRules.readBack(s).kind, .window)
    }

    // R32.5
    func testAtStartAnAppRowIsChosenByItsBundleID() {
        var s = ShareTarget(); s.kind = .window; s.appBundleID = "a.b"
        XCTAssertTrue(SharePopoutRules.isChosen(bundleID: "a.b", title: "", in: s))
        XCTAssertFalse(SharePopoutRules.isChosen(bundleID: "c.d", title: "", in: s))
        s.kind = .display
        XCTAssertFalse(SharePopoutRules.isChosen(bundleID: "a.b", title: "", in: s))
        XCTAssertFalse(SharePopoutRules.groupsByApp(.atStart))
        XCTAssertTrue(SharePopoutRules.groupsByApp(.thisMeeting))
    }
}

final class CanvasShareRulesTests: XCTestCase {
    private func app(_ id: String) -> LayoutPiece { LayoutPiece(kind: .app(AppPiece(bundleID: id)), rect: .full) }
    private let chat = LayoutPiece(kind: .chat, rect: .full)

    // R34.1
    func testOneWindowTagsTheChosenAndFadesTheRest() {
        let t = Visibility.Target.window(bundleID: "a")
        XCTAssertEqual(CanvasShareRules.mark(piece: app("a"), target: t), .shared)
        XCTAssertEqual(CanvasShareRules.mark(piece: app("b"), target: t), .notShared)
        XCTAssertEqual(CanvasShareRules.mark(piece: chat, target: t), .notShared)
        XCTAssertFalse(CanvasShareRules.fades(piece: app("a"), target: t))
        XCTAssertTrue(CanvasShareRules.fades(piece: app("b"), target: t))
        XCTAssertTrue(CanvasShareRules.fades(piece: chat, target: t))
    }

    // R34.1: no window chosen yet, so nothing is the shared one
    func testOneWindowNotChosenTagsNothing() {
        let t = Visibility.Target.window(bundleID: nil)
        XCTAssertEqual(CanvasShareRules.mark(piece: app("a"), target: t), .notShared)
    }

    // R34.2
    func testWhiteboardAndJustMeFadeEveryWindow() {
        for t in [Visibility.Target.whiteboard, .justMe] {
            for p in [app("a"), chat, LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false), rect: .full)] {
                XCTAssertEqual(CanvasShareRules.mark(piece: p, target: t), .notShared)
                XCTAssertTrue(CanvasShareRules.fades(piece: p, target: t))
            }
        }
    }

    // R34.3
    func testWholeScreenHasNoTagAndNoHint() {
        XCTAssertEqual(CanvasShareRules.mark(piece: app("a"), target: .wholeScreen), .none)
        XCTAssertEqual(CanvasShareRules.mark(piece: chat, target: .wholeScreen), .none)
        XCTAssertFalse(CanvasShareRules.fades(piece: chat, target: .wholeScreen))
    }

    // R34.5
    func testTheWordsAndIcons() {
        XCTAssertEqual(CanvasShareRules.sharedWords, "Shared")
        XCTAssertEqual(CanvasShareRules.notSharedWords, "Not shared")
        XCTAssertEqual(CanvasShareRules.icon(.shared), VisibilitySymbol.everyoneSees(true))
        XCTAssertEqual(CanvasShareRules.icon(.notShared), VisibilitySymbol.everyoneSees(false))
        XCTAssertNil(CanvasShareRules.icon(.none))
    }
}

final class PieceInspectorRulesTests: XCTestCase {
    private let browser = AppPiece(bundleID: Visibility.builtInBrowserID)
    private let safari = AppPiece(bundleID: "com.apple.Safari")

    private func kinds() -> [LayoutPiece.Kind] {
        [.chat, .roomScreen, .meeting(fillsDisplay: false, startsHidden: false), .meeting(fillsDisplay: true, startsHidden: true),
         .view(.gallery, startsHidden: false), .app(browser), .app(safari)]
    }

    // R35.1
    func testNoKindHasMoreThanTwoRowsAtRest() {
        XCTAssertEqual(PieceInspectorRules.maxRowsAtRest, 2)
        for kind in kinds() { for slot in LayoutSlot.allCases {
            XCTAssertLessThanOrEqual(PieceInspectorRules.rows(for: kind, slot: slot).count, 2, "\(kind) \(slot)")
        } }
        XCTAssertLessThanOrEqual(PieceInspectorRules.cameraRows.count, 2)
    }

    // R35.2
    func testTheRowsOfEachKind() {
        XCTAssertEqual(PieceInspectorRules.cameraRows, [.whoSees, .shapeAndSize])
        XCTAssertEqual(PieceInspectorRules.rows(for: .chat, slot: .main), [])
        XCTAssertEqual(PieceInspectorRules.rows(for: .roomScreen, slot: .second), [])
        let meeting = LayoutPiece.Kind.meeting(fillsDisplay: false, startsHidden: false)
        XCTAssertEqual(PieceInspectorRules.rows(for: meeting, slot: .main), [.startsHidden])
        XCTAssertEqual(PieceInspectorRules.rows(for: meeting, slot: .second), [.fillDisplay, .startsHidden])
        XCTAssertEqual(PieceInspectorRules.rows(for: .view(.gallery, startsHidden: false), slot: .main), [.startsHidden])
        XCTAssertEqual(PieceInspectorRules.rows(for: .app(safari), slot: .main), [.app, .opensAtStart])
    }

    // R35.3
    func testSecondaryActionsLiveInTheMenuAndRemoveIsLast() {
        for kind in kinds() { XCTAssertEqual(PieceInspectorRules.menu(for: kind).last, .remove) }
        XCTAssertEqual(PieceInspectorRules.menu(for: .app(safari)), [.closesOnStop, .opensMinimised, .remove])
        XCTAssertEqual(PieceInspectorRules.menu(for: .app(browser)), [.closesOnStop, .reopenLastTabs, .searchSuggestions, .remove])
        XCTAssertEqual(PieceInspectorRules.menu(for: .chat), [.remove])
    }

    // R35.4
    func testHintsAreTooltipsAndTheReadoutIsOneValue() {
        for kind in kinds() { XCTAssertFalse(PieceInspectorRules.tooltip(for: kind).isEmpty, "\(kind)") }
        XCTAssertEqual(PieceInspectorRules.readout(points: (w: 790, h: 460)), "790\u{00D7}460")
        XCTAssertEqual(PieceInspectorRules.readoutHelp(columns: 7...12, rows: 1...5, points: (w: 790, h: 460)),
                       "Columns 7\u{2013}12, rows 1\u{2013}5, 790\u{00D7}460 points")
    }

    // R35.5
    func testTheFourCameraStatesAreFourIcons() {
        XCTAssertEqual(PieceInspectorRules.cameraChoices.count, 4)
        XCTAssertEqual(PieceInspectorRules.cameraChoices, CameraState.allCases)
        XCTAssertEqual(PieceInspectorRules.cameraTip(.onlyMe), "Only me: " + CameraState.onlyMe.detail)
    }
}

final class ShareHintRulesTests: XCTestCase {
    // R36.1
    func testTheHintPerShare() {
        XCTAssertNil(ShareHintRules.hint(kind: .display, appName: ""))
        XCTAssertEqual(ShareHintRules.hint(kind: .nothing, appName: ""), "Arranges your screen. The meeting sees just you.")
        XCTAssertEqual(ShareHintRules.hint(kind: .whiteboard, appName: ""), "Arranges your screen. The meeting sees the whiteboard.")
        XCTAssertEqual(ShareHintRules.hint(kind: .window, appName: "Keynote"), "Arranges your screen. The meeting sees Keynote.")
        XCTAssertEqual(ShareHintRules.hint(kind: .window, appName: ""), "Arranges your screen. The meeting sees one window.")
        XCTAssertNil(ShareHintRules.hint(kind: .app, appName: "X"), "a saved One app reads as the whole screen")
    }

    // R36.2
    func testTheFooterShowsOneNoteRoomThenHintThenSecondDisplay() {
        XCTAssertEqual(ShareHintRules.footerNote(room: "R", hint: "H", secondDisplay: "S"), .room("R"))
        XCTAssertEqual(ShareHintRules.footerNote(room: nil, hint: "H", secondDisplay: "S"), .hint("H"))
        XCTAssertEqual(ShareHintRules.footerNote(room: nil, hint: nil, secondDisplay: "S"), .secondDisplay("S"))
        XCTAssertNil(ShareHintRules.footerNote(room: nil, hint: nil, secondDisplay: nil))
    }

    // R36.3
    func testTheTileLabelsAreTheShortNames() {
        XCTAssertEqual(ShareHintRules.tileLabel(kind: .display, appName: ""), "Whole screen")
        XCTAssertEqual(ShareHintRules.tileLabel(kind: .app, appName: "X"), "Whole screen")
        XCTAssertEqual(ShareHintRules.tileLabel(kind: .whiteboard, appName: ""), "Whiteboard")
        XCTAssertEqual(ShareHintRules.tileLabel(kind: .nothing, appName: ""), "Just me")
        XCTAssertEqual(ShareHintRules.tileLabel(kind: .window, appName: ""), "A window")
        XCTAssertEqual(ShareHintRules.tileLabel(kind: .window, appName: "Notes"), "Notes")
    }

    // R36.3
    func testALongAppNameIsCutCleanlyAtTheEnd() {
        let label = ShareHintRules.tileLabel(kind: .window, appName: "Google Chrome Canary")
        XCTAssertEqual(label.count, ShareHintRules.maxTileChars)
        XCTAssertTrue(label.hasSuffix("\u{2026}")); XCTAssertTrue(label.hasPrefix("Google"))
        for k in [ShareTarget.Kind.display, .whiteboard, .nothing, .window] {
            XCTAssertLessThanOrEqual(ShareHintRules.tileLabel(kind: k, appName: "").count, ShareHintRules.maxTileChars)
        }
    }
}
