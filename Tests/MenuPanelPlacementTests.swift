//
//  MenuPanelPlacementTests.swift
//  GreenroomTests
//
//  Where a MeetingMenuPanel goes (MenuPanelPlacement): the whole menu, last row included, is always
//  on the screen's visible frame. Above the control when it fits, else below, else shifted onto the
//  screen, and only a menu taller than the screen scrolls. AppKit screen space, y up.
//
import XCTest

final class MenuPanelPlacementTests: XCTestCase {

    /// A 14" MacBook's visible frame (menu bar out, Dock hidden).
    private let area = CGRect(x: 0, y: 0, width: 1512, height: 944)

    /// The bar's camera menu as the owner's screenshot had it: a header, four items with a two-line
    /// note, a divider and Stop video (also two lines), in MeetingMenuPanel's row metrics.
    private var cameraMenu: CGSize {
        let header: CGFloat = 6 + 14 + 2
        let twoLineItem: CGFloat = 4 + 16 + 1 + 2 * 14 + 4
        let separator: CGFloat = 1 + 2 * 4
        return CGSize(width: 364, height: 6 + header + 4 * twoLineItem + separator + twoLineItem + 6)
    }

    private func assertWhole(_ p: MenuPanelPlacement, _ size: CGSize, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(p.scrolls, "no scrolling needed, \(what)", file: file, line: line)
        XCTAssertEqual(p.frame.size, size, "the whole menu, Stop video included, \(what)", file: file, line: line)
        XCTAssertTrue(area.contains(p.frame), "on the visible frame, \(what): \(p.frame)", file: file, line: line)
    }

    // The screenshot: the floating bar near the bottom of the screen, the menu opening upward.
    func testTheBarsCameraMenuOpensWholeAboveTheBarNearTheBottom() {
        let arrow = CGRect(x: 700, y: 24, width: 20, height: 34)
        let p = MenuPanelPlacement.place(size: cameraMenu, anchor: arrow, area: area, below: false)
        assertWhole(p, cameraMenu, "bar near the bottom")
        XCTAssertEqual(p.frame.minY, arrow.maxY + MenuPanelPlacement.gap, "just above the bar, never over it")
        XCTAssertEqual(p.frame.minX, arrow.minX, "aligned to the cell")
    }

    // Not enough room above: it opens below instead.
    func testItFlipsBelowWhenTheTopIsFull() {
        let arrow = CGRect(x: 700, y: 900, width: 20, height: 34)
        let p = MenuPanelPlacement.place(size: cameraMenu, anchor: arrow, area: area, below: false)
        assertWhole(p, cameraMenu, "bar near the top")
        XCTAssertEqual(p.frame.maxY, arrow.minY - MenuPanelPlacement.gap)
    }

    // A hanging menu (the menu bar's) near the bottom flips up.
    func testAHangingMenuFlipsUpWhenTheBottomIsFull() {
        let button = CGRect(x: 700, y: 20, width: 20, height: 20)
        let p = MenuPanelPlacement.place(size: cameraMenu, anchor: button, area: area, below: true)
        assertWhole(p, cameraMenu, "hanging near the bottom")
        XCTAssertEqual(p.frame.minY, button.maxY + MenuPanelPlacement.gap)
    }

    // Neither side has room (a short display, the bar in the middle): shifted onto the screen, whole.
    func testWithNoRoomOnEitherSideItShiftsOntoTheScreenWhole() {
        let short = CGRect(x: 0, y: 0, width: 1280, height: 400)
        let arrow = CGRect(x: 1200, y: 180, width: 20, height: 34)
        let p = MenuPanelPlacement.place(size: cameraMenu, anchor: arrow, area: short, below: false)
        XCTAssertFalse(p.scrolls)
        XCTAssertEqual(p.frame.size, cameraMenu)
        XCTAssertTrue(short.contains(p.frame), "\(p.frame)")
        XCTAssertEqual(p.frame.maxX, short.maxX, "kept inside the right edge")
    }

    // Only a menu taller than the whole visible frame scrolls, and it then fills the frame's height.
    func testOnlyAMenuTallerThanTheScreenScrolls() {
        let tiny = CGRect(x: 0, y: 0, width: 1280, height: 240)
        let arrow = CGRect(x: 100, y: 10, width: 20, height: 34)
        let p = MenuPanelPlacement.place(size: cameraMenu, anchor: arrow, area: tiny, below: false)
        XCTAssertTrue(p.scrolls)
        XCTAssertEqual(p.frame.height, tiny.height)
        XCTAssertEqual(p.frame.width, cameraMenu.width)
        XCTAssertTrue(tiny.contains(p.frame), "\(p.frame)")
    }

    // A submenu beside its row is kept on the screen the same way.
    func testASubmenuIsKeptOnTheScreen() {
        let size = CGSize(width: 240, height: 300)
        let p = MenuPanelPlacement.fit(origin: CGPoint(x: 1400, y: -120), size: size, area: area)
        XCTAssertFalse(p.scrolls)
        XCTAssertEqual(p.frame, CGRect(x: area.maxX - 240, y: 0, width: 240, height: 300))
    }
}
