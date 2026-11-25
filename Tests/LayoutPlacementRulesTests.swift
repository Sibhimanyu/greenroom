import XCTest
import CoreGraphics

/// R45: a layout places windows once. Only Start, a layout switch and Snap Back
/// (the shortcut or the menu bar) re-place what is already placed; a window the
/// owner moved stays where it is; nothing a layout does activates an app.
final class LayoutPlacementRulesTests: XCTestCase {

    private let explicit: [PlacementTrigger] = [.start, .switchedLayout, .snapBack]

    // MARK: Snap, Start and a switch re-place everything

    func testSnapBackRePlacesEveryWindowEvenOneMovedByHand() {
        for state in PlacedWindowState.allCases {
            XCTAssertTrue(LayoutPlacementRules.shouldPlace(.snapBack, state), "\(state)")
        }
    }

    func testStartAndASwitchPlaceEveryWindow() {
        for trigger in [PlacementTrigger.start, .switchedLayout] {
            for state in PlacedWindowState.allCases {
                XCTAssertTrue(LayoutPlacementRules.shouldPlace(trigger, state), "\(trigger) \(state)")
            }
        }
    }

    // MARK: Nothing else re-places a placed window

    func testAMoveByHandIsNeverUndone() {
        for trigger in PlacementTrigger.allCases where !explicit.contains(trigger)
            && trigger != .displaysConnectedOrDisconnected {
            XCTAssertFalse(LayoutPlacementRules.shouldPlace(trigger, .movedByHand), "\(trigger)")
        }
    }

    func testTheOwnersOwnMoveAndTheOneSecondLoopPlaceNothing() {
        for trigger in [PlacementTrigger.movedByHand, .tick] {
            for state in PlacedWindowState.allCases {
                XCTAssertFalse(LayoutPlacementRules.shouldPlace(trigger, state), "\(trigger) \(state)")
            }
        }
    }

    func testEditingTheRunningLayoutMovesNoWindowUntilSnap() {
        for state in PlacedWindowState.allCases {
            XCTAssertFalse(LayoutPlacementRules.shouldPlace(.layoutEdited, state), "\(state)")
        }
    }

    func testBringingTheMeetingBackLeavesPlacedWindowsWhereTheyAre() {
        XCTAssertFalse(LayoutPlacementRules.shouldPlace(.meetingShown, .placed))
        XCTAssertFalse(LayoutPlacementRules.shouldPlace(.meetingShown, .movedByHand))
        // A view that never opened (it started hidden) opens at its rectangle once.
        XCTAssertTrue(LayoutPlacementRules.shouldPlace(.meetingShown, .neverPlaced))
    }

    func testAResolutionOrDockChangeMovesNothing() {
        for state in PlacedWindowState.allCases {
            XCTAssertFalse(LayoutPlacementRules.shouldPlace(.displaySettingsChanged, state), "\(state)")
        }
    }

    /// Kept as it is today: a display plugged in or pulled out re-places everything.
    func testADisplayComingOrGoingStillRePlacesEverything() {
        for state in PlacedWindowState.allCases {
            XCTAssertTrue(LayoutPlacementRules.shouldPlace(.displaysConnectedOrDisconnected, state), "\(state)")
        }
    }

    // MARK: A window that appears later

    func testALateWindowIsPlacedOnceWhenItFirstAppears() {
        XCTAssertTrue(LayoutPlacementRules.shouldPlace(.windowAppeared, .neverPlaced))
        XCTAssertFalse(LayoutPlacementRules.shouldPlace(.windowAppeared, .placed))
        XCTAssertFalse(LayoutPlacementRules.shouldPlace(.windowAppeared, .movedByHand))
    }

    // MARK: The neighbour that grows into the Meeting's gap

    func testTheNeighbourGrowsOnlyIfItIsStillWhereTheLayoutPutIt() {
        XCTAssertTrue(LayoutPlacementRules.shouldPlace(.neighbourMakesRoom, .placed))
        XCTAssertFalse(LayoutPlacementRules.shouldPlace(.neighbourMakesRoom, .movedByHand))
    }

    // MARK: Focus

    func testPlacingNeverActivatesAnApp() {
        for trigger in PlacementTrigger.allCases {
            XCTAssertFalse(LayoutPlacementRules.activatesWhenPlacing(trigger), "\(trigger)")
        }
    }

    func testOnlyTheEndOfStartHandsFocusToTheMainApp() {
        for trigger in PlacementTrigger.allCases {
            XCTAssertEqual(LayoutPlacementRules.handsFocusToMainApp(trigger), trigger == .start, "\(trigger)")
        }
    }

    func testOnlyAnExplicitPassOrdersPlacedWindowsFront() {
        for trigger in PlacementTrigger.allCases {
            let raises = explicit.contains(trigger) || trigger == .displaysConnectedOrDisconnected
            XCTAssertEqual(LayoutPlacementRules.raisesPlacedWindows(trigger), raises, "\(trigger)")
        }
    }

    // MARK: Telling a hand move from a placed window

    func testNoWindowIsNeverPlaced() {
        XCTAssertEqual(LayoutPlacementRules.state(windowExists: false, current: nil, placed: CGRect(x: 0, y: 0, width: 10, height: 10)),
                       .neverPlaced)
    }

    func testAWindowStillAtItsPlacedFrameIsPlaced() {
        let placed = CGRect(x: 100, y: 40, width: 800, height: 600)
        XCTAssertEqual(LayoutPlacementRules.state(windowExists: true, current: placed.offsetBy(dx: 2, dy: -1), placed: placed),
                       .placed)
    }

    func testAWindowDraggedOrResizedIsMovedByHand() {
        let placed = CGRect(x: 100, y: 40, width: 800, height: 600)
        XCTAssertEqual(LayoutPlacementRules.state(windowExists: true, current: placed.offsetBy(dx: 60, dy: 0), placed: placed),
                       .movedByHand)
        XCTAssertEqual(LayoutPlacementRules.state(windowExists: true,
                                                  current: CGRect(x: 100, y: 40, width: 640, height: 600), placed: placed),
                       .movedByHand)
    }

    /// No record of where it went (no Accessibility read, never placed by us): it is
    /// taken as placed, so only the explicit triggers and the neighbour move touch it.
    func testAnOpenWindowWithNoRecordIsPlaced() {
        XCTAssertEqual(LayoutPlacementRules.state(windowExists: true, current: nil, placed: nil), .placed)
        XCTAssertEqual(LayoutPlacementRules.state(windowExists: true,
                                                  current: CGRect(x: 0, y: 0, width: 5, height: 5), placed: nil), .placed)
    }
}
