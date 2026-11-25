import XCTest

/// Owner, 2026-11-26: "I am not able to drag around the Greenroom Browser window
/// by dragging the top part of it." The empty parts of the tab strip and the
/// toolbar move the window; tabs, buttons and the address field keep their clicks.
final class BrowserChromeDragTests: XCTestCase {

    func testTheEmptyPartsOfTheTopDragTheWindow() {
        XCTAssertTrue(BrowserChromeDrag.dragsWindow(.tabStripEmpty))
        XCTAssertTrue(BrowserChromeDrag.dragsWindow(.toolbarEmpty))
    }

    func testControlsKeepTheirOwnClicks() {
        for region in [BrowserChromeDrag.Region.tab, .tabClose, .newTabButton, .toolbarButton, .addressField, .moreMenu] {
            XCTAssertFalse(BrowserChromeDrag.dragsWindow(region), "\(region)")
        }
    }

    // MARK: Double-click follows System Settings > Desktop & Dock

    func testDoubleClickZoomsByDefault() {
        XCTAssertEqual(BrowserChromeDrag.doubleClick(actionSetting: nil, legacyMinimise: nil), .zoom)
        XCTAssertEqual(BrowserChromeDrag.doubleClick(actionSetting: "Maximize", legacyMinimise: nil), .zoom)
        XCTAssertEqual(BrowserChromeDrag.doubleClick(actionSetting: "Fill", legacyMinimise: nil), .zoom)
    }

    func testDoubleClickMinimisesOrDoesNothingWhenSetSo() {
        XCTAssertEqual(BrowserChromeDrag.doubleClick(actionSetting: "Minimize", legacyMinimise: nil), .minimise)
        XCTAssertEqual(BrowserChromeDrag.doubleClick(actionSetting: "None", legacyMinimise: nil), .nothing)
    }

    func testTheOldMinimiseSwitchCountsWhenTheNewOneIsUnset() {
        XCTAssertEqual(BrowserChromeDrag.doubleClick(actionSetting: nil, legacyMinimise: true), .minimise)
        XCTAssertEqual(BrowserChromeDrag.doubleClick(actionSetting: "Maximize", legacyMinimise: true), .zoom)
    }
}
