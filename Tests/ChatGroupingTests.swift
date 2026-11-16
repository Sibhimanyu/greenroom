import XCTest

final class ChatGroupingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func line(_ id: String, key: String = "1", name: String = "Maya", at seconds: TimeInterval = 0,
                      out: Bool = false, to: String? = nil, file: Bool = false) -> ChatLine {
        ChatLine(id: id, senderKey: key, senderName: name, isOutgoing: out,
                 timestamp: t0.addingTimeInterval(seconds), privateTo: to, isFile: file)
    }

    func testFirstMessageStartsGroup() {
        XCTAssertTrue(ChatGrouping.rows([line("a")], calendar: cal)[0].startsGroup)
    }

    func testSameSenderWithinThreeMinutesCollapses() {
        let rows = ChatGrouping.rows([line("a"), line("b", at: 60), line("c", at: 60 + 180)], calendar: cal)
        XCTAssertEqual(rows.map(\.startsGroup), [true, false, false])
    }

    func testGapOverThreeMinutesSplits() {
        let rows = ChatGrouping.rows([line("a"), line("b", at: 181)], calendar: cal)
        XCTAssertEqual(rows.map(\.startsGroup), [true, true])
    }

    func testChainMeasuredFromPreviousMessageNotGroupStart() {
        let rows = ChatGrouping.rows([line("a"), line("b", at: 170), line("c", at: 340)], calendar: cal)
        XCTAssertEqual(rows.map(\.startsGroup), [true, false, false])
    }

    func testDifferentSenderSplitsEvenWithSameName() {
        let rows = ChatGrouping.rows([line("a", key: "1"), line("b", key: "2", at: 5)], calendar: cal)
        XCTAssertEqual(rows.map(\.startsGroup), [true, true])
    }

    func testFilesAndPrivacyChangeSplit() {
        let rows = ChatGrouping.rows([line("a"), line("b", at: 5, file: true), line("c", at: 10),
                                      line("d", at: 15, to: "Ravi")], calendar: cal)
        XCTAssertEqual(rows.map(\.startsGroup), [true, true, true, true])
    }

    func testNewDaySplits() {
        let rows = ChatGrouping.rows([line("a"), line("b", at: 86_400)], calendar: cal)
        XCTAssertTrue(rows[1].startsGroup)
    }

    func testOwnMessagesReadYou() {
        let r = ChatGrouping.rows([line("a", name: "Sibhi", out: true)], calendar: cal)[0]
        XCTAssertEqual(r.displayName, "You")
        XCTAssertEqual(ChatGrouping.rows([line("b", name: "Maya")], calendar: cal)[0].displayName, "Maya")
    }

    func testPrivateLabels() {
        let mine = ChatGrouping.privateLabel(for: line("a", name: "Sibhi", out: true, to: "Maya"))
        let theirs = ChatGrouping.privateLabel(for: line("b", name: "Maya", to: "you"))
        XCTAssertEqual(mine, "Privately to Maya")
        XCTAssertEqual(theirs, "Privately to you")
        XCTAssertNil(ChatGrouping.privateLabel(for: line("c")))
    }

    func testComposerCopy() {
        XCTAssertEqual(ChatGrouping.placeholder(privateTo: nil, replying: false), "Message everyone")
        XCTAssertEqual(ChatGrouping.placeholder(privateTo: "Maya", replying: false), "Message Maya")
        XCTAssertEqual(ChatGrouping.audienceNote(privateTo: nil), "Everyone in the meeting can see your messages")
        XCTAssertEqual(ChatGrouping.audienceNote(privateTo: "Maya"), "Only Maya can see this message")
    }
}
