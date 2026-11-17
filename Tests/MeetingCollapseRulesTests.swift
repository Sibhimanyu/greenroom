import XCTest

final class MeetingCollapseRulesTests: XCTestCase {

    private let plain = MeetingCollapseContext()

    // MARK: The ladder

    func testWindowStepsDownToTheBarAndTheBarStepsUpToTheWindow() {
        XCTAssertEqual(MeetingCollapse.next(from: .window, step: .down), .bar)
        XCTAssertEqual(MeetingCollapse.next(from: .bar, step: .down), .bar)
        XCTAssertEqual(MeetingCollapse.next(from: .bar, step: .up), .window)
        XCTAssertEqual(MeetingCollapse.next(from: .window, step: .up), .window)
    }

    func testThereAreTwoSizes() {
        XCTAssertNil(MeetingSize(rawValue: "mini"))
        XCTAssertEqual(MeetingSize(rawValue: "bar"), .bar)
        XCTAssertEqual(MeetingSize(rawValue: "window"), .window)
    }

    // MARK: Layout cases

    func testAFullSizePlacedMeetingHandsItsRoomToTheNeighbour() {
        let ctx = MeetingCollapseContext(placedFull: true, meetingIsSlot: false)
        XCTAssertTrue(MeetingCollapse.neighbourTakesRoom(going: .bar, context: ctx))
        XCTAssertFalse(MeetingCollapse.neighbourTakesRoom(going: .window, context: ctx))
    }

    func testNoNeighbourMovesWithoutAFullSizePlacedMeeting() {
        XCTAssertFalse(MeetingCollapse.neighbourTakesRoom(going: .bar, context: plain))
        let slot = MeetingCollapseContext(placedFull: true, meetingIsSlot: true)
        XCTAssertFalse(MeetingCollapse.neighbourTakesRoom(going: .bar, context: slot))
    }

    // MARK: Show on my share

    func testOnlyAWholeDisplayShareLetsWindowsThrough() {
        let registry: Set<Int> = [12, 40]
        XCTAssertEqual(ShowOnShare.exceptionIDs(kind: .display, registry: registry), registry)
        XCTAssertEqual(ShowOnShare.exceptionIDs(kind: .display, registry: []), [])
        XCTAssertNil(ShowOnShare.exceptionIDs(kind: .app, registry: registry))
        XCTAssertNil(ShowOnShare.exceptionIDs(kind: .window, registry: registry))
        XCTAssertNil(ShowOnShare.exceptionIDs(kind: .other, registry: registry))
    }

    func testShowOnShareAvailabilityHelpAndMarking() {
        XCTAssertTrue(ShowOnShare.isAvailable(.display))
        XCTAssertFalse(ShowOnShare.isAvailable(.app))
        XCTAssertEqual(ShowOnShare.help(kind: .window, on: true), "Works when you share a whole display")
        XCTAssertTrue(ShowOnShare.help(kind: .display, on: true).contains("in the picture"))
        XCTAssertTrue(ShowOnShare.help(kind: .display, on: false).contains("stay out"))
        XCTAssertTrue(ShowOnShare.marksWindow(on: true, kind: .display))
        XCTAssertFalse(ShowOnShare.marksWindow(on: true, kind: .app))
        XCTAssertFalse(ShowOnShare.marksWindow(on: false, kind: .display))
    }

    // MARK: The Mini is gone

    func testALayoutNamingTheMiniDoesNotDecode() {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode([MeetingView].self, from: Data("[\"mini\"]".utf8)))
        XCTAssertThrowsError(try decoder.decode([MeetingView].self, from: Data("[\"nonsense\"]".utf8)))
        XCTAssertEqual(try decoder.decode([MeetingView].self, from: Data("[\"gallery\"]".utf8)), [.gallery])
        XCTAssertEqual(MeetingView.allCases.count, 9)
    }

    // MARK: One control surface at a time

    func testExactlyOneSurfaceForEveryStateWithABar() {
        for window in [true, false] {
            XCTAssertTrue(MeetingSurfaces.isSound(windowShowing: window, barExists: true), "window \(window)")
        }
    }

    func testTheBarFillsInOnlyWhenTheWindowIsNotUp() {
        XCTAssertTrue(MeetingSurfaces.barVisible(windowShowing: false))
        XCTAssertFalse(MeetingSurfaces.barVisible(windowShowing: true))
    }

    func testNoBarAndNoWindowIsNoSurfaceAtAll() {
        XCTAssertEqual(MeetingSurfaces.visibleCount(windowShowing: false, barExists: false), 0)
        XCTAssertFalse(MeetingSurfaces.isSound(windowShowing: false, barExists: false))
    }

    func testEveryWayBackLandsOnSomethingThatExists() {
        XCTAssertEqual(MeetingSurfaces.wayBack(windowExists: true, barExists: true), .window)
        XCTAssertEqual(MeetingSurfaces.wayBack(windowExists: false, barExists: true), .bar)
        XCTAssertNil(MeetingSurfaces.wayBack(windowExists: false, barExists: false))
    }

    // MARK: Other desktops

    func testThePopOutsComeToThisDesktop() {
        XCTAssertTrue(MeetingSurfaces.comesHereFirst(visible: true, onActiveSpace: false))
        XCTAssertFalse(MeetingSurfaces.comesHereFirst(visible: true, onActiveSpace: true))
        // Hidden (shrunk to the bar): ordering it in already lands it here.
        XCTAssertFalse(MeetingSurfaces.comesHereFirst(visible: false, onActiveSpace: false))
    }

    func testTheMeetingWindowOnAnotherDesktopTakesYouThere() {
        XCTAssertTrue(MeetingSurfaces.meetingWindowElsewhere(visible: true, miniaturized: false, onActiveSpace: false))
        // In view already: nothing to switch to.
        XCTAssertFalse(MeetingSurfaces.meetingWindowElsewhere(visible: true, miniaturized: false, onActiveSpace: true))
        // Shrunk to the bar or minimised: it comes up here, the pop-outs stay.
        XCTAssertFalse(MeetingSurfaces.meetingWindowElsewhere(visible: false, miniaturized: false, onActiveSpace: false))
        XCTAssertFalse(MeetingSurfaces.meetingWindowElsewhere(visible: true, miniaturized: true, onActiveSpace: false))
    }

    func testThePopOutChatFoldsIntoTheWindowOnceTheWindowIsInView() {
        XCTAssertTrue(MeetingSurfaces.foldsPopOutChat(windowShowing: true, popOutOpen: true, arranged: false))
        // Still on another desktop: the pop-out is the chat here.
        XCTAssertFalse(MeetingSurfaces.foldsPopOutChat(windowShowing: false, popOutOpen: true, arranged: false))
        XCTAssertFalse(MeetingSurfaces.foldsPopOutChat(windowShowing: true, popOutOpen: false, arranged: false))
        // A layout's chat is a placed piece, never folded away.
        XCTAssertFalse(MeetingSurfaces.foldsPopOutChat(windowShowing: true, popOutOpen: true, arranged: true))
    }

    // MARK: Who carries the controls

    private func plan(_ layout: Bool, _ hasMain: Bool, _ shown: Bool) -> MeetingSurfacePlan {
        MeetingSurfacePlan.decide(layoutActive: layout, layoutHasMainWindow: hasMain, mainWindowShown: shown)
    }

    func testNoLayoutKeepsWindowOrBar() {
        XCTAssertFalse(plan(false, false, true).barVisible)
        XCTAssertTrue(plan(false, false, false).barVisible)
        XCTAssertEqual(plan(false, false, true).viewsChrome, .full)
        XCTAssertEqual(plan(false, false, false).viewsChrome, .full)
    }

    func testLayoutWithMainWindowShownHidesBarAndKeepsItsControls() {
        let p = plan(true, true, true)
        XCTAssertFalse(p.barVisible)
        XCTAssertEqual(p.mainWindowChrome, .full)
        XCTAssertEqual(p.viewsChrome, .contentOnly)
    }

    func testLayoutWithMainWindowCollapsedShowsBar() {
        let p = plan(true, true, false)
        XCTAssertTrue(p.barVisible)
        XCTAssertEqual(p.viewsChrome, .contentOnly)
    }

    func testLayoutOfOnlyContentViewsShowsBarAndContentOnly() {
        let p = plan(true, false, false)
        XCTAssertTrue(p.barVisible)
        XCTAssertEqual(p.viewsChrome, .contentOnly)
        XCTAssertFalse(p.viewsChrome.showsControls)
    }

    func testLayoutWithoutMeetingPieceButWindowOpenedByHandKeepsItsControls() {
        let p = plan(true, false, true)
        XCTAssertFalse(p.barVisible)
        XCTAssertEqual(p.mainWindowChrome, .full)
    }
}
