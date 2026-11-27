import XCTest
@testable import GreenroomTests

/// R1: the Zoom window opens beside the setup guide on the same screen.
final class ZoomMarketplaceWindowPlacementTests: XCTestCase {
    private let guideSize = CGSize(width: 680, height: 700)

    private func assertBeside(_ f: ZoomMarketplaceWindowPlacement.Frames, in screen: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(screen.contains(f.guide), "guide on screen", file: file, line: line)
        XCTAssertTrue(screen.contains(f.zoom), "zoom on screen", file: file, line: line)
        XCTAssertTrue(f.guide.intersection(f.zoom).isNull || f.guide.intersection(f.zoom).width < 1, "side by side", file: file, line: line)
        XCTAssertEqual(f.guide.size, guideSize, "the guide keeps its size", file: file, line: line)
    }

    func testCentredGuideOn1440MovesLeftAndZoomTakesTheRest() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let guide = CGRect(x: 380, y: 100, width: 680, height: 700)
        let f = ZoomMarketplaceWindowPlacement.frames(screen: screen, guide: guide)
        assertBeside(f, in: screen)
        XCTAssertEqual(f.guide.minX, 0)
        XCTAssertEqual(f.zoom.minX, 680)
        XCTAssertEqual(f.zoom.width, 760)
        XCTAssertEqual(f.zoom.height, 900)
    }

    func testCentredGuideOn1920AlsoMovesLeftAndZoomIsCapped() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let guide = CGRect(x: 620, y: 190, width: 680, height: 700)
        let f = ZoomMarketplaceWindowPlacement.frames(screen: screen, guide: guide)
        assertBeside(f, in: screen)
        XCTAssertEqual(f.guide.minX, 0)
        XCTAssertEqual(f.zoom.minX, 680)
        XCTAssertEqual(f.zoom.width, 1200)
    }

    func testAGuideWithRoomOnItsRightStaysPut() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let guide = CGRect(x: 100, y: 190, width: 680, height: 700)
        let f = ZoomMarketplaceWindowPlacement.frames(screen: screen, guide: guide)
        assertBeside(f, in: screen)
        XCTAssertEqual(f.guide, guide)
        XCTAssertEqual(f.zoom.minX, 780)
        XCTAssertEqual(f.zoom.width, 1140)
    }

    func testAGuideAlreadyOnTheRightGetsZoomOnItsLeft() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let guide = CGRect(x: 760, y: 100, width: 680, height: 700)
        let f = ZoomMarketplaceWindowPlacement.frames(screen: screen, guide: guide)
        assertBeside(f, in: screen)
        XCTAssertEqual(f.guide, guide)
        XCTAssertEqual(f.zoom.maxX, 760)
        XCTAssertEqual(f.zoom.width, 760)
    }

    func testASecondScreenWithAnOffsetOrigin() {
        let screen = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let guide = CGRect(x: 1440 + 620, y: 0, width: 680, height: 700)
        let f = ZoomMarketplaceWindowPlacement.frames(screen: screen, guide: guide)
        assertBeside(f, in: screen)
        XCTAssertEqual(f.guide.minX, 1440)
    }

    func testANarrowScreenStillSitsSideBySide() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let f = ZoomMarketplaceWindowPlacement.frames(screen: screen, guide: CGRect(x: 300, y: 50, width: 680, height: 700))
        assertBeside(f, in: screen)
        XCTAssertEqual(f.zoom.width, 600)
    }

    func testWithNoGuideTheWindowIsCentredWithItsUsualSize() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let z = ZoomMarketplaceWindowPlacement.alone(screen: screen)
        XCTAssertTrue(screen.contains(z))
        XCTAssertEqual(z.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(z.width, 1200)
        let small = ZoomMarketplaceWindowPlacement.alone(screen: CGRect(x: 0, y: 0, width: 1000, height: 700))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1000, height: 700).contains(small))
    }
}
