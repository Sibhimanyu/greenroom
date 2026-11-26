//
//  MeetingEndWordsTests.swift
//  GreenroomTests
//
//  Zoom ending a live meeting the owner did not end: the island's one line per
//  end reason and error (raw values from ZoomSDKErrors.h), and silence when the
//  owner ended it.
//
import XCTest

final class MeetingEndWordsTests: XCTestCase {

    private func line(failed: Bool = false, error: Int = 0, reason: Int = 0, byOwner: Bool = false) -> String? {
        MeetingEndWords.line(for: MeetingEnd(failed: failed, error: error, reason: reason, byOwner: byOwner))
    }

    func testEveryEndReasonInPlainWords() {
        // EndMeetingReason, ZoomSDKErrors.h
        let table: [(reason: Int, line: String)] = [
            (1, "Zoom ended the meeting: removed by the host"),                 // KickByHost
            (2, "Zoom ended the meeting: the host ended it"),                   // EndByHost
            (3, "Zoom ended the meeting: the host did not join in time"),       // JBHTimeOut
            (4, "Zoom ended the meeting: nobody joined"),                       // NoAttendee
            (5, "Zoom ended the meeting: the host started another meeting"),    // HostStartAnotherMeeting
            (6, "Zoom ended the meeting: the time limit was reached"),          // FreeMeetingTimeOut
            (8, "Zoom ended the meeting: the signed-in account left it"),       // DueToAuthorizedUserLeave
            (7, "Zoom ended the meeting (reason 7)"),                           // Undefined
            (42, "Zoom ended the meeting (reason 42)"),
        ]
        for row in table {
            XCTAssertEqual(line(reason: row.reason), row.line, "reason \(row.reason)")
        }
    }

    func testWithNoReasonTheErrorSpeaks() {
        // ZoomSDKMeetingError, ZoomSDKErrors.h
        let table: [(error: Int, line: String)] = [
            (1, "Zoom ended the meeting: the connection dropped"),              // ConnectionError
            (2, "Zoom ended the meeting: the connection dropped"),              // ReconnectFailed
            (5, "Zoom ended the meeting: the connection dropped"),              // SessionError
            (6, "Zoom ended the meeting: the meeting is over"),                 // MeetingOver
            (16, "Zoom ended the meeting: the host key expired"),               // StartTokenExpired
            (61, "Zoom ended the meeting: removed by the host"),                // RemovedByHost
            (64, "Zoom ended the meeting: blocked by the account admin"),       // BlockedByAccountAdmin
            (77, "Zoom ended the meeting (error 77)"),
        ]
        for row in table {
            XCTAssertEqual(line(failed: true, error: row.error), row.line, "error \(row.error)")
        }
    }

    func testTheReasonWinsOverTheError() {
        XCTAssertEqual(line(error: 1, reason: 6), "Zoom ended the meeting: the time limit was reached")
    }

    func testNothingSaidIsReasonZero() {
        // Ended with no reason and no error (0, or 101 "none given").
        XCTAssertEqual(line(), "Zoom ended the meeting (reason 0)")
        XCTAssertEqual(line(error: 101), "Zoom ended the meeting (reason 0)")
        XCTAssertEqual(line(failed: true), "Zoom ended the meeting: the connection dropped",
                       "a Failed status with nothing more is the connection going")
    }

    func testNoLineWhenTheOwnerEndedIt() {
        // End, Leave and quit all call leave() first; Zoom then reports EndByHost.
        XCTAssertNil(line(reason: 2, byOwner: true))
        XCTAssertNil(line(failed: true, error: 1, byOwner: true))
        XCTAssertNil(line(byOwner: true))
    }
}
