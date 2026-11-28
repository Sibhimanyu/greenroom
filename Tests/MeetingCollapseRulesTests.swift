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

    // MARK: Sizes as decisions (Spec: docs/specs/meeting-surface.md R15 to R21)

    private func size(morph: CGFloat? = nil, open: Bool = true, live: Bool = false,
                      reopenWindow: Bool = true, hidden: Bool = false) -> MeetingSize {
        MeetingCollapse.sizeOnScreen(morphHeading: morph, windowOpen: open, live: live,
                                     reopenIsWindow: reopenWindow, windowHidden: hidden)
    }

    // Spec: meeting-surface R15
    func testAMorphHeadingSomewhereDecidesTheSize() {
        XCTAssertEqual(size(morph: 1, open: false, live: true, reopenWindow: false), .window)
        XCTAssertEqual(size(morph: 0, open: true, live: true, reopenWindow: true), .bar)
    }
    // Spec: meeting-surface R15
    func testNoOpenWindowIsTheBar() {
        XCTAssertEqual(size(open: false), .bar)
        XCTAssertEqual(size(open: false, live: true, reopenWindow: true), .bar)
    }
    // Spec: meeting-surface R15
    func testLiveFollowsTheModelsReopenTarget() {
        XCTAssertEqual(size(live: true, reopenWindow: true, hidden: true), .window)
        XCTAssertEqual(size(live: true, reopenWindow: false, hidden: false), .bar)
    }
    // Spec: meeting-surface R15
    func testNotLiveFollowsWhetherTheWindowIsHidden() {
        XCTAssertEqual(size(hidden: true), .bar)
        XCTAssertEqual(size(hidden: false), .window)
    }

    // Spec: meeting-surface R16
    func testAMoveToTheBarNeedsABar() {
        XCTAssertEqual(MeetingCollapse.plan(from: .window, wanted: .bar, barInstalled: true), .collapse)
        XCTAssertEqual(MeetingCollapse.plan(from: .window, wanted: .bar, barInstalled: false), .stay)
    }
    // Spec: meeting-surface R16
    func testTheWindowComesBackWithOrWithoutABar() {
        XCTAssertEqual(MeetingCollapse.plan(from: .bar, wanted: .window, barInstalled: true), .expand)
        XCTAssertEqual(MeetingCollapse.plan(from: .bar, wanted: .window, barInstalled: false), .expand)
    }
    // Spec: meeting-surface R16
    func testTheSameSizeStays() {
        XCTAssertEqual(MeetingCollapse.plan(from: .bar, wanted: .bar, barInstalled: true), .stay)
        XCTAssertEqual(MeetingCollapse.plan(from: .window, wanted: .window, barInstalled: true), .stay)
    }

    // Spec: meeting-surface R17
    func testTheStepFollowsTheTarget() {
        XCTAssertEqual(MeetingCollapse.step(toward: .bar), .down)
        XCTAssertEqual(MeetingCollapse.step(toward: .window), .up)
    }

    // Spec: meeting-surface R18
    func testExpandDuringAMorphTurnsItRound() {
        XCTAssertEqual(MeetingCollapse.expandPlan(morphing: true, size: .bar), .turnRound)
        XCTAssertEqual(MeetingCollapse.expandPlan(morphing: true, size: .window), .turnRound)
    }
    // Spec: meeting-surface R18
    func testExpandFromACoveredBarOpensTheWindow() {
        XCTAssertEqual(MeetingCollapse.expandPlan(morphing: false, size: .window), .openWindow)
        XCTAssertEqual(MeetingCollapse.expandPlan(morphing: false, size: .bar), .step)
    }

    // Spec: meeting-surface R19
    func testToggleDuringAMorphGoesTheOtherWay() {
        XCTAssertEqual(MeetingCollapse.togglePlan(morphHeading: 0, size: .window), .expandFromBar)
        XCTAssertEqual(MeetingCollapse.togglePlan(morphHeading: 1, size: .bar), .shrinkToBar)
        // Quirk kept: anything but 0 shrinks.
        XCTAssertEqual(MeetingCollapse.togglePlan(morphHeading: 0.5, size: .bar), .shrinkToBar)
    }
    // Spec: meeting-surface R19
    func testToggleWithoutAMorphFollowsTheSize() {
        XCTAssertEqual(MeetingCollapse.togglePlan(morphHeading: nil, size: .window), .collapse)
        XCTAssertEqual(MeetingCollapse.togglePlan(morphHeading: nil, size: .bar), .expandFromBar)
    }

    // Spec: meeting-surface R20
    func testTheNeighbourMovesOnlyWhenTheSessionArranges() {
        let full = MeetingCollapseContext(placedFull: true, meetingIsSlot: false)
        XCTAssertTrue(MeetingCollapse.neighbourMoves(going: .bar, context: full, arranged: true))
        XCTAssertFalse(MeetingCollapse.neighbourMoves(going: .bar, context: full, arranged: false))
        XCTAssertFalse(MeetingCollapse.neighbourMoves(going: .window, context: full, arranged: true))
        XCTAssertFalse(MeetingCollapse.neighbourMoves(going: .bar, context: plain, arranged: true))
    }
    // Spec: meeting-surface R20
    func testClosingByHandHandsTheRoomOnlyWhenNothingElseShowsTheMeeting() {
        XCTAssertTrue(MeetingCollapse.closeHandsRoomToNeighbour(arranged: true, inMeeting: true, placesMeeting: true, viewWindowsOpen: false))
        XCTAssertFalse(MeetingCollapse.closeHandsRoomToNeighbour(arranged: false, inMeeting: true, placesMeeting: true, viewWindowsOpen: false))
        XCTAssertFalse(MeetingCollapse.closeHandsRoomToNeighbour(arranged: true, inMeeting: false, placesMeeting: true, viewWindowsOpen: false))
        XCTAssertFalse(MeetingCollapse.closeHandsRoomToNeighbour(arranged: true, inMeeting: true, placesMeeting: false, viewWindowsOpen: false))
        XCTAssertFalse(MeetingCollapse.closeHandsRoomToNeighbour(arranged: true, inMeeting: true, placesMeeting: true, viewWindowsOpen: true))
    }

    // Spec: meeting-surface R21
    func testReopenShrunkIgnoresMorphsAndOpenWindows() {
        XCTAssertTrue(MeetingCollapse.shrunkForReopen(live: true, reopenIsBar: true, windowHidden: false))
        XCTAssertFalse(MeetingCollapse.shrunkForReopen(live: true, reopenIsBar: false, windowHidden: true))
        XCTAssertTrue(MeetingCollapse.shrunkForReopen(live: false, reopenIsBar: false, windowHidden: true))
        XCTAssertFalse(MeetingCollapse.shrunkForReopen(live: false, reopenIsBar: true, windowHidden: false))
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

    // MARK: Other desktops

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

    // MARK: What the views a layout places draw

    func testNoLayoutKeepsTheViewsControls() {
        XCTAssertEqual(MeetingSurfacePlan.decide(layoutActive: false).viewsChrome, .full)
    }

    func testALayoutMakesTheViewsContentOnly() {
        let p = MeetingSurfacePlan.decide(layoutActive: true)
        XCTAssertEqual(p.viewsChrome, .contentOnly)
        XCTAssertFalse(p.viewsChrome.showsControls)
    }
}
