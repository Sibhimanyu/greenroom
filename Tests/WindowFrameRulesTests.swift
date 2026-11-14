import XCTest
@testable import GreenroomTests

final class WindowFrameRulesTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let page = CGSize(width: 1180, height: 760)

    func testPageGrowsDownRightFromTopLeft() {
        let home = NSRect(x: 568, y: 500, width: 592, height: 352)
        let f = WindowFrameRules.pageFrame(from: home, size: page, visibleFrames: [screen])
        XCTAssertEqual(f.minX, home.minX)
        XCTAssertEqual(f.maxY, home.maxY)
        XCTAssertEqual(f.size, page)
    }

    func testClampsRightOnly() {
        let right = NSRect(x: 1500, y: 400, width: 400, height: 600)
        let f = WindowFrameRules.pageFrame(from: right, size: page, visibleFrames: [screen])
        XCTAssertEqual(f.maxX, screen.maxX)
        XCTAssertEqual(f.maxY, right.maxY)
    }

    func testLowHomeShiftsUpByOverflowAndRoundTripsExactly() {
        // Home sits low: bottom at y=20, 352 tall (Home, 2026-11-14: the collapsed column). The page needs 408 more.
        let home = NSRect(x: 568, y: 20, width: 592, height: 352)
        let pageFrame = WindowFrameRules.pageFrame(from: home, size: page, visibleFrames: [screen])
        XCTAssertEqual(pageFrame.minY, 0)
        XCTAssertEqual(pageFrame.minX, home.minX)
        let back = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: pageFrame, movedOnPage: false,
            visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(back, home)
    }

    func testNotShiftedWhenItFits() {
        let high = NSRect(x: 568, y: 500, width: 592, height: 352)
        XCTAssertEqual(WindowFrameRules.pageFrame(from: high, size: page, visibleFrames: [screen]).minY,
                       high.maxY - 760)
    }

    func testSecondaryScreenUsesItsOwnBounds() {
        let second = NSRect(x: 1920, y: -200, width: 1440, height: 900)
        let home = NSRect(x: 2400, y: -150, width: 592, height: 352)
        let pageFrame = WindowFrameRules.pageFrame(from: home, size: page, visibleFrames: [screen, second])
        XCTAssertEqual(pageFrame.minY, second.minY)
        XCTAssertEqual(pageFrame.maxX, second.maxX)
        XCTAssertTrue(second.contains(pageFrame))
        let back = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: pageFrame, movedOnPage: false,
            visibleFrames: [screen, second], currentVisible: second)
        XCTAssertEqual(back, home)
    }

    func testBackRestoresRememberedOriginWhenUnmoved() {
        let home = NSRect(x: 568, y: 500, width: 592, height: 352)
        let f = WindowFrameRules.returningHome(
            remembered: home, size: home.size,
            current: NSRect(x: 370, y: 240, width: 1180, height: 760),
            movedOnPage: false, visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(f, home)
    }

    func testBackAfterMoveKeepsMiddleAndTop() {
        let home = NSRect(x: 568, y: 500, width: 592, height: 352)
        let cur = NSRect(x: 100, y: 200, width: 1180, height: 760)
        let f = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: cur,
            movedOnPage: true, visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(f.minX, cur.minX)
        XCTAssertEqual(f.maxY, cur.maxY)
        XCTAssertEqual(f.size, home.size)
    }

    func testBackFallsBackWhenRememberedScreenGone() {
        let home = NSRect(x: 2500, y: 400, width: 592, height: 352)
        let cur = NSRect(x: 370, y: 240, width: 1180, height: 760)
        let f = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: cur,
            movedOnPage: false, visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(f.minX, cur.minX)
        XCTAssertEqual(f.maxY, cur.maxY)
    }

    // Home's preview (2026-11-14): collapsed 592 wide, expanded 592 + 24 + 405.
    let collapsed = NSRect(x: 568, y: 400, width: 592, height: 352)
    let extra: CGFloat = 429

    func testCollapsedRoundTripReturnsIdenticalFrame() {
        let pageFrame = WindowFrameRules.pageFrame(from: collapsed, size: page, visibleFrames: [screen])
        let back = WindowFrameRules.returningHome(
            remembered: collapsed, size: collapsed.size, current: pageFrame, movedOnPage: false,
            visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(back, collapsed)
    }

    func testExpandedRoundTripReturnsIdenticalFrame() {
        let expanded = WindowFrameRules.expandedFrame(
            from: collapsed, size: CGSize(width: 592 + extra, height: 352), in: screen)
        let pageFrame = WindowFrameRules.pageFrame(from: expanded, size: page, visibleFrames: [screen])
        let back = WindowFrameRules.returningHome(
            remembered: expanded, size: expanded.size, current: pageFrame, movedOnPage: false,
            visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(back, expanded)
    }

    func testExpandGrowsRightWithTopLeftAnchoredThenCollapseIsIdentical() {
        let size = CGSize(width: 592 + extra, height: 352)
        let expanded = WindowFrameRules.expandedFrame(from: collapsed, size: size, in: screen)
        XCTAssertEqual(expanded.minX, collapsed.minX)
        XCTAssertEqual(expanded.maxY, collapsed.maxY)
        let back = WindowFrameRules.collapsedFrame(restoring: collapsed, current: expanded, size: collapsed.size,
                                                   movedSinceExpand: false, in: screen)
        XCTAssertEqual(back, collapsed)
    }

    func testExpandShiftsLeftOnlyByOverflowAndCollapseRestoresExactFrame() {
        let near = NSRect(x: 1700, y: 400, width: 592, height: 352)
        let expanded = WindowFrameRules.expandedFrame(
            from: near, size: CGSize(width: 592 + extra, height: 352), in: screen)
        XCTAssertEqual(expanded.maxX, screen.maxX)
        XCTAssertEqual(expanded.minX, screen.maxX - (592 + extra))
        XCTAssertEqual(expanded.maxY, near.maxY)
        let back = WindowFrameRules.collapsedFrame(restoring: near, current: expanded, size: near.size,
                                                   movedSinceExpand: false, in: screen)
        XCTAssertEqual(back, near)
    }

    func testCollapseAfterMoveKeepsCurrentTopLeft() {
        let expanded = NSRect(x: 300, y: 200, width: 592 + extra, height: 352)
        let back = WindowFrameRules.collapsedFrame(restoring: collapsed, current: expanded, size: collapsed.size,
                                                   movedSinceExpand: true, in: screen)
        XCTAssertEqual(back.minX, expanded.minX)
        XCTAssertEqual(back.maxY, expanded.maxY)
        XCTAssertEqual(back.size, collapsed.size)
    }

    func testMovedDetection() {
        let a = NSRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertFalse(WindowFrameRules.moved(from: nil, to: a))
        XCTAssertFalse(WindowFrameRules.moved(from: a, to: a.offsetBy(dx: 1, dy: 0)))
        XCTAssertTrue(WindowFrameRules.moved(from: a, to: a.offsetBy(dx: 30, dy: 0)))
    }
}
