import XCTest

final class StartChoreographyTests: XCTestCase {

    func testStartingShowsTheIslandAloneAndHidesHome() {
        let s = StartChoreography.surfaces(.starting)
        XCTAssertFalse(s.home)
        XCTAssertFalse(s.bar, "the floating bar waits for the meeting to be live")
        XCTAssertTrue(s.island, "the island is the only status surface while starting")
    }

    func testTheIslandOffersCancelOnlyForAMeetingStart() {
        XCTAssertTrue(StartChoreography.islandShowsCancel(.starting, recordStart: false))
        XCTAssertFalse(StartChoreography.islandShowsCancel(.starting, recordStart: true))
        XCTAssertFalse(StartChoreography.islandShowsCancel(.live, recordStart: false))
        XCTAssertFalse(StartChoreography.islandShowsCancel(.failed, recordStart: false))
        XCTAssertFalse(StartChoreography.islandShowsCancel(.idle, recordStart: false))
    }

    func testAFailureBringsHomeBackAndKeepsTheErrorOnTheIsland() {
        let s = StartChoreography.surfaces(.failed)
        XCTAssertTrue(s.home)
        XCTAssertFalse(s.bar)
        XCTAssertTrue(s.island)
    }

    func testIdleIsHomeAlone() {
        XCTAssertEqual(StartChoreography.surfaces(.idle), .init(home: true, bar: false, island: false))
    }

    func testLiveKeepsTheBarAndNoIsland() {
        XCTAssertEqual(StartChoreography.surfaces(.live), .init(home: false, bar: true, island: false))
    }

    func testBarWordsArePlain() {
        XCTAssertEqual(StartChoreography.barText(.starting), "Starting\u{2026}")
        XCTAssertEqual(StartChoreography.barText(.joining), "Joining\u{2026}")
    }

    func testDisplayQuietOnlyWhenAppsOpenOrAWindowLayoutRuns() {
        XCTAssertFalse(StartChoreography.needsDisplayQuiet(opensApps: false, arranges: false))
        XCTAssertTrue(StartChoreography.needsDisplayQuiet(opensApps: true, arranges: false))
        XCTAssertTrue(StartChoreography.needsDisplayQuiet(opensApps: false, arranges: true))
    }

    func testMeetingWindowOpensOnLiveOnlyWithOthersPresent() {
        XCTAssertFalse(StartChoreography.opensMeetingWindowOnLive(arranged: false, customUI: true, othersPresent: false))
        XCTAssertTrue(StartChoreography.opensMeetingWindowOnLive(arranged: false, customUI: true, othersPresent: true))
        // A layout places the Meeting itself; Zoom's own window has none of ours.
        XCTAssertFalse(StartChoreography.opensMeetingWindowOnLive(arranged: true, customUI: true, othersPresent: true))
        XCTAssertFalse(StartChoreography.opensMeetingWindowOnLive(arranged: false, customUI: false, othersPresent: true))
    }

    func testBarOutlivesTheStartExceptForALayoutOnZoomsOwnWindow() {
        XCTAssertTrue(StartChoreography.barKeptAfterLive(arranged: false, customUI: false))
        XCTAssertTrue(StartChoreography.barKeptAfterLive(arranged: true, customUI: true))
        XCTAssertFalse(StartChoreography.barKeptAfterLive(arranged: true, customUI: false))
    }

    func testHomeExitsSmallerAndPartWayToTheBar() {
        let home = CGRect(x: 100, y: 300, width: 800, height: 600)
        let bar = CGRect(x: 400, y: 20, width: 228, height: 44)
        let exit = StartChoreography.homeExitFrame(home: home, bar: bar)
        XCTAssertEqual(exit.width, 400)
        XCTAssertEqual(exit.height, 300)
        XCTAssertLessThan(exit.midY, home.midY)
        XCTAssertGreaterThan(exit.midY, bar.midY)
    }
}
