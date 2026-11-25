import XCTest

/// The canvas keys the hint row promises, as one table.
final class LayoutKeyRulesTests: XCTestCase {
    private func act(_ key: LayoutKey, shift: Bool = false, option: Bool = false,
                     selected: Bool = true, hasOther: Bool = true) -> LayoutKeyAction {
        LayoutKeyRules.action(for: key, shift: shift, option: option, hasSelection: selected, hasOtherDisplay: hasOther)
    }

    func testBothDeleteKeysRemove() {
        XCTAssertEqual(act(.delete), .remove)
        XCTAssertEqual(act(.deleteForward), .remove)
    }

    func testDeleteNeedsASelection() {
        XCTAssertEqual(act(.delete, selected: false), .ignore)
        XCTAssertEqual(act(.deleteForward, selected: false), .ignore)
    }

    func testArrowsMoveAndShiftArrowsResize() {
        XCTAssertEqual(act(.left), .nudge(cols: -1, rows: 0))
        XCTAssertEqual(act(.down), .nudge(cols: 0, rows: 1))
        XCTAssertEqual(act(.right, shift: true), .grow(cols: 1, rows: 0))
        XCTAssertEqual(act(.up, shift: true), .grow(cols: 0, rows: -1))
        XCTAssertEqual(act(.up, selected: false), .ignore)
    }

    func testOptionLeftRightSendsToTheOtherDisplay() {
        XCTAssertEqual(act(.left, option: true), .sendToOtherDisplay)
        XCTAssertEqual(act(.right, option: true), .sendToOtherDisplay)
        XCTAssertEqual(act(.up, option: true), .nudge(cols: 0, rows: -1))
        XCTAssertEqual(act(.left, option: true, hasOther: false), .nudge(cols: -1, rows: 0))
    }

    func testEscapeDeselectsOnlyWhenSomethingIsSelected() {
        XCTAssertEqual(act(.escape), .deselect)
        XCTAssertEqual(act(.escape, selected: false), .ignore)
    }

    func testTabCycles() {
        XCTAssertEqual(act(.tab), .cycle(backwards: false))
        XCTAssertEqual(act(.tab, shift: true, selected: false), .cycle(backwards: true))
    }

    // R9.3
    func testEscapeCancelsADragInProgressBeforeAnythingElse() {
        XCTAssertEqual(LayoutKeyRules.action(for: .escape, shift: false, option: false, hasSelection: true,
                                             hasOtherDisplay: false, isDragging: true), .cancelDrag)
        XCTAssertEqual(LayoutKeyRules.action(for: .escape, shift: false, option: false, hasSelection: false,
                                             hasOtherDisplay: false, isDragging: true), .cancelDrag)
    }

    // R9.5
    func testReadingOrderIsTopToBottomThenLeftToRight() {
        let a = LayoutPiece(kind: .chat, rect: UnitRect(x: 0.5, y: 0, w: 0.25, h: 0.25))
        let b = LayoutPiece(kind: .roomScreen, rect: UnitRect(x: 0, y: 0, w: 0.25, h: 0.25))
        let c = LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false), rect: UnitRect(x: 0, y: 0.5, w: 0.25, h: 0.25))
        XCTAssertEqual(LayoutKeyRules.readingOrder([c, a, b]), [b.id, a.id, c.id])
    }

    // R9.5
    func testTabWalksTheOrderThenLetsGo() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertEqual(LayoutKeyRules.cycleTarget(order: ids, current: nil, backwards: false), ids[0])
        XCTAssertEqual(LayoutKeyRules.cycleTarget(order: ids, current: nil, backwards: true), ids[2])
        XCTAssertEqual(LayoutKeyRules.cycleTarget(order: ids, current: ids[0], backwards: false), ids[1])
        XCTAssertEqual(LayoutKeyRules.cycleTarget(order: ids, current: ids[1], backwards: true), ids[0])
        XCTAssertNil(LayoutKeyRules.cycleTarget(order: ids, current: ids[2], backwards: false))
        XCTAssertNil(LayoutKeyRules.cycleTarget(order: ids, current: ids[0], backwards: true))
        XCTAssertNil(LayoutKeyRules.cycleTarget(order: [], current: nil, backwards: false))
    }

    // R9.5
    func testAnIdFromAnotherCanvasStartsTheWalkHere() {
        let ids = [UUID(), UUID()]
        XCTAssertEqual(LayoutKeyRules.cycleTarget(order: ids, current: UUID(), backwards: false), ids[0])
        XCTAssertEqual(LayoutKeyRules.cycleTarget(order: ids, current: UUID(), backwards: true), ids[1])
    }

    // R9.2
    func testDeleteOnTheCameraSaysItCannotBeRemoved() {
        let camera = UUID(), piece = UUID()
        XCTAssertEqual(LayoutKeyRules.removal(selection: camera, cameraID: camera),
                       .notice("Your camera can\u{2019}t be removed. Hide it on your screen instead."))
        XCTAssertEqual(LayoutKeyRules.removal(selection: piece, cameraID: camera), .piece(piece))
        XCTAssertEqual(LayoutKeyRules.removal(selection: nil, cameraID: camera), .nothing)
    }
}
