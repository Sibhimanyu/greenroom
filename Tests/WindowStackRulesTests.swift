import XCTest

/// R45.6: coming back to a desktop keeps Greenroom's windows stacked exactly as
/// the owner left them. Owner, 2026-11-26: Self view floated over the Greenroom
/// Browser; after a desktop switch and back it was behind the browser. Window
/// numbers here are front to back, as CGWindowList lists them.
final class WindowStackRulesTests: XCTestCase {

    private let selfView = 41, browser = 17, chat = 23

    func testTheLoggedCasePutsSelfViewBackAboveTheBrowser() {
        let moves = WindowStackRules.restoreMoves(saved: [selfView, browser, chat], current: [browser, selfView, chat])
        XCTAssertEqual(moves, [WindowStackRules.Move(window: selfView, above: browser)])
    }

    func testTheSameOrderMovesNothing() {
        XCTAssertEqual(WindowStackRules.restoreMoves(saved: [selfView, browser, chat], current: [selfView, browser, chat]), [])
    }

    func testOnlyWindowsInBothListsAreOrdered() {
        // Chat closed since; a new People window opened: neither is touched.
        let people = 77
        let moves = WindowStackRules.restoreMoves(saved: [selfView, chat, browser], current: [people, browser, selfView])
        XCTAssertEqual(moves, [WindowStackRules.Move(window: selfView, above: browser)])
    }

    func testAWholeReversalIsRebuiltFromTheBack() {
        let moves = WindowStackRules.restoreMoves(saved: [1, 2, 3], current: [3, 2, 1])
        XCTAssertEqual(moves, [WindowStackRules.Move(window: 2, above: 3), WindowStackRules.Move(window: 1, above: 2)])
    }

    func testNothingToOrderWithFewerThanTwoShared() {
        XCTAssertEqual(WindowStackRules.restoreMoves(saved: [1], current: [1, 2]), [])
        XCTAssertEqual(WindowStackRules.restoreMoves(saved: [], current: [2, 1]), [])
    }

    func testAClickAfterComingBackWinsOverTheSavedOrder() {
        XCTAssertTrue(WindowStackRules.shouldRestore(ownerActedSinceSwitch: false))
        XCTAssertFalse(WindowStackRules.shouldRestore(ownerActedSinceSwitch: true))
    }

    func testTheRestoreRunsAfterActivationSettlesAndAgainBeforeTheFreezeEnds() {
        XCTAssertFalse(WindowStackRules.restoreDelays.isEmpty)
        XCTAssertTrue(WindowStackRules.restoreDelays.allSatisfy { $0 > 0 && $0 < WindowStackRules.freezeSeconds })
        XCTAssertLessThanOrEqual(WindowStackRules.freezeSeconds, 1.5)
    }

    // MARK: A window we hid comes back to its place, not the front

    func testAWindowComingBackGoesAboveTheOneThatWasUnderIt() {
        XCTAssertEqual(WindowStackRules.slot(for: selfView, saved: [selfView, browser, chat], visibleNow: [browser, chat]),
                       .above(browser))
    }

    func testItSkipsAWindowUnderItThatHasGone() {
        XCTAssertEqual(WindowStackRules.slot(for: selfView, saved: [selfView, browser, chat], visibleNow: [chat]),
                       .above(chat))
    }

    func testAWindowWithNoRecordOrNothingUnderItGoesToTheFront() {
        XCTAssertEqual(WindowStackRules.slot(for: 99, saved: [selfView, browser], visibleNow: [browser]), .front)
        XCTAssertEqual(WindowStackRules.slot(for: chat, saved: [selfView, browser, chat], visibleNow: [browser]), .front)
    }

    // MARK: One order per desktop

    func testEachDesktopKeepsItsOwnOrder() {
        var memory = WindowStackMemory()
        memory.remember([selfView, browser])      // desktop 1
        memory.remember([chat, 90])               // desktop 2: none of desktop 1's windows
        XCTAssertEqual(memory.saved(for: [browser, selfView]), [selfView, browser])
        XCTAssertEqual(memory.saved(for: [90, chat]), [chat, 90])
    }

    func testANewerOrderOfTheSameWindowsReplacesTheOlder() {
        var memory = WindowStackMemory()
        memory.remember([selfView, browser])
        memory.remember([browser, selfView])      // the owner clicked the browser
        XCTAssertEqual(memory.saved(for: [selfView, browser]), [browser, selfView])
        XCTAssertEqual(memory.orders.count, 1)
    }

    func testAnOrderOfOneWindowIsNotWorthKeeping() {
        var memory = WindowStackMemory()
        memory.remember([browser])
        XCTAssertNil(memory.saved(for: [browser]))
    }

    func testTheMemoryStaysSmall() {
        var memory = WindowStackMemory()
        for n in 0..<20 { memory.remember([1000 + 2 * n, 1001 + 2 * n]) }
        XCTAssertEqual(memory.orders.count, WindowStackMemory.limit)
    }
}
