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

    // R9.7, R17.6: the single-eye words.
    func testAPieceIsSpokenWithItsSizeAndWhoSeesIt() {
        XCTAssertEqual(LayoutEditorRules.spokenPiece(name: "Chat", columns: 3, everyone: true, onMyScreen: true),
                       "Chat, 3 of 12 columns, Everyone sees this")
        XCTAssertEqual(LayoutEditorRules.spokenPiece(name: "Chat", columns: 3, everyone: false, onMyScreen: true),
                       "Chat, 3 of 12 columns, Only you")
        XCTAssertEqual(LayoutEditorRules.spokenPiece(name: "Chat", columns: 3, everyone: true, onMyScreen: false),
                       "Chat, 3 of 12 columns, Everyone sees this, Starts hidden on your screen")
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
        XCTAssertEqual(R.title(for: .showOnMyScreen, isApp: false), "Starts on my screen")
        XCTAssertEqual(R.title(for: .hideOnMyScreen, isApp: false), "Starts hidden on my screen")
        XCTAssertEqual(R.title(for: .showOnMyScreen, isApp: true), "Open on my screen")
        XCTAssertEqual(R.title(for: .hideOnMyScreen, isApp: true), "Open minimised")
        XCTAssertEqual(R.title(for: .remove, isApp: false), "Remove")
    }

    // MARK: After an undo or redo the editor's own state follows the library

    private let cameraID = UUID()
    private func state(two: Bool, slot: LayoutSlot, selection: UUID? = nil) -> LayoutEditorRules.EditorState {
        .init(showsTwo: two, activeSlot: slot, selection: selection)
    }

    // R9.1: undoing "Add Second Display" leaves no two-display version to show.
    func testNoTwoDisplayVersionDropsBackToOneDisplay() {
        let t = template(two: false)
        let r = LayoutEditorRules.reconciled(state(two: true, slot: .main), in: t, cameraID: cameraID)
        XCTAssertEqual(r, state(two: false, slot: .one))
    }

    // R9.1: redoing "Add Second Display" shows one display at a time on a valid canvas.
    func testAShownTwoDisplayVersionNeverHasTheOneDisplaySlotActive() {
        let t = template(two: true)
        XCTAssertEqual(LayoutEditorRules.reconciled(state(two: true, slot: .one), in: t, cameraID: cameraID),
                       state(two: true, slot: .main))
        XCTAssertEqual(LayoutEditorRules.reconciled(state(two: true, slot: .second), in: t, cameraID: cameraID),
                       state(two: true, slot: .second))
        XCTAssertEqual(LayoutEditorRules.reconciled(state(two: false, slot: .main), in: t, cameraID: cameraID),
                       state(two: false, slot: .one))
    }

    // R9.1: a selection whose piece an undo took away is cleared; the camera and live pieces stay.
    func testASelectionThatNoLongerExistsIsCleared() {
        let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: 0.25, h: 0.5))
        var t = template(two: false)
        t.oneDisplay = [chat]
        XCTAssertEqual(LayoutEditorRules.reconciled(state(two: false, slot: .one, selection: chat.id), in: t, cameraID: cameraID).selection, chat.id)
        XCTAssertEqual(LayoutEditorRules.reconciled(state(two: false, slot: .one, selection: cameraID), in: t, cameraID: cameraID).selection, cameraID)
        XCTAssertNil(LayoutEditorRules.reconciled(state(two: false, slot: .one, selection: UUID()), in: t, cameraID: cameraID).selection)
    }

    // R9.1: no active layout, nothing to show.
    func testNoActiveLayoutResetsTheEditor() {
        XCTAssertEqual(LayoutEditorRules.reconciled(state(two: true, slot: .second, selection: UUID()), in: nil, cameraID: cameraID),
                       state(two: false, slot: .one))
    }

    // R9.7: the camera's spoken note follows the camera state, never a fixed "moves for everyone".
    func testTheCameraNoteFollowsTheCameraState() {
        XCTAssertEqual(LayoutEditorRules.cameraMoveNote(everyoneSees: true, onMyScreen: true), "It moves for everyone.")
        XCTAssertEqual(LayoutEditorRules.cameraMoveNote(everyoneSees: true, onMyScreen: false),
                       "It moves for everyone, but is hidden on your screen.")
        XCTAssertEqual(LayoutEditorRules.cameraMoveNote(everyoneSees: false, onMyScreen: true),
                       "Only you see it, so it does not move for everyone.")
        XCTAssertEqual(LayoutEditorRules.cameraMoveNote(everyoneSees: false, onMyScreen: false),
                       "The camera is off, so nobody sees it.")
        for state in CameraState.allCases where state != .everyoneAndMe && state != .onlyEveryone {
            XCTAssertFalse(LayoutEditorRules.cameraMoveNote(everyoneSees: state.everyoneSees, onMyScreen: state.iSee)
                            .contains("moves for everyone."), "\(state)")
        }
    }

    // R9.7, R2.2: the "everyone" and "my screen" actions are offered only where the badge is a switch
    // under this share, as the right-click menu does.
    func testTheBadgeActionsAreOfferedOnlyWhereTheBadgesCanChange() {
        let browser = LayoutPiece(kind: .app(AppPiece(bundleID: Visibility.builtInBrowserID)), rect: chat.rect)
        let safari = LayoutPiece(kind: .app(AppPiece(bundleID: "com.apple.Safari")), rect: chat.rect)
        XCTAssertFalse(LayoutEditorRules.offersEveryoneAction(piece: browser, target: .wholeScreen))
        XCTAssertTrue(LayoutEditorRules.offersEveryoneAction(piece: safari, target: .wholeScreen))
        XCTAssertFalse(LayoutEditorRules.offersEveryoneAction(piece: safari, target: .justMe), "fixed off under Just my camera")
        XCTAssertFalse(LayoutEditorRules.offersEveryoneAction(piece: safari, target: .window(bundleID: "com.apple.Notes")))
        XCTAssertFalse(LayoutEditorRules.offersMyScreenAction(piece: chat), "the Chat is always on your screen")
        XCTAssertTrue(LayoutEditorRules.offersMyScreenAction(piece: safari))
    }

    private var chat: LayoutPiece { LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: 0.25, h: 0.5)) }

    // R11.3: the camera preview runs only while the camera piece is selected or in Preview: Everyone,
    // and never when the Layouts tab is not on screen.
    func testTheCameraPreviewRunsOnlyWhereItIsLooked() {
        typealias R = LayoutEditorRules
        XCTAssertFalse(R.runsCameraPreview(cameraSelected: false, previewEveryone: false, tabShown: true))
        XCTAssertTrue(R.runsCameraPreview(cameraSelected: true, previewEveryone: false, tabShown: true))
        XCTAssertTrue(R.runsCameraPreview(cameraSelected: false, previewEveryone: true, tabShown: true))
        XCTAssertFalse(R.runsCameraPreview(cameraSelected: true, previewEveryone: true, tabShown: false))
    }
}

/// A Meeting window that fills its display is an ordinary piece the owner can resize.
final class LayoutFillDisplayTests: XCTestCase {
    private let filling = LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: true), rect: .full)
    private let smaller = UnitRect(x: 0.1, y: 0.1, w: 0.6, h: 0.6)

    // Owner request: resizing a filling piece turns fill off and keeps the rest.
    func testResizingAFillingMeetingTurnsFillOffAtTheNewRect() {
        let r = LayoutEditorRules.adjusting(filling, to: smaller)
        XCTAssertEqual(r.rect, smaller)
        XCTAssertEqual(r.kind, .meeting(fillsDisplay: false, startsHidden: true))
        XCTAssertEqual(r.id, filling.id)
    }

    // A drag that ends where it began changes nothing.
    func testAnUnchangedRectKeepsFill() {
        XCTAssertEqual(LayoutEditorRules.adjusting(filling, to: .full), filling)
    }

    func testOtherPiecesJustTakeTheRect() {
        let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: 0.2, h: 0.2))
        XCTAssertEqual(LayoutEditorRules.adjusting(chat, to: smaller).rect, smaller)
        XCTAssertEqual(LayoutEditorRules.adjusting(chat, to: smaller).kind, .chat)
    }

    // The toggle: on fills the display, off keeps the rect.
    func testTheFillToggle() {
        var p = LayoutEditorRules.adjusting(filling, to: smaller)
        p = LayoutEditorRules.settingFill(p, on: true)
        XCTAssertEqual(p.rect, .full)
        XCTAssertEqual(p.kind, .meeting(fillsDisplay: true, startsHidden: true))
        let off = LayoutEditorRules.settingFill(p, on: false)
        XCTAssertEqual(off.kind, .meeting(fillsDisplay: false, startsHidden: true))
        XCTAssertEqual(off.rect, .full)
    }

    func testTheHintSaysWhatTurningFillOffChanges() {
        XCTAssertTrue(LayoutEditorRules.fillHint(othersOnDisplay: false).contains("people"))
        XCTAssertTrue(LayoutEditorRules.fillHint(othersOnDisplay: true).contains("Remove the other pieces"))
    }

    // One undo step named "Resize Meeting window"; undo puts back rect and fill.
    func testResizeIsOneNamedUndoStepAndUndoRestoresBoth() {
        let t = LayoutTemplate(name: "T", oneDisplay: [filling])
        let old = LayoutLibrary(templates: [t], activeID: t.id)
        var new = old
        new.templates[0].oneDisplay[0] = LayoutEditorRules.adjusting(filling, to: smaller)
        let step = LayoutEditHistory.describe(from: old, to: new) { _ in "Meeting window" }
        XCTAssertEqual(step?.name, "Resize Meeting window")
        let back = LayoutEditHistory.restoring(old, undoing: new, onto: new)
        XCTAssertEqual(back.templates[0].oneDisplay[0].rect, .full)
        XCTAssertEqual(back.templates[0].oneDisplay[0].kind, .meeting(fillsDisplay: true, startsHidden: true))
    }

    // The fade on My screen is only a look: every piece stays editable, seen by everyone or not,
    // on a connected display or on one that is not plugged in yet. Preview: Everyone is the
    // read-only picture of what the meeting sees.
    func testMyScreenPiecesAreAlwaysInteractive() {
        XCTAssertTrue(LayoutEditorRules.piecesAreInteractive(previewEveryone: false))
    }

    func testPreviewEveryoneIsReadOnly() {
        XCTAssertFalse(LayoutEditorRules.piecesAreInteractive(previewEveryone: true))
    }
}
