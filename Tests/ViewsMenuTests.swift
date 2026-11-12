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
        entries.entry(titled: "Spotlight student")?.action?()
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
}
