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
}
