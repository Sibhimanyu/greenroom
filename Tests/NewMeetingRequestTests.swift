import XCTest
@testable import GreenroomTests

final class NewMeetingRequestTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testNoFixedTimeIsType3WithoutRecurrence() {
        let body = NewMeetingRequest(name: " Maths 10B ").body(calendar: cal)
        XCTAssertEqual(body["type"] as? Int, 3)
        XCTAssertEqual(body["topic"] as? String, "Maths 10B")
        XCTAssertNil(body["recurrence"])
        XCTAssertNil(body["start_time"])
        let settings = body["settings"] as? [String: Any]
        XCTAssertEqual(settings?["waiting_room"] as? Bool, false)
        XCTAssertEqual(settings?["join_before_host"] as? Bool, false)
    }

    func testWaitingRoomFollowsToggle() {
        var r = NewMeetingRequest(name: "x")
        r.studentsJoinDirectly = false
        XCTAssertEqual((r.body(calendar: cal)["settings"] as? [String: Any])?["waiting_room"] as? Bool, true)
    }

    func testWeeklyIsType8WithZoomDayNumbers() {
        // 2026-11-16 is a Monday, 08:00 local: Mon 9:00 is still ahead.
        var r = NewMeetingRequest(name: "x")
        r.weekly = true
        r.days = [2, 4, 1] // Mon, Wed, Sun
        let body = r.body(now: date(2026, 11, 16, 8, 0), calendar: cal)
        XCTAssertEqual(body["type"] as? Int, 8)
        XCTAssertEqual(body["start_time"] as? String, "2026-11-16T09:00:00")
        XCTAssertEqual(body["timezone"] as? String, "Asia/Kolkata")
        XCTAssertEqual(body["duration"] as? Int, 60)
        let rec = body["recurrence"] as? [String: Any]
        XCTAssertEqual(rec?["type"] as? Int, 2)
        XCTAssertEqual(rec?["repeat_interval"] as? Int, 1)
        XCTAssertEqual(rec?["weekly_days"] as? String, "1,2,4")
        XCTAssertEqual(rec?["end_times"] as? Int, 50)
    }

    func testMondayThroughSundayMapsToZoomNumbers() {
        XCTAssertEqual(NewMeetingRequest.weekdays.map(\.zoom), [2, 3, 4, 5, 6, 7, 1])
    }

    func testTodayButTimePassedGoesToNextWeek() {
        let start = NewMeetingRequest.nextStart(days: [2], hour: 9, minute: 0,
                                                after: date(2026, 11, 16, 10, 0), calendar: cal)
        XCTAssertEqual(start, date(2026, 11, 23, 9, 0))
    }

    func testPicksTheNearestMatchingDay() {
        // Monday evening, Wed and Fri chosen: Wednesday.
        let start = NewMeetingRequest.nextStart(days: [4, 6], hour: 9, minute: 30,
                                                after: date(2026, 11, 16, 20, 0), calendar: cal)
        XCTAssertEqual(start, date(2026, 11, 18, 9, 30))
    }

    func testValidity() {
        var r = NewMeetingRequest(name: "  ")
        XCTAssertFalse(r.isValid)
        r.name = "Class"
        XCTAssertTrue(r.isValid)
        r.weekly = true
        XCTAssertFalse(r.isValid) // no day
        r.days = [3]
        XCTAssertTrue(r.isValid)
    }
}

final class NewMeetingParseTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }

    func testType3ParsesAsNoFixedTime() {
        let r = NewMeetingRequest.parse(["topic": "Maths", "type": 3,
                                         "settings": ["waiting_room": false]], calendar: cal)
        XCTAssertEqual(r.name, "Maths")
        XCTAssertFalse(r.weekly)
        XCTAssertTrue(r.studentsJoinDirectly)
    }

    func testType8ParsesDaysTimeAndDuration() {
        // 04:00 UTC is 09:30 in Kolkata.
        let r = NewMeetingRequest.parse([
            "topic": "10B", "type": 8, "start_time": "2026-11-16T04:00:00Z", "duration": 45,
            "recurrence": ["type": 2, "weekly_days": "2,4"],
            "settings": ["waiting_room": true],
        ], calendar: cal)
        XCTAssertTrue(r.weekly)
        XCTAssertEqual(r.days, [2, 4])
        XCTAssertEqual(r.hour, 9)
        XCTAssertEqual(r.minute, 30)
        XCTAssertEqual(r.durationMinutes, 45)
        XCTAssertFalse(r.studentsJoinDirectly)
    }

    func testTimeSnapsToNearestQuarter() {
        func snapped(_ utc: String) -> (Int, Int) {
            let r = NewMeetingRequest.parse(["type": 8, "start_time": utc], calendar: cal)
            return (r.hour, r.minute)
        }
        XCTAssertEqual(snapped("2026-11-16T04:08:00Z").1, 45) // 9:38 -> 9:45
        XCTAssertEqual(snapped("2026-11-16T04:05:00Z").1, 30) // 9:35 -> 9:30
    }

    func testSnapUpAndWrapPastMidnight() {
        // 18:25 UTC = 23:55 IST -> 00:00.
        let r = NewMeetingRequest.parse(["type": 8, "start_time": "2026-11-16T18:25:00Z"], calendar: cal)
        XCTAssertEqual(r.hour, 0)
        XCTAssertEqual(r.minute, 0)
    }

    func testMissingWaitingRoomMeansJoinDirectly() {
        XCTAssertTrue(NewMeetingRequest.parse(["type": 3], calendar: cal).studentsJoinDirectly)
    }
}

final class ZoomScopesTests: XCTestCase {
    func testSevenScopesWithUniqueNamesAndEveryKeyOnce() {
        XCTAssertEqual(ZoomScopes.count, 7)
        XCTAssertEqual(Set(ZoomScopes.names).count, 7)
        XCTAssertEqual(Set(ZoomScopes.all.map(\.key)), Set(ZoomScopes.Key.allCases))
        XCTAssertTrue(ZoomScopes.names.contains("meeting:update:meeting:admin"))
        XCTAssertTrue(ZoomScopes.names.contains("meeting:delete:meeting:admin"))
        XCTAssertEqual(ZoomScopes.countWord, "seven")
    }

    func testGrantedByNameOrLegacy() {
        let update = ZoomScopes.scope(.update)
        XCTAssertTrue(ZoomScopes.isGranted(update, in: ["meeting:update:meeting:admin"]))
        XCTAssertTrue(ZoomScopes.isGranted(update, in: ["meeting:write:admin"]))
        XCTAssertFalse(ZoomScopes.isGranted(update, in: ["meeting:read:admin"]))
    }

    func testMissingListsOnlyTheAbsentOnes() {
        let granted = Set(ZoomScopes.names).subtracting(["meeting:delete:meeting:admin"])
        XCTAssertEqual(ZoomScopes.missing(in: granted).map(\.key), [.delete])
    }

    func testEditErrorsNameOnlyTheScopeForTheAction() {
        let body = "{\"code\":4711,\"message\":\"Invalid access token, does not contain scopes:[meeting:update:meeting:admin]\"}"
        let text = ZoomServerToServerError.meetingEditFailed(.update, body).errorDescription ?? ""
        XCTAssertTrue(text.contains("meeting:update:meeting:admin"))
        XCTAssertFalse(text.contains("meeting:delete:meeting:admin"))
        XCTAssertFalse(text.contains("meeting:read:meeting:admin"))
        XCTAssertTrue(text.contains("Check Zoom setup lists them all"))
    }
}
