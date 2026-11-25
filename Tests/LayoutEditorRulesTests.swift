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
                       [.automatic, .display("a"), .display("b"), .remove])
    }

    func testSecondMenuKeepsAnUnpluggedSavedDisplay() {
        XCTAssertEqual(LayoutEditorRules.secondMenu(connectedNonMainIDs: ["a"], savedUUID: "gone"),
                       [.automatic, .display("a"), .savedNotConnected("gone"), .remove])
        XCTAssertEqual(LayoutEditorRules.secondMenu(connectedNonMainIDs: ["a"], savedUUID: "a"),
                       [.automatic, .display("a"), .remove])
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

    func testPlusAddsToItsOwnCanvas() {
        for slot in [LayoutSlot.one, .main, .second] { XCTAssertEqual(LayoutEditorRules.addSlot(canvas: slot), slot) }
    }

    func testInspectorFollowsTheSelection() {
        let cam = UUID(), a = UUID(), gone = UUID()
        func ins(_ s: UUID?, camera: Bool = true) -> LayoutEditorRules.Inspector {
            LayoutEditorRules.inspector(selection: s, cameraID: cam, hasCamera: camera, pieceIDs: [a])
        }
        XCTAssertEqual(ins(nil), .empty)
        XCTAssertEqual(ins(cam), .camera)
        XCTAssertEqual(ins(cam, camera: false), .empty)
        XCTAssertEqual(ins(a), .piece(a))
        XCTAssertEqual(ins(gone), .empty)
    }

    func testDescriptionLivesInTheEmptyInspector() {
        XCTAssertTrue(LayoutEditorRules.inspectorShowsDescription(.empty))
        XCTAssertFalse(LayoutEditorRules.inspectorShowsDescription(.camera))
        XCTAssertFalse(LayoutEditorRules.captionUnderCards(hasActiveLayout: true))
        XCTAssertTrue(LayoutEditorRules.captionUnderCards(hasActiveLayout: false))
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
}
