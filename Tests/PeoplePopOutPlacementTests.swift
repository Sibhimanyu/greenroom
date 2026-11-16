import XCTest
import CoreGraphics

/// The bar's People list opens beside the bar, never off the screen.
final class PeoplePopOutPlacementTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 320, height: 440)

    func testABarAtTheTopOpensTheListBelowItsRightEnd() {
        let bar = CGRect(x: 400, y: 820, width: 600, height: 52)
        let f = PeoplePopOutPlacement.frame(size: size, bar: bar, area: area)
        XCTAssertEqual(f.maxX, bar.maxX)
        XCTAssertEqual(f.maxY, bar.minY - PeoplePopOutPlacement.gap)
    }

    func testABarAtTheBottomOpensTheListAboveIt() {
        let bar = CGRect(x: 400, y: 40, width: 600, height: 52)
        let f = PeoplePopOutPlacement.frame(size: size, bar: bar, area: area)
        XCTAssertEqual(f.minY, bar.maxY + PeoplePopOutPlacement.gap)
    }

    func testTheListStaysOnTheScreen() {
        let bar = CGRect(x: 0, y: 820, width: 200, height: 52)  // narrower than the list, at the left edge
        let f = PeoplePopOutPlacement.frame(size: size, bar: bar, area: area)
        XCTAssertGreaterThanOrEqual(f.minX, area.minX)
        XCTAssertTrue(area.contains(f))
    }
}
