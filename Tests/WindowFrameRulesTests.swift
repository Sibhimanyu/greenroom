import XCTest
@testable import GreenroomTests

final class WindowFrameRulesTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let page = CGSize(width: 1180, height: 760)

    func testHomeCentredGrowsAroundMiddleTopKept() {
        let home = NSRect(x: 568, y: 400, width: 784, height: 600)
        let f = WindowFrameRules.centred(on: home, size: page, in: screen)
        XCTAssertEqual(f.midX, home.midX)
        XCTAssertEqual(f.maxY, home.maxY)
        XCTAssertEqual(f.width, 1180)
    }

    func testClampsRightAndLeft() {
        let right = NSRect(x: 1500, y: 400, width: 400, height: 600)
        XCTAssertEqual(WindowFrameRules.centred(on: right, size: page, in: screen).maxX, screen.maxX)
        let left = NSRect(x: 10, y: 400, width: 400, height: 600)
        XCTAssertEqual(WindowFrameRules.centred(on: left, size: page, in: screen).minX, screen.minX)
    }

    func testBottomShiftsUpOnlyWhenOffScreen() {
        let low = NSRect(x: 568, y: 50, width: 784, height: 300)
        let f = WindowFrameRules.centred(on: low, size: page, in: screen)
        XCTAssertEqual(f.minY, 0)
        let high = NSRect(x: 568, y: 400, width: 784, height: 600)
        XCTAssertEqual(WindowFrameRules.centred(on: high, size: page, in: screen).minY, high.maxY - 760)
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
        XCTAssertEqual(f.midX, cur.midX)
        XCTAssertEqual(f.maxY, cur.maxY)
        XCTAssertEqual(f.size, home.size)
    }

    func testBackFallsBackWhenRememberedScreenGone() {
        let home = NSRect(x: 2500, y: 400, width: 784, height: 600)
        let cur = NSRect(x: 370, y: 240, width: 1180, height: 760)
        let f = WindowFrameRules.returningHome(
            remembered: home, size: home.size, current: cur,
            movedOnPage: false, visibleFrames: [screen], currentVisible: screen)
        XCTAssertEqual(f.midX, cur.midX)
        XCTAssertEqual(f.maxY, cur.maxY)
    }

    func testMovedDetection() {
        let a = NSRect(x: 100, y: 100, width: 500, height: 400)
        XCTAssertFalse(WindowFrameRules.moved(from: nil, to: a))
        XCTAssertFalse(WindowFrameRules.moved(from: a, to: a.offsetBy(dx: 1, dy: 0)))
        XCTAssertTrue(WindowFrameRules.moved(from: a, to: a.offsetBy(dx: 30, dy: 0)))
    }
}
