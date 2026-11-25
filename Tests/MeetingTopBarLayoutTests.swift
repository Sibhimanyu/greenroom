import XCTest

/// The Meeting window's top bar never draws its buttons under the share eye
/// (the title bar's trailing accessory, WindowShareController).
final class MeetingTopBarLayoutTests: XCTestCase {
    typealias L = MeetingTopBarLayout
    /// The eye's host: 24pt switch plus 12pt, at the window's right edge.
    let reserve: CGFloat = 36

    private func eye(width: CGFloat) -> CGRect { CGRect(x: width - reserve, y: 0, width: reserve, height: 36) }

    func testTheButtonsEndBeforeTheShareEye() {
        // 760: the Meeting window's minimum width; 320: a placed slot's; 1280: a normal one.
        for width: CGFloat in [320, 760, 1280] {
            for shrinkShown in [true, false] {
                let r = L.right(width: width, height: 36, viewWidth: 52, shrinkWidth: 70,
                                shrinkShown: shrinkShown, trailingReserve: reserve)
                XCTAssertFalse(r.view.intersects(eye(width: width)), "View under the eye at \(width)")
                if shrinkShown { XCTAssertFalse(r.shrink.intersects(eye(width: width)), "Smaller under the eye at \(width)") }
                XCTAssertLessThan(r.shrink.maxX, r.view.minX)
                XCTAssertLessThanOrEqual(r.rightEdge, (shrinkShown ? r.shrink : r.view).minX)
            }
        }
    }

    func testWithNoAccessoryTheButtonsKeepTheirEdge() {
        let r = L.right(width: 760, height: 36, viewWidth: 52, shrinkWidth: 70, shrinkShown: true, trailingReserve: 0)
        XCTAssertEqual(r.view.maxX, 760 - L.edge)
    }

    func testEverythingFitsAtTheMinimumWidths() {
        // Left: traffic lights (78) and the shield (30). Nothing on the right may reach into it.
        let r = L.right(width: 760, height: 36, viewWidth: 52, shrinkWidth: 70, shrinkShown: true, trailingReserve: reserve)
        XCTAssertGreaterThan(r.shrink.minX, 78 + 30)
        let slot = L.right(width: 320, height: 36, viewWidth: 52, shrinkWidth: 70, shrinkShown: false, trailingReserve: reserve)
        XCTAssertGreaterThan(slot.view.minX, 78 + 30)
    }
}
