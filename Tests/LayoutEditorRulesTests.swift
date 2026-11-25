import XCTest

/// The Layouts editor's chrome: which menu holds what, which canvas carries
/// which control, what the inspector shows.
final class LayoutEditorRulesTests: XCTestCase {
    private func template(two: Bool, shared: LayoutSlot = .main) -> LayoutTemplate {
        var t = LayoutTemplate(name: "T")
        if two { t.twoDisplays = TwoDisplay(sharedSlot: shared) }
        return t
    }

    func testLayoutMenuIsRenameDuplicateDeleteForYourOwn() {
        XCTAssertEqual(LayoutEditorRules.layoutMenu(isBuiltIn: false, canRestore: true), [.rename, .duplicate, .delete])
    }

    func testRestoreOriginalOnlyForARestorableBuiltIn() {
        XCTAssertEqual(LayoutEditorRules.layoutMenu(isBuiltIn: true, canRestore: true),
                       [.rename, .duplicate, .restoreOriginal, .delete])
        XCTAssertEqual(LayoutEditorRules.layoutMenu(isBuiltIn: true, canRestore: false), [.rename, .duplicate, .delete])
    }

    func testGhostSecondCanvasOnlyWithoutATwoDisplayVersion() {
        XCTAssertTrue(LayoutEditorRules.showsGhostSecondCanvas(hasTwoDisplays: false))
        XCTAssertFalse(LayoutEditorRules.showsGhostSecondCanvas(hasTwoDisplays: true))
    }

    func testSecondMenuHasAutomaticDisplaysThenRemove() {
        XCTAssertEqual(LayoutEditorRules.secondMenu(connectedNonMainIDs: ["a", "b"], savedUUID: ""),
                       [.automatic, .display("a"), .display("b")])
    }

    func testSecondMenuKeepsAnUnpluggedSavedDisplay() {
        XCTAssertEqual(LayoutEditorRules.secondMenu(connectedNonMainIDs: ["a"], savedUUID: "gone"),
                       [.automatic, .display("a"), .savedNotConnected("gone")])
        XCTAssertEqual(LayoutEditorRules.secondMenu(connectedNonMainIDs: ["a"], savedUUID: "a"),
                       [.automatic, .display("a")])
    }

    func testSharedControlsSitOnTheOneCanvas() {
        XCTAssertTrue(LayoutEditorRules.carriesSharedControls(slot: .one, template: template(two: false)))
        // Viewing the one-display version of a layout that also has two displays.
        XCTAssertTrue(LayoutEditorRules.carriesSharedControls(slot: .one, template: template(two: true)))
    }

    func testSharedControlsFollowTheSharedDisplay() {
        let main = template(two: true, shared: .main)
        XCTAssertTrue(LayoutEditorRules.carriesSharedControls(slot: .main, template: main))
        XCTAssertFalse(LayoutEditorRules.carriesSharedControls(slot: .second, template: main))
        let second = template(two: true, shared: .second)
        XCTAssertTrue(LayoutEditorRules.carriesSharedControls(slot: .second, template: second))
        XCTAssertFalse(LayoutEditorRules.carriesSharedControls(slot: .main, template: second))
    }

    func testExactlyOneCanvasCarriesTheSharedControls() {
        for two in [false, true] {
            let t = template(two: two)
            let slots: [LayoutSlot] = two ? [.main, .second] : [.one]
            XCTAssertEqual(slots.filter { LayoutEditorRules.carriesSharedControls(slot: $0, template: t) }.count, 1)
        }
        let shown = template(two: true, shared: .second)
        XCTAssertEqual([LayoutSlot.main, .second].filter { LayoutEditorRules.carriesSharedControls(slot: $0, template: shown) }, [.second])
    }

    func testSharedMenuRowsFoldAway() {
        XCTAssertEqual(LayoutEditorRules.sharedMenu(hasTwoDisplays: false, kind: .display), [.whatsShared])
        XCTAssertEqual(LayoutEditorRules.sharedMenu(hasTwoDisplays: true, kind: .nothing), [.sharedDisplay, .whatsShared])
        XCTAssertEqual(LayoutEditorRules.sharedMenu(hasTwoDisplays: true, kind: .window),
                       [.sharedDisplay, .whatsShared, .windowApp, .followSlideShow])
    }

    // R9 (editor): the description lives in the empty inspector (the view decides that by selection).
    func testTheCaptionUnderCardsOnlyWithNoLayout() {
        XCTAssertFalse(LayoutEditorRules.captionUnderCards(hasActiveLayout: true))
        XCTAssertTrue(LayoutEditorRules.captionUnderCards(hasActiveLayout: false))
    }

    // MARK: Captions and the camera (render review, 2026-11-25)

    // R8.1: a piece's caption goes where the camera is not.
    func testACaptionMovesToTheLargestPartTheCameraDoesNotCover() {
        let tile = CGRect(x: 0, y: 0, width: 360, height: 510)
        XCTAssertEqual(LayoutCaptionRules.freeRegion(tile: tile, covered: nil), tile)
        XCTAssertEqual(LayoutCaptionRules.freeRegion(tile: tile, covered: CGRect(x: 500, y: 0, width: 50, height: 50)), tile)
        let bottomRight = CGRect(x: 250, y: 400, width: 100, height: 100)
        let free = LayoutCaptionRules.freeRegion(tile: tile, covered: bottomRight)
        XCTAssertEqual(free, CGRect(x: 0, y: 0, width: 360, height: 400), "above the camera")
        XCTAssertFalse(free.intersects(bottomRight))
        let topLeft = CGRect(x: 0, y: 0, width: 300, height: 100)
        XCTAssertEqual(LayoutCaptionRules.freeRegion(tile: tile, covered: topLeft), CGRect(x: 0, y: 100, width: 360, height: 410))
    }

    func testKeyboardHelpMentionsSendOnlyWithTwoDisplays() {
        XCTAssertFalse(LayoutEditorRules.keyboardHelp(twoDisplays: false).contains("\u{2325}"))
        XCTAssertTrue(LayoutEditorRules.keyboardHelp(twoDisplays: true).contains("other display"))
    }

    func testShowOnScreenAndApplyNow() {
        XCTAssertFalse(LayoutEditorRules.canShowOnScreen(pieceCount: 0))
        XCTAssertTrue(LayoutEditorRules.canShowOnScreen(pieceCount: 1))
        let me = UUID()
        XCTAssertFalse(LayoutEditorRules.offersApplyNow(liveLayoutID: nil, templateID: me))
        XCTAssertFalse(LayoutEditorRules.offersApplyNow(liveLayoutID: me, templateID: me))
        XCTAssertTrue(LayoutEditorRules.offersApplyNow(liveLayoutID: UUID(), templateID: me))
    }

    // MARK: Right-click on a piece

    // R9.4
    func testAChatMenuOffersHideFromEveryoneThenRemove() {
        let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: 0.25, h: 0.25))
        XCTAssertEqual(LayoutEditorRules.pieceMenu(piece: chat, target: .wholeScreen, slot: .one, hasOtherDisplay: false),
                       [.hideFromEveryone, .remove])
    }

    // R9.4
    func testTheOtherDisplayRowComesFirstAndNamesWhereItGoes() {
        let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: 0.25, h: 0.25))
        XCTAssertEqual(LayoutEditorRules.pieceMenu(piece: chat, target: .wholeScreen, slot: .main, hasOtherDisplay: true).first,
                       .moveToOtherDisplay(toSecond: true))
        XCTAssertEqual(LayoutEditorRules.pieceMenu(piece: chat, target: .wholeScreen, slot: .second, hasOtherDisplay: true).first,
                       .moveToOtherDisplay(toSecond: false))
    }

    // R9.4
    func testTheEyeRowIsOfferedOnlyWhereItIsASwitch() {
        let meeting = LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false),
                                  rect: UnitRect(x: 0, y: 0, w: 0.5, h: 0.5))
        XCTAssertEqual(LayoutEditorRules.pieceMenu(piece: meeting, target: .wholeScreen, slot: .one, hasOtherDisplay: false),
                       [.hideFromEveryone, .hideOnMyScreen, .remove])
        var hidden = meeting
        hidden.kind = .meeting(fillsDisplay: false, startsHidden: true)
        hidden.showsToEveryone = false
        XCTAssertEqual(LayoutEditorRules.pieceMenu(piece: hidden, target: .wholeScreen, slot: .one, hasOtherDisplay: false),
                       [.showToEveryone, .showOnMyScreen, .remove])
        let browser = LayoutPiece(kind: .app(AppPiece(bundleID: Visibility.builtInBrowserID)),
                                  rect: UnitRect(x: 0, y: 0, w: 0.5, h: 0.5))
        XCTAssertEqual(LayoutEditorRules.pieceMenu(piece: browser, target: .wholeScreen, slot: .one, hasOtherDisplay: false),
                       [.remove])
    }

    // R9.7
    func testAPieceIsSpokenWithItsSizeAndWhoSeesIt() {
        XCTAssertEqual(LayoutEditorRules.spokenPiece(name: "Chat", columns: 3, everyone: true, onMyScreen: true),
                       "Chat, 3 of 12 columns, everyone sees it")
        XCTAssertEqual(LayoutEditorRules.spokenPiece(name: "Chat", columns: 3, everyone: false, onMyScreen: true),
                       "Chat, 3 of 12 columns, hidden from everyone")
        XCTAssertEqual(LayoutEditorRules.spokenPiece(name: "Chat", columns: 3, everyone: true, onMyScreen: false),
                       "Chat, 3 of 12 columns, everyone sees it, not on your screen")
    }

    // R9.7
    func testACanvasIsSpokenWithItsDisplayAndWhetherEveryoneSeesIt() {
        XCTAssertEqual(LayoutEditorRules.spokenCanvas(name: "Main display", isShared: true), "Main display, everyone sees this")
        XCTAssertEqual(LayoutEditorRules.spokenCanvas(name: "Second display", isShared: false), "Second display")
    }

    // R9.4
    func testMenuRowsUseTheMeetingsWords() {
        typealias R = LayoutEditorRules
        XCTAssertEqual(R.title(for: .moveToOtherDisplay(toSecond: true), isApp: false), "Move to second display")
        XCTAssertEqual(R.title(for: .moveToOtherDisplay(toSecond: false), isApp: false), "Move to main display")
        XCTAssertEqual(R.title(for: .showToEveryone, isApp: false), "Show to everyone")
        XCTAssertEqual(R.title(for: .hideFromEveryone, isApp: false), "Hide from everyone")
        XCTAssertEqual(R.title(for: .showOnMyScreen, isApp: false), "Show on my screen")
        XCTAssertEqual(R.title(for: .hideOnMyScreen, isApp: false), "Hide on my screen")
        XCTAssertEqual(R.title(for: .showOnMyScreen, isApp: true), "Open on my screen")
        XCTAssertEqual(R.title(for: .hideOnMyScreen, isApp: true), "Open minimised")
        XCTAssertEqual(R.title(for: .remove, isApp: false), "Remove")
    }
}
