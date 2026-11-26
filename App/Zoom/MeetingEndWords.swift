//
//  MeetingEndWords.swift
//  Greenroom
//
//  Zoom ended a live meeting that the owner did not end: one plain line for the
//  island, from what the SDK said (meeting status Ended or Failed, its
//  ZoomSDKMeetingError and its EndMeetingReason, by raw value). No line when the
//  owner ended it (End, Leave, quit all go through `leave()`).
//
//  Pure: Foundation only, no ZoomSDK import (the test target compiles it).
//
import Foundation

/// How a meeting ended, as Zoom reported it, in plain values.
struct MeetingEnd: Equatable {
    /// The status was Failed (else Ended).
    var failed: Bool
    /// `ZoomSDKMeetingError` raw value.
    var error: Int
    /// `EndMeetingReason` raw value.
    var reason: Int
    /// The owner asked for it: End, Leave or quit called `leave()` first.
    var byOwner: Bool
}

enum MeetingEndWords {
    /// The island's line, or nil when there is nothing to tell (the owner ended it).
    static func line(for end: MeetingEnd) -> String? {
        guard !end.byOwner else { return nil }
        if let why = reasons[end.reason] { return "Zoom ended the meeting: \(why)" }
        if end.reason != 0 { return "Zoom ended the meeting (reason \(end.reason))" }
        if let why = errors[end.error] { return "Zoom ended the meeting: \(why)" }
        // 0 is Success and 101 is "none given": nothing more to say.
        let nothingSaid = end.error == 0 || end.error == 101
        if nothingSaid { return end.failed ? "Zoom ended the meeting: \(dropped)" : "Zoom ended the meeting (reason 0)" }
        return "Zoom ended the meeting (error \(end.error))"
    }

    private static let dropped = "the connection dropped"

    /// `EndMeetingReason` (7 is Undefined: said by number).
    private static let reasons: [Int: String] = [
        1: "removed by the host",                  // KickByHost
        2: "the host ended it",                    // EndByHost
        3: "the host did not join in time",        // JBHTimeOut
        4: "nobody joined",                        // NoAttendee
        5: "the host started another meeting",     // HostStartAnotherMeeting
        6: "the time limit was reached",           // FreeMeetingTimeOut
        8: "the signed-in account left it",        // DueToAuthorizedUserLeave
    ]

    /// `ZoomSDKMeetingError`, the ones that end a live meeting.
    private static let errors: [Int: String] = [
        1: dropped,                                // ConnectionError
        2: dropped,                                // ReconnectFailed
        5: dropped,                                // SessionError
        6: "the meeting is over",                  // MeetingOver
        16: "the host key expired",                // StartTokenExpired
        61: "removed by the host",                 // RemovedByHost
        64: "blocked by the account admin",        // BlockedByAccountAdmin
    ]
}
