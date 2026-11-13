import XCTest

final class BannerLayoutTests: XCTestCase {
    // A 1440x900 display with a 25pt menu bar and a 70pt Dock at the bottom,
    // on a second screen offset to the right.
    private let visible = CGRect(x: 1440, y: 70, width: 1440, height: 805)

    func testSingleCardIsCentredAndInsetFromTheMenuBar() {
        let f = BannerLayout.cardFrames(sizes: [CGSize(width: 340, height: 100)], in: visible)[0]
        XCTAssertEqual(f.midX, visible.midX)
        XCTAssertEqual(visible.maxY - f.maxY, 12)
        XCTAssertEqual(f.size, CGSize(width: 340, height: 100))
    }

    func testCardsStackDownwardWithEightPointGaps() {
        let sizes = [CGSize(width: 340, height: 120), CGSize(width: 340, height: 60), CGSize(width: 340, height: 50)]
        let frames = BannerLayout.cardFrames(sizes: sizes, in: visible)
        XCTAssertEqual(frames.count, 3)
        for i in 1..<frames.count {
            XCTAssertEqual(frames[i - 1].minY - frames[i].maxY, 8)
            XCTAssertEqual(frames[i].midX, visible.midX)
        }
        XCTAssertTrue(frames.allSatisfy { visible.contains($0) })
    }

    func testPanelFrameWrapsTheStackWithShadowRoom() {
        let stack = CGSize(width: 340, height: 200)
        let panel = BannerLayout.panelFrame(stack: stack, in: visible)
        XCTAssertEqual(panel.width, 340 + 28)
        XCTAssertEqual(panel.height, 200 + 28)
        // The panel is centred and the cards inside are still 12pt from the top.
        XCTAssertEqual(panel.midX, visible.midX)
        XCTAssertEqual(visible.maxY - (panel.maxY - BannerLayout.shadowPad), 12)
    }

    func testNoCardsNoFrames() {
        XCTAssertTrue(BannerLayout.cardFrames(sizes: [], in: visible).isEmpty)
    }
}
