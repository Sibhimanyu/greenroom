import XCTest

/// A click on a tile or Speaker view's stage opens that person's drawer.
final class ParticipantClickRulesTests: XCTestCase {
    typealias C = ParticipantClick

    func testClickingSomeoneOpensTheirDrawer() {
        XCTAssertEqual(C.leftClick(on: .person(7, isMyself: false), selected: nil), .init(selected: 7, consumed: true))
        // Another person while one is open: switches.
        XCTAssertEqual(C.leftClick(on: .person(8, isMyself: false), selected: 7), .init(selected: 8, consumed: true))
    }
    func testClickingTheSamePersonAgainClosesIt() {
        XCTAssertEqual(C.leftClick(on: .person(7, isMyself: false), selected: 7), .init(selected: nil, consumed: true))
    }
    func testAClickElsewhereClosesItAndGoesOn() {
        XCTAssertEqual(C.leftClick(on: .elsewhere, selected: 7), .init(selected: nil, consumed: false))
        XCTAssertEqual(C.leftClick(on: .elsewhere, selected: nil), .init(selected: nil, consumed: false))
    }
    func testTheDrawerKeepsItsOwnClicks() {
        XCTAssertEqual(C.leftClick(on: .drawer, selected: 7), .init(selected: 7, consumed: false))
    }
    func testYouAreNeverSelected() {
        XCTAssertEqual(C.leftClick(on: .person(1, isMyself: true), selected: nil), .init(selected: nil, consumed: false))
        XCTAssertEqual(C.leftClick(on: .person(1, isMyself: true), selected: 7), .init(selected: nil, consumed: false))
        XCTAssertNil(C.menuFor(.person(1, isMyself: true)))
    }
    func testRightClickGivesThePersonsMenu() {
        XCTAssertEqual(C.menuFor(.person(7, isMyself: false)), 7)
        XCTAssertNil(C.menuFor(.elsewhere))
        XCTAssertNil(C.menuFor(.drawer))
    }
}
