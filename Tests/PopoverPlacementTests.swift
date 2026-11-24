import XCTest
@testable import GreenroomTests

final class PopoverPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 80, width: 1440, height: 800)  // Dock takes the bottom 80

    func testTallContentNearBottomStopsAboveDock() {
        let anchor = CGRect(x: 600, y: 200, width: 60, height: 40)
        let r = PopoverPlacement.frame(anchor: anchor, contentSize: CGSize(width: 300, height: 900), visible: visible)
        let room = (anchor.minY - 8) - visible.minY - 12
        XCTAssertEqual(r.bodySize.height, room, accuracy: 0.01)
        // The panel is the body: its bottom sits 12 above the visible bottom.
        XCTAssertEqual(r.panelFrame.minY, visible.minY + 12, accuracy: 0.01)
    }

    func testHangsEightBelowTheAnchor() {
        let anchor = CGRect(x: 600, y: 600, width: 60, height: 40)
        let r = PopoverPlacement.frame(anchor: anchor, contentSize: CGSize(width: 300, height: 200), visible: visible)
        XCTAssertEqual(r.panelFrame.maxY, anchor.minY - 8, accuracy: 0.01)
        XCTAssertEqual(r.panelFrame.midX, anchor.midX, accuracy: 0.01)
    }

    func testShortContentKeepsItsHeight() {
        let r = PopoverPlacement.frame(anchor: CGRect(x: 600, y: 600, width: 60, height: 40),
                                       contentSize: CGSize(width: 300, height: 200), visible: visible)
        XCTAssertEqual(r.bodySize, CGSize(width: 300, height: 200))
    }

    func testNeverLeavesLeftOrRightEdge() {
        for x in [CGFloat(0), 10, 1400, 1430] {
            let r = PopoverPlacement.frame(anchor: CGRect(x: x, y: 400, width: 30, height: 30),
                                           contentSize: CGSize(width: 300, height: 200), visible: visible)
            XCTAssertGreaterThanOrEqual(r.panelFrame.minX, visible.minX + 12 - 0.01)
            XCTAssertLessThanOrEqual(r.panelFrame.maxX, visible.maxX - 12 + 0.01)
        }
    }

    func testWideContentIsClampedAndCentred() {
        let r = PopoverPlacement.frame(anchor: CGRect(x: 700, y: 400, width: 40, height: 30),
                                       contentSize: CGSize(width: 5000, height: 200), visible: visible)
        XCTAssertEqual(r.bodySize.width, visible.width - 24, accuracy: 0.01)
        XCTAssertEqual(r.panelFrame.midX, visible.midX, accuracy: 0.01)
    }

    func testContentGrowthIsCappedAgain() {
        let anchor = CGRect(x: 600, y: 300, width: 60, height: 40)
        let a = PopoverPlacement.frame(anchor: anchor, contentSize: CGSize(width: 300, height: 100), visible: visible)
        let b = PopoverPlacement.frame(anchor: anchor, contentSize: CGSize(width: 300, height: 2000), visible: visible)
        XCTAssertEqual(a.panelFrame.maxY, b.panelFrame.maxY, accuracy: 0.01)  // top never moves
        XCTAssertGreaterThanOrEqual(b.panelFrame.minY, visible.minY + 12 - 0.01)
    }
}
