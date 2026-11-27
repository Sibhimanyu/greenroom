//
//  PersonalRoomTests.swift
//  GreenroomTests
//
//  The Zoom Personal Meeting Room (PMI) on Home's Scheduled list: reading it
//  from GET /users/me, its place in the list, what a missing scope does, the
//  scope itself, and the number as Zoom writes it.
//
import XCTest

final class PersonalRoomTests: XCTestCase {

    private typealias Meeting = ZoomServerToServerClient.ScheduledMeeting

    private let usersMe: [String: Any] = [
        "id": "KDcuGIm1QgePTO8WbOqwIQ",
        "first_name": "Jill", "last_name": "Chill", "display_name": "Jill Chill",
        "pmi": Int64(3542471135), "use_pmi": false,
        "personal_meeting_url": "https://us05web.zoom.us/j/3542471135?pwd=abc123",
        "account_id": "q6gBJVO5TzexKYTb_I2rpg",
    ]

    private func meeting(_ id: Int64, _ topic: String) -> Meeting {
        Meeting(id: id, topic: topic, startTime: nil, isRecurring: false, joinURL: "https://zoom.us/j/\(id)")
    }

    // MARK: Parsing /users/me

    func testUsersMeGivesThePersonalRoom() {
        let room = ZoomPersonalRoom.parse(user: usersMe)
        XCTAssertEqual(room?.number, 3542471135)
        XCTAssertEqual(room?.joinURL, "https://us05web.zoom.us/j/3542471135?pwd=abc123")
        XCTAssertEqual(room?.hostName, "Jill Chill")
        XCTAssertEqual(room?.meetingNumber, "3542471135")
    }

    func testNameFallsBackToFirstAndLast() {
        var json = usersMe
        json["display_name"] = ""
        XCTAssertEqual(ZoomPersonalRoom.parse(user: json)?.hostName, "Jill Chill")
    }

    func testPmiAsAStringStillParses() {
        var json = usersMe
        json["pmi"] = "3542471135"
        XCTAssertEqual(ZoomPersonalRoom.parse(user: json)?.number, 3542471135)
    }

    /// Zoom sometimes answers 200 with pmi 0 and an empty URL (devforum 90526).
    func testPmiZeroOrMissingMeansNoRoom() {
        var zero = usersMe
        zero["pmi"] = 0
        zero["personal_meeting_url"] = ""
        XCTAssertNil(ZoomPersonalRoom.parse(user: zero))
        var missing = usersMe
        missing["pmi"] = nil
        XCTAssertNil(ZoomPersonalRoom.parse(user: missing))
    }

    func testAnEmptyURLFallsBackToTheZoomJoinLink() {
        var json = usersMe
        json["personal_meeting_url"] = ""
        XCTAssertEqual(ZoomPersonalRoom.parse(user: json)?.joinURL, "https://zoom.us/j/3542471135")
    }

    /// use_pmi only decides whether instant meetings use the PMI; the room is there either way.
    func testUsePmiDoesNotMatter() {
        var on = usersMe
        on["use_pmi"] = true
        XCTAssertEqual(ZoomPersonalRoom.parse(user: on), ZoomPersonalRoom.parse(user: usersMe))
    }

    func testLookupReadsA200Answer() throws {
        let body = try JSONSerialization.data(withJSONObject: usersMe)
        XCTAssertEqual(ZoomPersonalRoom.lookup(status: 200, body: body),
                       .room(ZoomPersonalRoom.parse(user: usersMe)!))
    }

    // MARK: List order

    func testThePersonalRoomIsPinnedFirst() {
        let room = ZoomPersonalRoom.parse(user: usersMe)!
        let entries = ScheduledListRules.entries(room: room, meetings: [meeting(111, "Monday"), meeting(222, "Friday")])
        XCTAssertEqual(entries.map(\.id), ["personal-room", "meeting-111", "meeting-222"])
        XCTAssertEqual(entries.first, .personalRoom(room))
    }

    func testWithoutARoomTheListIsTheScheduledMeetings() {
        let entries = ScheduledListRules.entries(room: nil, meetings: [meeting(111, "Monday")])
        XCTAssertEqual(entries, [.meeting(meeting(111, "Monday"))])
        XCTAssertEqual(ScheduledListRules.entries(room: ZoomPersonalRoom.parse(user: usersMe), meetings: []).count, 1)
    }

    func testTheChosenEntryFollowsTheMeetingNumber() {
        let room = ZoomPersonalRoom.parse(user: usersMe)!
        let entries = ScheduledListRules.entries(room: room, meetings: [meeting(111, "Monday")])
        XCTAssertEqual(ScheduledListRules.chosen(digits: "3542471135", in: entries), .personalRoom(room))
        XCTAssertEqual(ScheduledListRules.chosen(digits: "111", in: entries), .meeting(meeting(111, "Monday")))
        XCTAssertNil(ScheduledListRules.chosen(digits: "", in: entries))
        XCTAssertNil(ScheduledListRules.chosen(digits: "999", in: entries))
    }

    func testThePersonalRoomCannotBeEditedOrDeleted() {
        let room = ZoomPersonalRoom.parse(user: usersMe)!
        XCTAssertFalse(ScheduledEntry.personalRoom(room).canEdit)
        XCTAssertTrue(ScheduledEntry.meeting(meeting(111, "Monday")).canEdit)
    }

    func testStartSaysWhichRoom() {
        let room = ZoomPersonalRoom.parse(user: usersMe)!
        XCTAssertEqual(ScheduledListRules.startLine(digits: "3542471135", room: room),
                       "Starting your personal room as host\u{2026}")
        XCTAssertEqual(ScheduledListRules.startLine(digits: "111", room: room),
                       "Starting your scheduled meeting as host\u{2026}")
        XCTAssertEqual(ScheduledListRules.startLine(digits: "111", room: nil),
                       "Starting your scheduled meeting as host\u{2026}")
    }

    // MARK: Missing scope

    func testAMissingScopeMeansNoEntry() {
        let body = Data(#"{"code":4711,"message":"Invalid access token, does not contain scopes:[user:read:user:admin, user:read:user]."}"#.utf8)
        let lookup = ZoomPersonalRoom.lookup(status: 400, body: body)
        XCTAssertEqual(lookup, .missingScope)
        XCTAssertNil(lookup.room)
        XCTAssertEqual(ScheduledListRules.entries(room: lookup.room, meetings: [meeting(111, "Monday")]).map(\.id),
                       ["meeting-111"])
    }

    func testOtherFailuresAlsoMeanNoEntry() {
        let lookup = ZoomPersonalRoom.lookup(status: 500, body: Data(#"{"code":200,"message":"Internal error"}"#.utf8))
        XCTAssertEqual(lookup, .failed("Internal error"))
        XCTAssertNil(lookup.room)
    }

    func testTheCheckLineNamesTheMissingScopeWithItsFixes() {
        let scope = ZoomScopes.scope(.personalRoom)
        let line = ZoomScopeLineRules.line(scope, granted: ["meeting:read:list_meetings:admin"], ids: .init(s2sClientID: "abc123"))
        XCTAssertEqual(line.id, "personalRoom")
        XCTAssertEqual(line.title, "Permission to read your personal room")
        XCTAssertEqual(line.status, .failed)
        XCTAssertTrue(line.detail.contains("user:read:user:admin"))
        XCTAssertEqual(line.actions.map(\.action.title), ["Copy scope", "Open Scopes page", "Show me where"])
        XCTAssertEqual(line.actions.first?.action, .copyScope("user:read:user:admin"))
    }

    func testAGrantedScopeLinePasses() {
        let line = ZoomScopeLineRules.line(ZoomScopes.scope(.personalRoom), granted: ["user:read:user:admin"], ids: .init())
        XCTAssertEqual(line.status, .passed)
        XCTAssertTrue(line.actions.isEmpty)
        // A classic app's broad user read scope covers it too.
        XCTAssertEqual(ZoomScopeLineRules.line(ZoomScopes.scope(.personalRoom), granted: ["user:read:admin"], ids: .init()).status, .passed)
    }

    // MARK: The scope list

    func testTheScopeListHasThePersonalRoomScopeWithItsTitle() {
        let scope = ZoomScopes.scope(.personalRoom)
        XCTAssertEqual(scope.name, "user:read:user:admin")
        XCTAssertEqual(scope.purpose, "Read your personal room")
        XCTAssertEqual(scope.legacy, "user:read:admin")
        XCTAssertTrue(ZoomScopes.names.contains("user:read:user:admin"))
        XCTAssertEqual(ZoomScopes.countWord, "eight")
    }

    /// The signed-in route already asks for the user-level scope that covers GET /users/me.
    func testSignInAlreadyCoversUsersMe() {
        XCTAssertTrue(ZoomOAuth.requiredScopes.contains("user:read:user"))
    }

    // MARK: Formatting

    func testFormatsTheNumberLikeZoom() {
        XCTAssertEqual(ZoomPersonalRoom.spaced("3542471135"), "354 247 1135")
        XCTAssertEqual(ZoomPersonalRoom.spaced("97891943927"), "978 9194 3927")
        XCTAssertEqual(ZoomPersonalRoom.spaced("123456789"), "123 456 789")
        XCTAssertEqual(ZoomPersonalRoom.spaced("12345"), "12345")
        XCTAssertEqual(ZoomPersonalRoom.parse(user: usersMe)?.spacedNumber, "354 247 1135")
    }

    // MARK: Words

    func testWordsArePlain() {
        XCTAssertEqual(ZoomPersonalRoom.title, "Your personal room")
        XCTAssertEqual(ZoomPersonalRoom.note, "Always the same link")
        XCTAssertEqual(ZoomPersonalRoom.help,
                       "Your Zoom account\u{2019}s fixed meeting room. Anyone with the link can try to join while it\u{2019}s open, so keep the waiting room or a passcode on in Zoom.")
        let room = ZoomPersonalRoom.parse(user: usersMe)!
        XCTAssertEqual(ScheduledListRules.label(.personalRoom(room)), "Your personal room \u{2014} 354 247 1135")
        for text in [ZoomPersonalRoom.title, ZoomPersonalRoom.note, ZoomPersonalRoom.help,
                     ScheduledListRules.startLine(digits: "3542471135", room: room)] {
            XCTAssertFalse(text.lowercased().contains("class"), text)
        }
    }
}
