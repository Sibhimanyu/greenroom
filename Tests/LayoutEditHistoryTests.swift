import XCTest

/// Undo in the Layouts editor: names, grouping, and what an undo restores.
final class LayoutEditHistoryTests: XCTestCase {
    private let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: 0.25, h: 0.5))

    private func library(_ pieces: [LayoutPiece]) -> LayoutLibrary {
        let t = LayoutTemplate(name: "T", oneDisplay: pieces)
        return LayoutLibrary(templates: [t], activeID: t.id)
    }

    private func named(_ p: LayoutPiece) -> String { "Chat" }

    // R9.1
    func testMovingAPieceIsNamedMoveChat() {
        let old = library([chat])
        var new = old
        new.templates[0].oneDisplay[0].rect.x = 0.5
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: new, pieceName: named)?.name, "Move Chat")
    }

    // R9.1
    func testResizingAPieceIsNamedResizeChat() {
        let old = library([chat])
        var new = old
        new.templates[0].oneDisplay[0].rect.w = 0.5
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: new, pieceName: named)?.name, "Resize Chat")
    }

    // R9.1
    func testAddingAPieceIsNamedAddChat() {
        let old = library([])
        let new = library([chat])
        var n = new; n.templates[0].id = old.templates[0].id
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: n, pieceName: named)?.name, "Add Chat")
    }

    // R9.1
    func testRemovingAPieceIsNamedRemoveChat() {
        let old = library([chat])
        var new = old
        new.templates[0].oneDisplay = []
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: new, pieceName: named)?.name, "Remove Chat")
    }

    // R9.1
    func testMovingToTheOtherDisplayNamesTheDisplay() {
        var t = LayoutTemplate(name: "T", twoDisplays: TwoDisplay(main: [chat]))
        let old = LayoutLibrary(templates: [t], activeID: t.id)
        t.twoDisplays = TwoDisplay(main: [], second: [chat])
        let new = LayoutLibrary(templates: [t], activeID: t.id)
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: new, pieceName: named)?.name,
                       "Move Chat to Second Display")
    }

    // R9.1
    func testFlippingShowToEveryoneIsNamed() {
        let old = library([chat])
        var hidden = old
        hidden.templates[0].oneDisplay[0].showsToEveryone = false
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: hidden, pieceName: named)?.name, "Hide Chat from Everyone")
        XCTAssertEqual(LayoutEditHistory.describe(from: hidden, to: old, pieceName: named)?.name, "Show Chat to Everyone")
    }

    // R9.1
    func testFlippingMyScreenIsNamed() {
        let meeting = LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false), rect: chat.rect)
        let old = library([meeting])
        var new = old
        new.templates[0].oneDisplay[0].kind = .meeting(fillsDisplay: false, startsHidden: true)
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: new, pieceName: named)?.name, "Hide Chat on My Screen")
        XCTAssertEqual(LayoutEditHistory.describe(from: new, to: old, pieceName: named)?.name, "Show Chat on My Screen")
    }

    // R9.1
    func testRenamingTheLayoutFoldsIntoOneStepWhileTyping() {
        let old = library([chat])
        var new = old
        new.templates[0].name = "Tu"
        let step = LayoutEditHistory.describe(from: old, to: new, pieceName: named)
        XCTAssertEqual(step?.name, "Rename Layout")
        XCTAssertEqual(step?.coalesceKey, "name:\(old.templates[0].id)")
    }

    // R9.1
    func testChangingAPiecesSettingsFoldsWhileTyping() {
        let site = LayoutPiece(kind: .app(AppPiece(bundleID: "com.apple.Safari", url: "a")), rect: chat.rect)
        let old = library([site])
        var new = old
        new.templates[0].oneDisplay[0].kind = .app(AppPiece(bundleID: "com.apple.Safari", url: "ab"))
        let step = LayoutEditHistory.describe(from: old, to: new, pieceName: named)
        XCTAssertEqual(step?.name, "Change Chat")
        XCTAssertEqual(step?.coalesceKey, "settings:\(site.id)")
    }

    // R9.1
    func testAddingAndDeletingALayout() {
        let old = library([chat])
        var added = old
        added.templates.append(LayoutTemplate(name: "Two"))
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: added, pieceName: named)?.name, "Add Layout")
        XCTAssertEqual(LayoutEditHistory.describe(from: added, to: old, pieceName: named)?.name, "Delete Layout")
    }

    // R9.1
    func testChoosingAnotherActiveLayoutIsNotAnEdit() {
        let old = library([chat])
        var new = old
        new.activeID = nil
        XCTAssertNil(LayoutEditHistory.describe(from: old, to: new, pieceName: named))
    }

    // R9.1
    func testTwoDisplayVersionIsNamed() {
        let old = library([chat])
        var two = old
        two.templates[0].twoDisplays = TwoDisplay()
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: two, pieceName: named)?.name, "Add Second Display")
        XCTAssertEqual(LayoutEditHistory.describe(from: two, to: old, pieceName: named)?.name, "Remove Second Display")
    }

    // R9.1
    func testCameraEditsAreNamed() {
        let old = library([chat])
        var moved = old
        var cam = LayoutCamera()
        cam.rightInset = 0.2
        moved.templates[0].camera = cam
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: moved, pieceName: named)?.name, "Move Camera")
        var bigger = moved
        bigger.templates[0].camera?.widthFraction = 0.4
        XCTAssertEqual(LayoutEditHistory.describe(from: moved, to: bigger, pieceName: named)?.name, "Resize Camera")
        var square = bigger
        square.templates[0].camera?.shape = .square
        XCTAssertEqual(LayoutEditHistory.describe(from: bigger, to: square, pieceName: named)?.name, "Change Camera Shape")
    }

    // R9.1
    func testAnythingElseIsChangeLayout() {
        let old = library([chat])
        var new = old
        new.templates[0].share = ShareTarget()
        XCTAssertEqual(LayoutEditHistory.describe(from: old, to: new, pieceName: named)?.name, "Change Layout")
    }

    // R9.1
    func testEditsWithTheSameKeyCloseTogetherFoldIntoOneStep() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let step = LayoutEditHistory.Step(name: "Rename Layout", coalesceKey: "name:1")
        XCTAssertTrue(LayoutEditHistory.folds(previous: ("name:1", t0), into: step, at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(LayoutEditHistory.folds(previous: ("name:1", t0), into: step, at: t0.addingTimeInterval(3)), "a pause starts a new step")
        XCTAssertFalse(LayoutEditHistory.folds(previous: ("name:2", t0), into: step, at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(LayoutEditHistory.folds(previous: nil, into: step, at: t0))
        let move = LayoutEditHistory.Step(name: "Move Chat", coalesceKey: nil)
        XCTAssertFalse(LayoutEditHistory.folds(previous: ("name:1", t0), into: move, at: t0))
    }

    // R9.1
    func testUndoingAnEditKeepsTheLayoutChosenSince() {
        let other = LayoutTemplate(name: "Other")
        var old = library([chat])
        old.templates.append(other)
        var edited = old
        edited.templates[0].oneDisplay[0].rect.x = 0.5
        var now = edited
        now.activeID = other.id   // picked another card after the edit
        let undone = LayoutEditHistory.restoring(old, undoing: edited, onto: now)
        XCTAssertEqual(undone.templates, old.templates)
        XCTAssertEqual(undone.activeID, other.id)
    }

    // R9.1
    func testUndoingADeleteOfTheActiveLayoutBringsBackBothLayoutAndChoice() {
        let old = library([chat])
        var deleted = old
        deleted.templates = []
        deleted.activeID = nil
        let undone = LayoutEditHistory.restoring(old, undoing: deleted, onto: deleted)
        XCTAssertEqual(undone, old)
    }

    // R9.1: a Size slider drag is one step, not one per tick.
    func testResizingTheCameraFoldsWhileTheSliderMoves() {
        let old = library([chat])
        var a = old
        a.templates[0].camera = LayoutCamera()
        a.templates[0].camera?.widthFraction = 0.30
        var b = a
        b.templates[0].camera?.widthFraction = 0.31
        let second = LayoutEditHistory.describe(from: a, to: b, pieceName: named)
        XCTAssertEqual(second?.name, "Resize Camera")
        XCTAssertNotNil(second?.coalesceKey)
        guard let step = second, let key = step.coalesceKey else { return XCTFail("no fold key") }
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(LayoutEditHistory.folds(previous: (key, t0), into: step, at: t0.addingTimeInterval(0.1)))
    }

    // R9.1: moving the camera is still its own step each time.
    func testMovingTheCameraDoesNotFold() {
        let old = library([chat])
        var moved = old
        moved.templates[0].camera = LayoutCamera()
        moved.templates[0].camera?.rightInset = 0.2
        XCTAssertNil(LayoutEditHistory.describe(from: old, to: moved, pieceName: named)?.coalesceKey)
    }

    // R9.1, R12.2: an undo can never leave no active layout: if the layout chosen since is gone, Leave my windows alone is.
    func testUndoNeverLeavesNoActiveLayout() {
        let lib = LayoutLibrary(templates: LayoutLibrary.starters())
        var edited = lib
        edited.templates[0].name = "Renamed"
        var now = edited
        now.activeID = nil
        let undone = LayoutEditHistory.restoring(lib, undoing: edited, onto: now)
        XCTAssertEqual(undone.templates, lib.templates)
        XCTAssertEqual(undone.activeID, lib.leaveAloneID)
        XCTAssertNotNil(undone.active)
    }
}
