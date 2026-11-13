import XCTest
@testable import GreenroomTests

final class WindowFrameRulesTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let page = CGSize(width: 1180, height: 760)

    func testPageGrowsDownRightFromTopLeft() {
        let home = NSRect(x: 568, y: 400, width: 784, height: 600)
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
        // Home sits low: bottom at y=50, 300 tall. The page needs 460 more.
        let home = NSRect(x: 568, y: 50, width: 784, height: 300)
        let pageFrame = WindowFrameRules.pageFrame(from: home, size: page, visibleFrames: [screen])
        XCTAssertEqual(pageFrame.minY, 0)
        XCTAssertEqual(pageFrame.minX, home.minX)
        let back = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: pageFrame, movedOnPage: false,
            visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(back, home)
    }

    func testNotShiftedWhenItFits() {
        let high = NSRect(x: 568, y: 400, width: 784, height: 600)
        XCTAssertEqual(WindowFrameRules.pageFrame(from: high, size: page, visibleFrames: [screen]).minY,
                       high.maxY - 760)
    }

    func testSecondaryScreenUsesItsOwnBounds() {
        let second = NSRect(x: 1920, y: -200, width: 1440, height: 900)
        let home = NSRect(x: 2400, y: -150, width: 784, height: 300)
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
        let home = NSRect(x: 568, y: 400, width: 784, height: 600)
        let f = WindowFrameRules.returningHome(
            remembered: home, size: home.size,
            current: NSRect(x: 370, y: 240, width: 1180, height: 760),
            movedOnPage: false, visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(f, home)
    }

    func testBackAfterMoveKeepsMiddleAndTop() {
        let home = NSRect(x: 568, y: 400, width: 784, height: 600)
        let cur = NSRect(x: 100, y: 200, width: 1180, height: 760)
        let f = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: cur,
            movedOnPage: true, visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(f.minX, cur.minX)
        XCTAssertEqual(f.maxY, cur.maxY)
        XCTAssertEqual(f.size, home.size)
    }

    func testBackFallsBackWhenRememberedScreenGone() {
        let home = NSRect(x: 2500, y: 400, width: 784, height: 600)
        let cur = NSRect(x: 370, y: 240, width: 1180, height: 760)
        let f = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: cur,
            movedOnPage: false, visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(f.minX, cur.minX)
        XCTAssertEqual(f.maxY, cur.maxY)
    }

    func testMovedDetection() {
        let a = NSRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertFalse(WindowFrameRules.moved(from: nil, to: a))
        XCTAssertFalse(WindowFrameRules.moved(from: a, to: a.offsetBy(dx: 1, dy: 0)))
        XCTAssertTrue(WindowFrameRules.moved(from: a, to: a.offsetBy(dx: 30, dy: 0)))
    }
}
