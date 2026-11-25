import XCTest

/// The recorder puts the Layouts page's edits on a real UndoManager.
@MainActor
final class LayoutEditRecorderTests: XCTestCase {
    private let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: 0.25, h: 0.5))
    private var manager: UndoManager!
    private var library: LayoutLibrary!
    private var recorder: LayoutEditRecorder!
    private var restored = 0

    override func setUp() {
        let t = LayoutTemplate(name: "T", oneDisplay: [chat])
        library = LayoutLibrary(templates: [t], activeID: t.id)
        manager = UndoManager()
        manager.groupsByEvent = false
        restored = 0
        recorder = LayoutEditRecorder(library: library, read: { [unowned self] in library },
                                      write: { [unowned self] in library = $0 }, nameOf: { _ in "Chat" })
        recorder.undoManager = manager
        recorder.didRestore = { [unowned self] in restored += 1 }
    }

    private func grouped(_ body: () -> Void) {
        manager.beginUndoGrouping(); body(); manager.endUndoGrouping()
    }

    // R9.1: an undo or redo of a library edit tells the page to reconcile its own state.
    func testUndoAndRedoOfALibraryEditTellThePageToReconcile() {
        var edited = library!
        edited.templates[0].twoDisplays = TwoDisplay()
        grouped { library = edited; recorder.observe(edited) }
        manager.undo()
        XCTAssertNil(library.templates[0].twoDisplays)
        XCTAssertEqual(restored, 1)
        manager.redo()
        XCTAssertNotNil(library.templates[0].twoDisplays)
        XCTAssertEqual(restored, 2)
    }

    // R30.3: removing the second display, pieces and all, is one named step; undo brings them back.
    func testRemovingTheSecondDisplayWithPiecesUndoesAndRedoes() {
        let meeting = LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)
        var withSecond = library!
        withSecond.templates[0].addSecondDisplay()
        withSecond.templates[0].setPieces([meeting], for: .second)
        grouped { library = withSecond; recorder.observe(withSecond) }
        var removed = withSecond
        removed.templates[0].removeSecondDisplay()
        grouped { library = removed; recorder.observe(removed) }
        XCTAssertEqual(manager.undoActionName, "Remove Second Display")
        XCTAssertNil(library.templates[0].twoDisplays)
        manager.undo()
        XCTAssertEqual(library.templates[0].pieces(for: .second), [meeting], "the pieces are back")
        XCTAssertEqual(library.templates[0].pieces(for: .main), [chat], "main untouched")
        manager.redo()
        XCTAssertNil(library.templates[0].twoDisplays)
    }

    // R9.1, R6: the camera state is an undoable step, and redo puts it back.
    func testACameraStateChangeUndoesAndRedoes() {
        var state = CameraState.everyoneAndMe
        grouped {
            state = .onlyMe
            recorder.record(.cameraState, undo: { state = .everyoneAndMe }, redo: { state = .onlyMe })
        }
        XCTAssertEqual(manager.undoActionName, "Change Camera State")
        manager.undo()
        XCTAssertEqual(state, .everyoneAndMe)
        manager.redo()
        XCTAssertEqual(state, .onlyMe)
        manager.undo()
        XCTAssertEqual(state, .everyoneAndMe, "undo again after a redo")
    }

    // R9.1, R11: each camera look setting is a named, undoable step.
    func testTheCameraLookIsUndoable() {
        var mirror = true
        grouped {
            mirror = false
            recorder.record(.mirror, undo: { mirror = true }, redo: { mirror = false })
        }
        XCTAssertEqual(manager.undoActionName, "Change Mirror")
        manager.undo()
        XCTAssertTrue(mirror)
        XCTAssertEqual(LayoutEditHistory.SettingEdit.allCases.map(\.name),
                       ["Change Camera State", "Change Camera Background", "Change Background Picture",
                        "Change Background Removal", "Change Mirror"])
    }
}
