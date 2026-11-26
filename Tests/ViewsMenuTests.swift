import XCTest

/// The Views menu: the Meeting window and every view, a checkmark on each open one.
final class ViewsMenuTests: XCTestCase {

    func testListsTheMeetingWindowThenEveryView() {
        let entries = MeetingMenus.views(.init(), toggleMeetingWindow: {}, toggleView: { _ in })
        XCTAssertEqual(entries.flatTitles, ["Meeting window"] + MeetingView.allCases.map(\.title))
        XCTAssertEqual(entries.flatTitles.count, 10)
    }

    func testCheckmarksFollowWhatIsOpen() {
        let state = MeetingMenus.ViewsMenuState(meetingWindowOpen: true, openViews: [.gallery, .handsUp], viewsAvailable: true)
        let entries = MeetingMenus.views(state, toggleMeetingWindow: {}, toggleView: { _ in })
        let checked = entries.filter(\.checked).map(\.title)
        XCTAssertEqual(Set(checked), ["Meeting window", "Gallery", "Hands up"])
        let none = MeetingMenus.views(.init(), toggleMeetingWindow: {}, toggleView: { _ in })
        XCTAssertTrue(none.filter(\.checked).isEmpty)
    }

    func testChoosingAnItemTogglesThatWindow() {
        var toggled: [MeetingView] = []
        var meetingToggled = 0
        let entries = MeetingMenus.views(.init(openViews: [.gallery]),
                                         toggleMeetingWindow: { meetingToggled += 1 },
                                         toggleView: { toggled.append($0) })
        entries.entry(titled: "Gallery")?.action?()
        entries.entry(titled: "Spotlight person")?.action?()
        entries.entry(titled: "Meeting window")?.action?()
        XCTAssertEqual(toggled, [.gallery, .spotlight])
        XCTAssertEqual(meetingToggled, 1)
    }

    func testViewsOffOffersOnlyTheMeetingWindow() {
        let entries = MeetingMenus.views(.init(viewsAvailable: false), toggleMeetingWindow: {}, toggleView: { _ in })
        XCTAssertEqual(entries.flatTitles, ["Meeting window"])
    }

    func testTheMoreMenuHoldsTheViewsSubmenu() {
        let views = MeetingMenus.views(.init(openViews: [.people]), toggleMeetingWindow: {}, toggleView: { _ in })
        let more = MeetingMenus.more(overflow: [], facts: .init(), views: views, .init())
        let submenu = more.entry(titled: "Views")
        XCTAssertEqual(submenu?.kind, .submenu)
        XCTAssertEqual(submenu?.children.count, views.count)
        XCTAssertTrue(MeetingMenus.more(overflow: [], facts: .init(), .init()).entry(titled: "Views") == nil)
    }

    // MARK: The bar's Views menu while the Meeting window is away

    private func barViews(pickers: [MenuEntry] = [], host: Bool = true) -> [MenuEntry] {
        let views = MeetingMenus.views(.init(), toggleMeetingWindow: {}, toggleView: { _ in })
        let item = MenuEntry.item("x") {}
        let controls = MeetingMenus.BarControls(audio: [item], video: [item], react: [item],
                                                security: host ? [item] : nil, sharing: [item], pickers: pickers)
        let facts = MeetingMenus.MeetingFacts(number: "82916390348", passcode: "", joinURL: "https://zoom.us/j/1")
        return MeetingMenus.barViews(views, controls: controls, facts: facts, .init())
    }

    /// Kinds top to bottom, "-" for a divider, for reading a failure.
    private func shape(_ entries: [MenuEntry]) -> String {
        entries.map { $0.kind == .separator ? "-" : $0.title }.joined(separator: " | ")
    }

    private func assertNoEmptySection(_ entries: [MenuEntry], file: StaticString = #filePath, line: UInt = #line) {
        let kinds = entries.map(\.kind)
        XCTAssertNotEqual(kinds.first, .separator, shape(entries), file: file, line: line)
        XCTAssertNotEqual(kinds.last, .separator, shape(entries), file: file, line: line)
        for (a, b) in zip(kinds, kinds.dropFirst()) where a == .separator {
            XCTAssertNotEqual(b, .separator, "two dividers in a row: \(shape(entries))", file: file, line: line)
        }
    }

    // The owner's screenshot (1.10.0): two dividers between "Sharing" and "Meeting info",
    // 21 rows. The controls closed their own section and More closed it again.
    func testTheBarsViewsMenuHasNoEmptySection() {
        let entries = barViews()
        assertNoEmptySection(entries)
        XCTAssertEqual(entries.count, 20)
        assertNoEmptySection(barViews(host: false))
    }

    func testAContentViewsPickersAreTheirOwnSection() {
        let picker = MenuEntry.submenu("Spotlight person", [.item("Ana") {}])
        let entries = barViews(pickers: [picker])
        assertNoEmptySection(entries)
        let at = entries.lastIndex { $0.title == "Spotlight person" }!   // the view row comes first
        XCTAssertEqual(entries[at - 1].kind, .separator)
        XCTAssertEqual(entries[at - 2].title, "Sharing")
        XCTAssertEqual(entries[at + 1].kind, .separator)
        XCTAssertEqual(entries[at + 2].title, "Meeting info")
    }
}

/// The menu builder's divider rule (`[MenuEntry].tidiedSeparators`), for every menu it draws.
final class MenuSeparatorRuleTests: XCTestCase {
    private let a = MenuEntry.item("A") {}
    private let b = MenuEntry.item("B") {}
    private let sep = MenuEntry.separator

    private func shape(_ entries: [MenuEntry]) -> [String] {
        entries.map { $0.kind == .separator ? "-" : $0.title }
    }

    func testRepeatedDividersCollapseToOne() {
        XCTAssertEqual(shape([a, sep, sep, sep, b].tidiedSeparators), ["A", "-", "B"])
    }

    func testLeadingAndTrailingDividersGo() {
        XCTAssertEqual(shape([sep, sep, a, sep, b, sep].tidiedSeparators), ["A", "-", "B"])
        XCTAssertEqual(shape([sep, sep].tidiedSeparators), [])
        XCTAssertEqual(shape([MenuEntry]().tidiedSeparators), [])
    }

    func testAWellFormedMenuIsUnchanged() {
        let header = MenuEntry.header("Camera")
        let entries = [header, a, sep, b]
        XCTAssertEqual(shape(entries.tidiedSeparators), shape(entries))
    }

    func testSubmenusFollowTheSameRule() {
        let sub = MenuEntry.submenu("More", [sep, a, sep, sep, b, sep])
        let tidied = [sub].tidiedSeparators
        XCTAssertEqual(shape(tidied.first!.children), ["A", "-", "B"])
    }

    func testItemsKeepTheirActions() {
        var ran = 0
        let entries = [sep, MenuEntry.item("Go") { ran += 1 }, sep].tidiedSeparators
        entries.first?.action?()
        XCTAssertEqual(ran, 1)
    }
}

