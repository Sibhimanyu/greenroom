import XCTest
@testable import GreenroomTests

/// R1: the Zoom window opens large and centred on the setup guide's screen; the guide never moves.
final class ZoomMarketplaceWindowPlacementTests: XCTestCase {
    private func check(_ screen: CGRect, _ w: CGFloat, _ h: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let f = ZoomMarketplaceWindowPlacement.frame(screen: screen)
        XCTAssertEqual(f.width, w, file: file, line: line)
        XCTAssertEqual(f.height, h, file: file, line: line)
        XCTAssertEqual(f.midX, screen.midX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(f.midY, screen.midY, accuracy: 1, file: file, line: line)
        XCTAssertTrue(screen.contains(f), file: file, line: line)
    }

    func testAbout85PercentOfAVisibleFrame() {
        check(CGRect(x: 0, y: 0, width: 1440, height: 900), 1224, 765)
    }

    func testCappedAt1400By1000() {
        check(CGRect(x: 0, y: 0, width: 2560, height: 1440), 1400, 1000)
        check(CGRect(x: 0, y: 0, width: 1920, height: 1080), 1400, 918)
    }

    func testNeverSmallerThan900By700() {
        check(CGRect(x: 0, y: 0, width: 1024, height: 768), 900, 700)
        check(CGRect(x: 0, y: 0, width: 1280, height: 800), 1088, 700)
    }

    func testAScreenSmallerThanTheMinimumKeepsTheWindowOnIt() {
        check(CGRect(x: 0, y: 0, width: 800, height: 600), 800, 600)
    }

    func testASecondScreenWithAnOffsetOrigin() {
        check(CGRect(x: 1440, y: -200, width: 1920, height: 1080), 1400, 918)
    }
}
