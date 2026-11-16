//
//  NewMeetingRequest.swift
//  Greenroom
//
//  The pure part of "New scheduled meeting": what the person chose, and the
//  JSON body Zoom's create-meeting call wants for it. No network, so it is
//  unit-tested (Tests/NewMeetingRequestTests.swift).
//
import Foundation

struct NewMeetingRequest: Equatable {
    var name: String
    /// false = "No fixed time" (Zoom type 3); true = weekly (type 8).
    var weekly = false
    /// Zoom's numbering: 1 = Sunday ... 7 = Saturday.
    var days: Set<Int> = []
    var hour = 9
    var minute = 0
    var durationMinutes = 60
    /// true = no waiting room.
    var studentsJoinDirectly = true

    /// Mon..Sun in the order the sheet draws them, with Zoom's numbers.
    static let weekdays: [(label: String, zoom: Int)] = [
        ("Mon", 2), ("Tue", 3), ("Wed", 4), ("Thu", 5), ("Fri", 6), ("Sat", 7), ("Sun", 1),
    ]

    /// Zoom ends a series after at most 60 occurrences; 50 stays inside that.
    static let endTimes = 50

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValid: Bool {
        guard !trimmedName.isEmpty else { return false }
        return weekly ? (!days.isEmpty && durationMinutes > 0) : true
    }

    /// The next moment, strictly after `now`, that falls on one of `days` at
    /// hour:minute in the calendar's time zone. Today counts only if that
    /// time has not passed yet.
    static func nextStart(days: Set<Int>, hour: Int, minute: Int,
                          after now: Date, calendar: Calendar) -> Date? {
        guard !days.isEmpty else { return nil }
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  days.contains(calendar.component(.weekday, from: day)),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  candidate > now else { continue }
            return candidate
        }
        return nil
    }

    /// The POST /users/me/meetings body.
    func body(now: Date = Date(), calendar: Calendar = .current) -> [String: Any] {
        let settings: [String: Any] = [
            "waiting_room": !studentsJoinDirectly,
            "join_before_host": false,
        ]
        var out: [String: Any] = ["topic": trimmedName]
        if weekly,
           let start = Self.nextStart(days: days, hour: hour, minute: minute, after: now, calendar: calendar) {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            out["type"] = 8
            out["start_time"] = f.string(from: start)
            out["timezone"] = calendar.timeZone.identifier
            out["duration"] = durationMinutes
            out["recurrence"] = [
                "type": 2,
                "repeat_interval": 1,
                "weekly_days": days.sorted().map(String.init).joined(separator: ","),
                "end_times": Self.endTimes,
            ] as [String: Any]
        } else {
            out["type"] = 3
        }
        out["settings"] = settings
        return out
    }

    /// Reads Zoom's GET /meetings/{id} answer back into what the sheet edits.
    /// Type 8 is weekly; anything else is "No fixed time". The start time
    /// (UTC from Zoom) is shown in the calendar's zone, snapped to the
    /// nearest quarter hour, as the sheet's Time menu only offers quarters.
    static func parse(_ json: [String: Any], calendar: Calendar = .current) -> NewMeetingRequest {
        var r = NewMeetingRequest(name: json["topic"] as? String ?? "")
        let settings = json["settings"] as? [String: Any]
        r.studentsJoinDirectly = !((settings?["waiting_room"] as? Bool) ?? false)
        guard (json["type"] as? Int) == 8 else { return r }
        r.weekly = true
        if let list = (json["recurrence"] as? [String: Any])?["weekly_days"] as? String {
            r.days = Set(list.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }.filter { (1...7).contains($0) })
        }
        if let text = json["start_time"] as? String, let date = parseDate(text, calendar: calendar) {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            let snapped = Int((Double((c.hour ?? 9) * 60 + (c.minute ?? 0)) / 15).rounded()) * 15 % (24 * 60)
            r.hour = snapped / 60
            r.minute = snapped % 60
        }
        if let d = json["duration"] as? Int, d > 0 { r.durationMinutes = d }
        return r
    }

    private static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: text)
    }
}
