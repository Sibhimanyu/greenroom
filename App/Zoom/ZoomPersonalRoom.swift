//
//  ZoomPersonalRoom.swift
//  Greenroom
//
//  The account's Zoom Personal Meeting Room (PMI) and its place on Home's
//  Scheduled list (owner, 2026-11-27). Zoom's scheduled-meetings list never
//  includes it, so it is read from GET /users/me (`pmi`, `personal_meeting_url`,
//  `display_name`) and pinned first. Starting it is the same as any scheduled
//  meeting: the PMI number with a fresh ZAK. The host needs no passcode and
//  skips the waiting room, so nothing special happens at Start. It is the
//  account's room, so Greenroom never edits or deletes it.
//
//  Scopes: GET /users/{userId} takes `user:read:user:admin` (Server-to-Server,
//  in ZoomScopes) or `user:read:user` (the sign-in, already in
//  ZoomOAuth.requiredScopes); classic apps grant `user:read:admin`. Without
//  the scope the list simply has no entry; Check Zoom setup names the scope.
//
//  Pure: Foundation only, compiled by the tests.
//
import Foundation

struct ZoomPersonalRoom: Equatable, Hashable {
    /// The PMI.
    let number: Int64
    /// `personal_meeting_url`; Zoom's plain join link when that is empty.
    let joinURL: String
    /// The account's display name (first and last name when it is empty).
    let hostName: String

    var meetingNumber: String { String(number) }
    var spacedNumber: String { Self.spaced(meetingNumber) }

    static let title = "Your personal room"
    static let note = "Always the same link"
    static let help = "Your Zoom account\u{2019}s fixed meeting room. Anyone with the link can try to join while it\u{2019}s open, so keep the waiting room or a passcode on in Zoom."

    /// What GET /users/me said about the room.
    enum Lookup: Equatable {
        case room(ZoomPersonalRoom)
        /// Answered, but no PMI (Zoom sometimes sends pmi 0).
        case noRoom
        /// The token lacks the scope: no entry; Check Zoom setup names it.
        case missingScope
        case failed(String)

        var room: ZoomPersonalRoom? {
            if case .room(let room) = self { return room }
            return nil
        }
    }

    /// The room from a GET /users/me body. `use_pmi` is not read: it only says
    /// whether instant meetings use the PMI; the room exists either way.
    static func parse(user json: [String: Any]) -> ZoomPersonalRoom? {
        let number: Int64?
        switch json["pmi"] {
        case let n as Int64: number = n
        case let n as Int: number = Int64(n)
        case let n as NSNumber: number = n.int64Value
        case let s as String: number = Int64(s.filter(\.isNumber))
        default: number = nil
        }
        guard let number, number > 0 else { return nil }
        let url = (json["personal_meeting_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://zoom.us/j/\(number)"
        let first = json["first_name"] as? String ?? ""
        let last = json["last_name"] as? String ?? ""
        let name = (json["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        return ZoomPersonalRoom(number: number, joinURL: url, hostName: name)
    }

    /// One HTTP answer from GET /users/me, as the list needs it.
    static func lookup(status: Int, body: Data) -> Lookup {
        let text = String(decoding: body, as: UTF8.self)
        guard (200...299).contains(status) else {
            if text.contains("scopes") { return .missingScope }
            return .failed(ZoomServerToServerError.plainMessage(text))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .failed("Zoom\u{2019}s answer wasn\u{2019}t a user.")
        }
        return parse(user: json).map(Lookup.room) ?? .noRoom
    }

    /// The number as Zoom writes it: 354 247 1135 (10 digits), 978 9194 3927 (11), 123 456 789 (9).
    static func spaced(_ number: String) -> String {
        let d = Array(number.filter(\.isNumber))
        let groups: [Int]
        switch d.count {
        case 9: groups = [3, 3, 3]
        case 10: groups = [3, 3, 4]
        case 11: groups = [3, 4, 4]
        default:
            guard d.count > 11 else { return number }
            groups = [3, 4, d.count - 7]
        }
        var out: [String] = [], at = 0
        for g in groups { out.append(String(d[at..<at + g])); at += g }
        return out.joined(separator: " ")
    }
}

/// One line of Home's Scheduled list.
enum ScheduledEntry: Identifiable, Equatable, Hashable {
    case personalRoom(ZoomPersonalRoom)
    case meeting(ZoomServerToServerClient.ScheduledMeeting)

    var id: String {
        switch self {
        case .personalRoom: return "personal-room"
        case .meeting(let m): return "meeting-\(m.id)"
        }
    }

    /// The personal room is the account's: no Edit, so no Delete either.
    var canEdit: Bool {
        if case .meeting = self { return true }
        return false
    }
}

enum ScheduledListRules {
    /// The personal room pinned first, then the scheduled meetings in Zoom's order.
    static func entries(room: ZoomPersonalRoom?,
                        meetings: [ZoomServerToServerClient.ScheduledMeeting]) -> [ScheduledEntry] {
        (room.map { [.personalRoom($0)] } ?? []) + meetings.map(ScheduledEntry.meeting)
    }

    /// Which entry the meeting number in the field is: the room by its PMI,
    /// a scheduled meeting by its ID.
    static func chosen(digits: String, in entries: [ScheduledEntry]) -> ScheduledEntry? {
        guard !digits.isEmpty else { return nil }
        return entries.first { entry in
            switch entry {
            case .personalRoom(let room): return room.meetingNumber == digits
            case .meeting(let m): return String(m.id) == digits
            }
        }
    }

    /// The session log's line as Start asks Zoom for the host key.
    static func startLine(digits: String, room: ZoomPersonalRoom?) -> String {
        room?.meetingNumber == digits && !digits.isEmpty
            ? "Starting your personal room as host\u{2026}"
            : "Starting your scheduled meeting as host\u{2026}"
    }

    /// The picker's words. Recurring meetings' times come from the per-meeting
    /// details call (their real next occurrence), never from the list endpoint,
    /// whose recurring timestamps are the series' original anchor. No time means
    /// "no fixed time", no upcoming occurrence, or a missing details scope.
    static func label(_ entry: ScheduledEntry) -> String {
        switch entry {
        case .personalRoom(let room):
            return "\(ZoomPersonalRoom.title) \u{2014} \(room.spacedNumber)"
        case .meeting(let meeting):
            let when = meeting.startTime?.formatted(
                .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            switch (meeting.isRecurring, when) {
            case (true, let when?): return "\(meeting.topic) \u{2014} recurring, next \(when)"
            case (true, nil): return "\(meeting.topic) \u{2014} recurring"
            case (false, let when?): return "\(meeting.topic) \u{2014} \(when)"
            case (false, nil): return meeting.topic
            }
        }
    }
}

/// One scope's line in Check Zoom setup (your own Zoom apps).
enum ZoomScopeLineRules {
    static func line(_ scope: ZoomScopes.Scope, granted: Set<String>, ids: ZoomCheckActionContext) -> ZoomCheckLine {
        let ok = ZoomScopes.isGranted(scope, in: granted)
        let status: ZoomCheckStatus = ok ? .passed : .failed
        var line = ZoomCheckLine(id: scope.key.rawValue, title: scope.checkTitle, status: status,
                                 detail: ok ? "Granted by Zoom."
                                    : "Missing \(scope.name). Add it in the Server-to-Server app\u{2019}s Scopes page, save, and check again.")
        line.actions = ZoomCheckActionRules.buttons(.ownApps, check: line.id, status: status,
                                                    problem: ok ? .nothing : .missingScopes([scope.name]), ids: ids)
        return line
    }
}
