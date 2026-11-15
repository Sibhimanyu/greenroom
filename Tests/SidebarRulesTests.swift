import XCTest
import SwiftUI
@testable import GreenroomTests

final class SidebarRulesTests: XCTestCase {
    func testHomeAndRecordCollapseTheSidebar() {
        XCTAssertEqual(SidebarRules.visibility(onSessionsPage: false, hidden: false), .detailOnly)
        XCTAssertEqual(SidebarRules.visibility(onSessionsPage: false, hidden: true), .detailOnly)
    }

    func testSessionsPagesShowItUnlessHidden() {
        XCTAssertEqual(SidebarRules.visibility(onSessionsPage: true, hidden: false), .all)
        XCTAssertEqual(SidebarRules.visibility(onSessionsPage: true, hidden: true), .detailOnly)
    }

    func testChoiceIsOnlyRecordedOnSessionsPages() {
        // The system toggle or Command-B on a page is a choice.
        XCTAssertTrue(SidebarRules.hidden(afterVisibility: .detailOnly, onSessionsPage: true, was: false))
        XCTAssertFalse(SidebarRules.hidden(afterVisibility: .all, onSessionsPage: true, was: true))
        // Home forcing the column away is not.
        XCTAssertFalse(SidebarRules.hidden(afterVisibility: .detailOnly, onSessionsPage: false, was: false))
        XCTAssertTrue(SidebarRules.hidden(afterVisibility: .all, onSessionsPage: false, was: true))
    }

    func testASingleSessionHasNoSidebarWhateverWasSaved() {
        XCTAssertEqual(SidebarRules.visibility(onSessionsPage: true, hidden: false, onSingleSession: true), .detailOnly)
        XCTAssertEqual(SidebarRules.visibility(onSessionsPage: true, hidden: true, onSingleSession: true), .detailOnly)
        XCTAssertFalse(SidebarRules.shown(onSessionsPage: true, hidden: false, onSingleSession: true))
        XCTAssertTrue(SidebarRules.shown(onSessionsPage: true, hidden: false, onSingleSession: false))
    }

    func testTheSavedGridChoiceSurvivesASingleSession() {
        // The column going away for a session page is not a choice: the saved
        // value is returned untouched, in both directions.
        XCTAssertFalse(SidebarRules.hidden(afterVisibility: .detailOnly, onSessionsPage: true, was: false,
                                           onSingleSession: true))
        XCTAssertTrue(SidebarRules.hidden(afterVisibility: .all, onSessionsPage: true, was: true,
                                          onSingleSession: true))
        // Back on the grid it is the person's choice again.
        XCTAssertTrue(SidebarRules.hidden(afterVisibility: .detailOnly, onSessionsPage: true, was: false,
                                          onSingleSession: false))
    }

    func testDetailMinimumLeavesRoomForTheSidebar() {
        XCTAssertEqual(SidebarRules.detailMinWidth(windowMin: 900, sidebarShown: true, sidebarWidth: 220), 680)
        XCTAssertEqual(SidebarRules.detailMinWidth(windowMin: 900, sidebarShown: false, sidebarWidth: 220), 900)
        XCTAssertEqual(SidebarRules.detailMinWidth(windowMin: 100, sidebarShown: true, sidebarWidth: 220), 0)
    }

    func testSidebarHoldsTheGridMinimum() {
        // Page minimum 900 must hold sidebar 180 + grid 480.
        XCTAssertGreaterThanOrEqual(900 - SidebarRules.widthRange.lowerBound, 480)
    }

    func testCommandBIsReservedFromGlobalHotkeys() {
        XCTAssertNotNil(ReservedShortcuts.reason(for: KeyCombo(keyCode: 11, modifiers: KeyCombo.command)))
    }
}
