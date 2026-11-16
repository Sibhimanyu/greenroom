import XCTest
@testable import GreenroomTests

final class WindowFrameRulesTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let page = CGSize(width: 1180, height: 760)

    func testPageGrowsOutFromHomesCentre() {
        let home = NSRect(x: 664, y: 364, width: 592, height: 352)   // centred on the 1920x1080 screen
        let f = WindowFrameRules.pageFrame(from: home, size: page, visibleFrames: [screen])
        XCTAssertEqual(f.midX, home.midX)
        XCTAssertEqual(f.midY, home.midY)
        XCTAssertEqual(f.size, page)
    }

    func testEditGrowsAboutTheMiddle() {
        let home = NSRect(x: 664, y: 364, width: 592, height: 352)
        let f = WindowFrameRules.centred(on: home, size: CGSize(width: 592, height: 502), in: screen)
        XCTAssertEqual(f.midY, home.midY)
        XCTAssertEqual(f.minX, home.minX)
        XCTAssertEqual(f.height, 502)
        // Near the bottom of the screen it is pushed up only by the overflow.
        let low = NSRect(x: 100, y: 20, width: 592, height: 352)
        let g = WindowFrameRules.centred(on: low, size: CGSize(width: 592, height: 502), in: screen)
        XCTAssertEqual(g.minY, 0)
        XCTAssertEqual(g.height, 502)
    }

    func testClampsRightOnly() {
        let right = NSRect(x: 1500, y: 400, width: 400, height: 600)
        let f = WindowFrameRules.pageFrame(from: right, size: page, visibleFrames: [screen])
        XCTAssertEqual(f.maxX, screen.maxX)
        XCTAssertEqual(f.midY, right.midY)
    }

    func testLowHomeShiftsUpByOverflowAndRoundTripsExactly() {
        // Home sits low: bottom at y=20, 352 tall (Home, 2026-11-14: the collapsed column). The page needs 408 more.
        let home = NSRect(x: 568, y: 20, width: 592, height: 352)
        let pageFrame = WindowFrameRules.pageFrame(from: home, size: page, visibleFrames: [screen])
        XCTAssertEqual(pageFrame.minY, 0)
        XCTAssertEqual(pageFrame.midX, home.midX)
        let back = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: pageFrame, movedOnPage: false,
            visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(back, home)
    }

    func testNotShiftedWhenItFits() {
        let high = NSRect(x: 568, y: 500, width: 592, height: 352)
        XCTAssertEqual(WindowFrameRules.pageFrame(from: high, size: page, visibleFrames: [screen]).midY,
                       high.midY)
    }

    func testSecondaryScreenUsesItsOwnBounds() {
        let second = NSRect(x: 1920, y: -200, width: 1440, height: 900)
        let home = NSRect(x: 2400, y: -150, width: 592, height: 352)
        let pageFrame = WindowFrameRules.pageFrame(from: home, size: page, visibleFrames: [screen, second])
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

    func testBackAfterMoveCentresOnThePage() {
        let home = NSRect(x: 568, y: 500, width: 592, height: 352)
        let cur = NSRect(x: 100, y: 200, width: 1180, height: 760)
        let f = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: cur,
            movedOnPage: true, visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(f.midX, cur.midX)
        XCTAssertEqual(f.midY, cur.midY)
        XCTAssertEqual(f.size, home.size)
    }

    func testBackFallsBackWhenRememberedScreenGone() {
        let home = NSRect(x: 2500, y: 400, width: 592, height: 352)
        let cur = NSRect(x: 370, y: 240, width: 1180, height: 760)
        let f = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: cur,
            movedOnPage: false, visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(f.midX, cur.midX)
        XCTAssertEqual(f.midY, cur.midY)
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

    func testExpandGrowsAboutTheCentreThenCollapseIsIdentical() {
        let size = CGSize(width: 592 + extra, height: 352)
        let expanded = WindowFrameRules.expandedFrame(from: collapsed, size: size, in: screen)
        XCTAssertEqual(expanded.midX, collapsed.midX, accuracy: 0.5)
        XCTAssertEqual(expanded.midY, collapsed.midY, accuracy: 0.5)
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
        XCTAssertEqual(expanded.midY, near.midY)
        let back = WindowFrameRules.collapsedFrame(restoring: near, current: expanded, size: near.size,
                                                   movedSinceExpand: false, in: screen)
        XCTAssertEqual(back, near)
    }

    func testCollapseAfterMoveKeepsCurrentCentre() {
        let expanded = NSRect(x: 300, y: 200, width: 592 + extra, height: 352)
        let back = WindowFrameRules.collapsedFrame(restoring: collapsed, current: expanded, size: collapsed.size,
                                                   movedSinceExpand: true, in: screen)
        XCTAssertEqual(back.midX, expanded.midX, accuracy: 0.5)
        XCTAssertEqual(back.midY, expanded.midY, accuracy: 0.5)
        XCTAssertEqual(back.size, collapsed.size)
    }

    func testMovedDetection() {
        let a = NSRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertFalse(WindowFrameRules.moved(from: nil, to: a))
        XCTAssertFalse(WindowFrameRules.moved(from: a, to: a.offsetBy(dx: 1, dy: 0)))
        XCTAssertTrue(WindowFrameRules.moved(from: a, to: a.offsetBy(dx: 30, dy: 0)))
    }
}
