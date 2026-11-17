import XCTest

final class ScreenRecoveryTests: XCTestCase {

    func testPermissionRefusalIsNotRetried() {
        var r = ScreenRecovery()
        let d = r.failed("declined", permission: true, choiceStands: true)
        XCTAssertNil(d.retryIn)
        XCTAssertNil(d.logLine)
        XCTAssertFalse(r.inOutage)
    }

    func testOtherErrorRetriesEveryFiveSeconds() {
        var r = ScreenRecovery()
        let d = r.failed("no displays", permission: false, choiceStands: true)
        XCTAssertEqual(d.retryIn, 5)
        XCTAssertTrue(r.inOutage)
    }

    func testChoiceChangedStops() {
        var r = ScreenRecovery()
        _ = r.failed("no displays", permission: false, choiceStands: true)
        let d = r.failed("no displays", permission: false, choiceStands: false)
        XCTAssertNil(d.retryIn)
        XCTAssertNil(d.logLine)
        XCTAssertFalse(r.inOutage)
    }

    func testOnlyTheFirstFailureLogs() {
        var r = ScreenRecovery()
        let lines = (0..<120).compactMap { _ in r.failed("asleep", permission: false, choiceStands: true).logLine }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("asleep"))
    }

    func testRecoveryLogsOnceAndOnlyAfterAnOutage() {
        var r = ScreenRecovery()
        XCTAssertNil(r.recovered())
        _ = r.failed("asleep", permission: false, choiceStands: true)
        _ = r.failed("asleep", permission: false, choiceStands: true)
        XCTAssertEqual(r.recovered(), "Screen capture back (after 2 attempts).")
        XCTAssertNil(r.recovered())
        // A new outage logs again.
        XCTAssertNotNil(r.failed("asleep", permission: false, choiceStands: true).logLine)
    }
}
