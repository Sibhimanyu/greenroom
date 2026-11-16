import XCTest


/// The Sessions grid's filter, count, sort and week grouping (SessionsQuery).
final class SessionsQueryTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    /// Thursday 12 Nov 2026, noon UTC.
    private let now = Date(timeIntervalSince1970: 1_794_484_800)

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: now)!
    }

    private func card(_ id: String, _ title: String, _ kind: SessionKind, daysAgo: Int,
                      uploaded: Bool = false, analysed: Bool = false) -> SessionCardModel {
        SessionCardModel(id: id, title: title, kind: kind, date: day(daysAgo), duration: 600,
                         isUploaded: uploaded, isAnalysed: analysed)
    }

    private var cards: [SessionCardModel] {
        [
            card("a", "Monday class", .classSession, daysAgo: 3, uploaded: true),
            card("b", "Demo", .recording, daysAgo: 1, analysed: true),
            card("c", "Talk review", .review, daysAgo: 10),
            card("d", "Tuesday class", .classSession, daysAgo: 2, uploaded: true, analysed: true),
        ]
    }

    private func query(show: SessionsShow = .everything, status: SessionsStatus? = nil,
                       search: String = "", sort: SessionsSort = .newest) -> SessionsQuery {
        SessionsQuery(cards: cards, show: show, status: status, search: search, sort: sort,
                      now: now, calendar: calendar)
    }

    func testEverythingShowsAllNewestFirst() {
        XCTAssertEqual(query().visible.map(\.id), ["b", "d", "a", "c"])
    }

    func testOldestFirstReverses() {
        XCTAssertEqual(query(sort: .oldest).visible.map(\.id), ["c", "a", "d", "b"])
    }

    func testShowNarrowsByKind() {
        XCTAssertEqual(query(show: .classes).visible.map(\.id), ["d", "a"])
        XCTAssertEqual(query(show: .reviews).visible.map(\.id), ["c"])
    }

    func testStatusFilters() {
        XCTAssertEqual(query(status: .onYouTube).visible.map(\.id), ["d", "a"])
        XCTAssertEqual(query(status: .notUploaded).visible.map(\.id), ["b", "c"])
        XCTAssertEqual(query(status: .analysed).visible.map(\.id), ["b", "d"])
    }

    func testSearchMatchesTitleAndKindCaseInsensitively() {
        XCTAssertEqual(query(search: "  monday ").visible.map(\.id), ["a"])
        XCTAssertEqual(query(search: "presentation").visible.map(\.id), ["c"])
        XCTAssertTrue(query(search: "zzz").visible.isEmpty)
    }

    func testShowCountsIgnoreSearchAndStatus() {
        let q = query(show: .recordings, status: .analysed, search: "demo")
        XCTAssertEqual(q.count(for: .everything), 4)
        XCTAssertEqual(q.count(for: .classes), 2)
        XCTAssertEqual(q.count(for: .reviews), 1)
    }

    func testStatusCountsFollowKindAndSearchButNotStatus() {
        let q = query(show: .classes, status: .analysed)
        XCTAssertEqual(q.count(for: .onYouTube), 2)
        XCTAssertEqual(q.count(for: .notUploaded), 0)
        XCTAssertEqual(q.count(for: .analysed), 1)
        XCTAssertEqual(query(search: "demo").count(for: .analysed), 1)
    }

    func testCountsMatchVisibleRowsWhenFilterIsApplied() {
        for status in SessionsStatus.allCases {
            XCTAssertEqual(query(status: status).visible.count, query().count(for: status))
        }
    }

    func testGroupsByWeekWithSentenceCaseTitles() {
        let groups = query().groups
        XCTAssertEqual(groups.map(\.title).first, "This week")
        XCTAssertEqual(groups.map(\.cards.count).reduce(0, +), 4)
        XCTAssertTrue(groups.contains { $0.title == "Last week" })
        XCTAssertFalse(groups.contains { $0.title == $0.title.uppercased() })
    }

    func testFilterSummaryAndActive() {
        XCTAssertFalse(query().isFiltering)
        XCTAssertTrue(query(status: .analysed).isFiltering)
        XCTAssertTrue(query(search: "x").isFiltering)
    }
}

/// Status chips, day headings and transcript search (SessionsQuery.swift).
final class SessionsTimelineTests: XCTestCase {
    func testChipsSayWhatIsLeft() {
        var c = SessionCardModel(id: "a", title: "A", kind: .classSession, date: Date(), duration: 60,
                                 isUploaded: false, isAnalysed: false)
        XCTAssertTrue(SessionChips.chips(for: c).isEmpty)
        c.hasVideo = true; c.momentCount = 3; c.isAnalysed = true
        XCTAssertEqual(SessionChips.chips(for: c).map(\.text), ["Not shared", "3 moments", "Feedback ready"])
        c.isUploaded = true; c.uploadPrivacy = "unlisted"
        XCTAssertEqual(SessionChips.chips(for: c).first?.text, "On YouTube \u{00B7} Unlisted")
        XCTAssertFalse(SessionsNeed.notShared.matches(c))
    }

    func testTranscriptSearchFindsSentenceAndTime() {
        let lines = [("0:00:05", "Welcome back everyone"), ("0:12:40", "Jonas receives the memory"), ("1:02:05", "jonas again")]
        let hits = TranscriptSearch.hits(sessionID: "s", lines: lines, query: "JONAS")
        XCTAssertEqual(hits.map(\.seconds), [760, 3725])
        XCTAssertEqual(hits.first?.clock, "12:40")
        XCTAssertTrue(TranscriptSearch.hits(sessionID: "s", lines: lines, query: "  ").isEmpty)
    }

    func testSearchKeepsSessionWhoseTranscriptMatches() {
        let c = SessionCardModel(id: "a", title: "Chapter 4", kind: .classSession, date: Date(), duration: 60,
                                 isUploaded: false, isAnalysed: false)
        let hit = TranscriptHit(sessionID: "a", seconds: 5, stamp: "0:00:05", text: "Jonas")
        let q = SessionsQuery(cards: [c], search: "jonas", transcriptHits: ["a": [hit]])
        XCTAssertEqual(q.visible.count, 1)
        XCTAssertEqual(SessionsQuery(cards: [c], search: "jonas").visible.count, 0)
    }
}
