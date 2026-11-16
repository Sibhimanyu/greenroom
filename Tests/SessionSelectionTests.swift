import XCTest

final class SessionSelectionTests: XCTestCase {
    let order = ["a", "b", "c", "d", "e"]

    func testPlainClickPicksOne() {
        var s = SessionSelection()
        s.click("b", order: order, command: false, shift: false)
        s.click("d", order: order, command: false, shift: false)
        XCTAssertEqual(s.ids, ["d"])
    }

    func testCommandClickToggles() {
        var s = SessionSelection()
        s.click("a", order: order, command: false, shift: false)
        s.click("c", order: order, command: true, shift: false)
        XCTAssertEqual(s.ids, ["a", "c"])
        s.click("a", order: order, command: true, shift: false)
        XCTAssertEqual(s.ids, ["c"])
    }

    func testShiftExtendsInDisplayOrderBothWays() {
        var s = SessionSelection()
        s.click("b", order: order, command: false, shift: false)
        s.click("d", order: order, command: false, shift: true)
        XCTAssertEqual(s.ids, ["b", "c", "d"])
        s.click("a", order: order, command: false, shift: true)
        XCTAssertEqual(s.ids, ["a", "b"])
    }

    func testShiftWithoutAnchorPicksOne() {
        var s = SessionSelection()
        s.click("c", order: order, command: false, shift: true)
        XCTAssertEqual(s.ids, ["c"])
    }

    func testSelectAllAndClear() {
        var s = SessionSelection()
        s.selectAll(["x", "y"])
        XCTAssertEqual(s.ids, ["x", "y"])
        s.clear()
        XCTAssertTrue(s.isEmpty)
    }

    func testKeepOnlyDropsHiddenCards() {
        var s = SessionSelection()
        s.selectAll(order)
        s.keep(only: ["b", "c"])
        XCTAssertEqual(s.ids, ["b", "c"])
    }

    func testOrderedFollowsDisplay() {
        let s = SessionSelection(ids: ["d", "a"])
        XCTAssertEqual(s.ordered(order), ["a", "d"])
    }

    func testLiveSessionsAreSkipped() {
        let plan = SessionTrashPlan.split(["a", "b", "c"], live: ["b"])
        XCTAssertEqual(plan.trash, ["a", "c"])
        XCTAssertEqual(plan.skipped, ["b"])
    }

    func testMessageNamesCounts() {
        XCTAssertTrue(SessionTrashPlan.message(trash: 3, skipped: 1).contains("3 sessions go to the Trash"))
        XCTAssertTrue(SessionTrashPlan.message(trash: 3, skipped: 1).contains("1 session is live"))
        XCTAssertTrue(SessionTrashPlan.message(trash: 1, skipped: 0).contains("1 session goes to the Trash"))
    }
}
