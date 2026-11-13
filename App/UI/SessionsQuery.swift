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
        case .classSession: return "Class"
        case .recording: return "Recording"
        case .review: return "Presentation"
        }
    }

    var symbol: String {
        switch self {
        case .classSession: return "person.3.fill"
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
}

/// The sidebar's SHOW group: one kind, or all of them.
enum SessionsShow: String, CaseIterable, Identifiable {
    case everything = "Everything"
    case classes = "Classes"
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
        case .classes: return "No classes yet"
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
    case analysed = "Analysed"
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
    var search: String = ""
    var sort: SessionsSort = .newest
    var now = Date()
    var calendar: Calendar = .current

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespaces) }

    var isSearching: Bool { !trimmedSearch.isEmpty }
    /// A search or a status is narrowing the grid (the Show choice is not a filter).
    var isFiltering: Bool { isSearching || status != nil }

    private func matchesSearch(_ card: SessionCardModel) -> Bool {
        let query = trimmedSearch
        guard !query.isEmpty else { return true }
        return card.title.localizedCaseInsensitiveContains(query)
            || card.kind.label.localizedCaseInsensitiveContains(query)
    }

    /// Searched and of the kind being shown, before the status filter: what
    /// the Status counts are counted over.
    var ofKind: [SessionCardModel] {
        cards.filter { card in
            (show.kind == nil || card.kind == show.kind) && matchesSearch(card)
        }
    }

    var visible: [SessionCardModel] {
        let filtered = ofKind.filter { status?.matches($0) ?? true }
        return filtered.sorted { sort == .newest ? $0.date > $1.date : $0.date < $1.date }
    }

    /// The sidebar badge: every session of that kind, whatever is searched.
    func count(for option: SessionsShow) -> Int {
        cards.filter { option.kind == nil || $0.kind == option.kind }.count
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

    /// The window subtitle: what the grid shows, and how many.
    var subtitle: String {
        var parts = [show.rawValue]
        if let status { parts.append(status.rawValue) }
        let n = visible.count
        parts.append(n == 1 ? "1 session" : "\(n) sessions")
        return parts.joined(separator: " \u{00B7} ")
    }
}

