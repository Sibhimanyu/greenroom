//
//  SessionsQuery.swift
//
//  The Sessions grid's values and its filter, count, sort and week grouping as
//  plain Swift, with no SwiftUI view in it, so the sidebar badges, the Status
//  menu counts and the cards cannot disagree and the logic can be unit tested
//  (Tests/SessionsQueryTests.swift compiles this file on its own).
//
import Foundation

// MARK: - Values

/// What made a session. Read from session.json's `kind` by RecordingsView.
/// `.review` is the case name for folders the old presentation window made
/// (kind "screen" on disk): they still list, play and analyse, and are
/// labelled Presentation. Nothing writes that kind any more.
enum SessionKind: String, CaseIterable, Hashable {
    case classSession, recording, review

    var label: String {
        switch self {
        case .classSession: return "Meeting"
        case .recording: return "Recording"
        case .review: return "Presentation"
        }
    }

    var symbol: String {
        switch self {
        case .classSession: return "person.2"
        case .recording: return "record.circle"
        case .review: return "list.bullet.rectangle"
        }
    }
}

/// One card in the grid.
struct SessionCardModel: Identifiable, Hashable {
    let id: String
    var title: String
    var kind: SessionKind
    var date: Date
    /// Seconds, once the recording has been measured. Nil until then, and for
    /// a session with no recording at all.
    var duration: Double?
    var isUploaded: Bool
    var isAnalysed: Bool
    // What the list says is left to do. The host (RecordingsView) does not
    // know these; SessionsIndex reads them from the folder and merges them in
    // (SessionsIndex.enrich), so the defaults mean "not known yet".
    /// The folder holds a recording that could be shared.
    var hasVideo = false
    /// Clips plus notes: the marks drawn on the session's timeline.
    var momentCount = 0
    /// "unlisted", "public"... of the last upload, when there is one.
    var uploadPrivacy: String?
    /// A transcript with at least one spoken line exists, so a search can
    /// look inside this class.
    var hasTranscript = false
}

/// One thing still to do (or already done) about a session, drawn as a chip.
struct SessionChip: Identifiable, Hashable {
    enum Tone { case plain, amber, green }
    let id: String
    var text: String
    var symbol: String?
    var tone: Tone
}

/// The sidebar's NEEDS YOU group: sessions with something left to do.
enum SessionsNeed: String, CaseIterable, Identifiable {
    case notShared = "Not shared yet"
    case feedbackReady = "Feedback ready"
    var id: String { rawValue }

    func matches(_ card: SessionCardModel) -> Bool {
        switch self {
        case .notShared: return card.hasVideo && !card.isUploaded
        case .feedbackReady: return card.isAnalysed
        }
    }

    var symbol: String {
        switch self {
        case .notShared: return "square.and.arrow.up"
        case .feedbackReady: return "sparkles"
        }
    }
}

enum SessionChips {
    /// Amber "Not shared" or "On YouTube \u{00B7} Unlisted" (amber because
    /// both are about what leaves the Mac), the moment count, and green
    /// "Feedback ready". Empty for a session with nothing to say.
    static func chips(for card: SessionCardModel) -> [SessionChip] {
        var out: [SessionChip] = []
        if card.isUploaded {
            let privacy = card.uploadPrivacy.map { " \u{00B7} " + $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
            out.append(.init(id: "yt", text: "On YouTube" + privacy, symbol: "play.rectangle.fill", tone: .amber))
        } else if card.hasVideo {
            out.append(.init(id: "share", text: "Not shared", symbol: nil, tone: .amber))
        }
        if card.momentCount > 0 {
            out.append(.init(id: "moments",
                             text: card.momentCount == 1 ? "1 note" : "\(card.momentCount) notes",
                             symbol: "flag", tone: .plain))
        }
        if card.isAnalysed {
            out.append(.init(id: "feedback", text: "Feedback ready", symbol: "sparkles", tone: .green))
        }
        return out
    }
}

// MARK: - What was said

/// One sentence of a class that matches the search, and when it was said.
struct TranscriptHit: Identifiable, Hashable {
    let sessionID: String
    let seconds: Double
    /// "0:12:40", as written in transcript.txt.
    let stamp: String
    let text: String
    var id: String { "\(sessionID)@\(stamp)#\(text.hashValue)" }

    /// "12:40", or "1:02:05" past the hour.
    var clock: String {
        let t = Int(seconds)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}

enum TranscriptSearch {
    /// "h:mm:ss" (or "m:ss") to seconds; nil when it is not a time.
    static func seconds(from stamp: String) -> Double? {
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        guard parts.count == stamp.split(separator: ":").count, (1...3).contains(parts.count) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// The lines of one class that contain every word of the query, in the
    /// order they were said. Case and accents are ignored.
    static func hits(sessionID: String, lines: [(stamp: String, text: String)], query: String) -> [TranscriptHit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return lines.compactMap { line in
            guard words.allSatisfy({ line.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }),
                  let at = seconds(from: line.stamp) else { return nil }
            return TranscriptHit(sessionID: sessionID, seconds: at, stamp: line.stamp, text: line.text)
        }
    }
}

/// Said once so the pending "open at this time" has one reader. The list
/// writes it when a transcript result is clicked, then opens the session; the
/// session's page takes it (once) and seeks.
@MainActor
final class SessionsPendingSeek {
    static let shared = SessionsPendingSeek()
    private(set) var request: (sessionID: String, seconds: Double)?
    func set(_ id: String, seconds: Double) { request = (id, seconds) }
    /// Returns the time for this session and forgets it.
    func take(for id: String) -> Double? {
        guard let request, request.sessionID == id else { return nil }
        self.request = nil
        return request.seconds
    }
}

/// The sidebar's SHOW group: one kind, or all of them.
enum SessionsShow: String, CaseIterable, Identifiable {
    case everything = "Everything"
    case classes = "Meetings"
    case recordings = "Recordings"
    case reviews = "Presentations"
    var id: String { rawValue }

    var kind: SessionKind? {
        switch self {
        case .everything: return nil
        case .classes: return .classSession
        case .recordings: return .recording
        case .reviews: return .review
        }
    }

    var symbol: String {
        switch self {
        case .everything: return "square.grid.2x2"
        case .classes: return SessionKind.classSession.symbol
        case .recordings: return SessionKind.recording.symbol
        case .reviews: return SessionKind.review.symbol
        }
    }

    var emptyLine: String {
        switch self {
        case .everything: return "Nothing recorded yet"
        case .classes: return "No meetings yet"
        case .recordings: return "No recordings yet"
        case .reviews: return "No presentations yet"
        }
    }
}

/// The sidebar's STATUS group. At most one at a time; clicking the chosen
/// one again clears it.
enum SessionsStatus: String, CaseIterable, Identifiable {
    case notUploaded = "Not uploaded"
    case onYouTube = "On YouTube"
    case analysed = "Report ready"
    var id: String { rawValue }

    func matches(_ card: SessionCardModel) -> Bool {
        switch self {
        case .notUploaded: return !card.isUploaded
        case .onYouTube: return card.isUploaded
        case .analysed: return card.isAnalysed
        }
    }

    var symbol: String {
        switch self {
        case .notUploaded: return "icloud.slash"
        case .onYouTube: return "play.rectangle.fill"
        case .analysed: return "sparkles"
        }
    }
}

enum SessionsSort: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    var id: String { rawValue }
}

/// Words for dates and lengths, shared by the cards and the inspector.
enum SessionsFormat {

    /// "Today", "Yesterday", a weekday inside the week, then a date.
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7, days >= 0 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "Today" / "Monday 16 November", "Friday" / "13 November", then
    /// "12 November" / "2025" for anything older than a week.
    static func dayHeading(_ date: Date, now: Date, calendar: Calendar = .current) -> (title: String, subtitle: String) {
        let full = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let short = date.formatted(.dateTime.day().month(.wide))
        if calendar.isDate(date, inSameDayAs: now) { return ("Today", full) }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return ("Yesterday", short)
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day, days >= 0, days < 7 {
            return (date.formatted(.dateTime.weekday(.wide)), short)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? short : date.formatted(.dateTime.day().month(.wide).year()), date.formatted(.dateTime.weekday(.wide)))
    }

    /// "42:18", "1:02:05": a length as a clock, for the badge on a picture.
    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "48 min", "1 h 12 min", "under a minute".
    static func length(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The heading a card is filed under: this week, last week, then the
    /// Monday that started the week.
    static func week(_ date: Date, now: Date, calendar: Calendar = .current) -> (key: Date, title: String) {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        if start == thisWeek { return (start, "This week") }
        if let last = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek), start == last {
            return (start, "Last week")
        }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
        let label = sameYear
            ? start.formatted(.dateTime.day().month(.wide))
            : start.formatted(.dateTime.day().month(.wide).year())
        return (start, "Week of \(label)")
    }
}

// MARK: - Query

/// The grid's filter, count, sort and week grouping as plain values, so the
/// sidebar badges, the Status menu counts and the cards can never disagree
/// (Tests/SessionsQueryTests.swift).
struct SessionsQuery {
    var cards: [SessionCardModel]
    var show: SessionsShow = .everything
    var status: SessionsStatus?
    /// The sidebar's NEEDS YOU choice.
    var need: SessionsNeed?
    var search: String = ""
    /// Sessions whose transcript matches `search`, by session id.
    var transcriptHits: [String: [TranscriptHit]] = [:]
    var sort: SessionsSort = .newest
    var now = Date()
    var calendar: Calendar = .current

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespaces) }

    var isSearching: Bool { !trimmedSearch.isEmpty }
    /// A search or a status is narrowing the grid (the Show choice is not a filter).
    var isFiltering: Bool { isSearching || status != nil || need != nil }

    private func matchesSearch(_ card: SessionCardModel) -> Bool {
        let query = trimmedSearch
        guard !query.isEmpty else { return true }
        return card.title.localizedCaseInsensitiveContains(query)
            || card.kind.label.localizedCaseInsensitiveContains(query)
            || !(transcriptHits[card.id] ?? []).isEmpty
    }

    /// Searched and of the kind being shown, before the status filter: what
    /// the Status counts are counted over.
    var ofKind: [SessionCardModel] {
        cards.filter { card in
            (show.kind == nil || card.kind == show.kind) && matchesSearch(card)
        }
    }

    var visible: [SessionCardModel] {
        let filtered = ofKind.filter { (status?.matches($0) ?? true) && (need?.matches($0) ?? true) }
        return filtered.sorted { sort == .newest ? $0.date > $1.date : $0.date < $1.date }
    }

    /// The sidebar badge: every session of that kind, whatever is searched.
    func count(for option: SessionsShow) -> Int {
        cards.filter { option.kind == nil || $0.kind == option.kind }.count
    }

    /// The sidebar's Needs you badge: over every session, whatever is searched.
    func count(for option: SessionsNeed) -> Int {
        cards.filter(option.matches).count
    }

    /// The Status menu count.
    func count(for option: SessionsStatus) -> Int {
        ofKind.filter(option.matches).count
    }

    var groups: [(title: String, cards: [SessionCardModel])] {
        var out: [(key: Date, title: String, cards: [SessionCardModel])] = []
        for card in visible {
            let week = SessionsFormat.week(card.date, now: now, calendar: calendar)
            if let index = out.firstIndex(where: { $0.key == week.key }) {
                out[index].cards.append(card)
            } else {
                out.append((week.key, week.title, [card]))
            }
        }
        return out.map { ($0.title, $0.cards) }
    }

    /// Visible sessions under a heading per calendar day, in sort order.
    var dayGroups: [(day: Date, title: String, subtitle: String, cards: [SessionCardModel])] {
        var out: [(day: Date, title: String, subtitle: String, cards: [SessionCardModel])] = []
        for card in visible {
            let start = calendar.startOfDay(for: card.date)
            if let index = out.firstIndex(where: { $0.day == start }) {
                out[index].cards.append(card)
            } else {
                let h = SessionsFormat.dayHeading(card.date, now: now, calendar: calendar)
                out.append((start, h.title, h.subtitle, [card]))
            }
        }
        return out
    }

    /// The window subtitle: what the grid shows, and how many.
    var subtitle: String {
        var parts = [show.rawValue]
        if let status { parts.append(status.rawValue) }
        if let need { parts.append(need.rawValue) }
        let n = visible.count
        parts.append(n == 1 ? "1 session" : "\(n) sessions")
        return parts.joined(separator: " \u{00B7} ")
    }
}

