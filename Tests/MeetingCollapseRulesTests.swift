import XCTest

final class MeetingCollapseRulesTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "MeetingCollapseRulesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private let plain = MeetingCollapseContext()

    // MARK: The ladder

    func testWindowStepsDownToTheMiniByDefault() {
        XCTAssertEqual(MeetingCollapse.next(from: .window, step: .down, lastCollapsed: .mini), .mini)
    }

    func testWindowStepsDownToTheBarWhenThatWasLastChosen() {
        XCTAssertEqual(MeetingCollapse.next(from: .window, step: .down, lastCollapsed: .bar), .bar)
    }

    func testMiniAndBarStepDownToTheBar() {
        XCTAssertEqual(MeetingCollapse.next(from: .mini, step: .down, lastCollapsed: .mini), .bar)
        XCTAssertEqual(MeetingCollapse.next(from: .bar, step: .down, lastCollapsed: .mini), .bar)
    }

    func testMiniStepsUpToTheWindow() {
        XCTAssertEqual(MeetingCollapse.next(from: .mini, step: .up, lastCollapsed: .mini), .window)
        XCTAssertEqual(MeetingCollapse.next(from: .window, step: .up, lastCollapsed: .mini), .window)
    }

    func testBarStepsUpToTheMiniFirstAndOptionGoesToTheWindow() {
        XCTAssertEqual(MeetingCollapse.next(from: .bar, step: .up, lastCollapsed: .bar), .mini)
        XCTAssertEqual(MeetingCollapse.next(from: .bar, step: .up, option: true, lastCollapsed: .bar), .window)
    }

    // MARK: Layout cases

    func testACompactSlotSkipsTheMini() {
        let ctx = MeetingCollapseContext(placedFull: false, meetingIsSlot: true, speakerViewOnScreen: false)
        XCTAssertEqual(MeetingCollapse.next(from: .window, step: .down, lastCollapsed: .mini, context: ctx), .bar)
        XCTAssertEqual(MeetingCollapse.next(from: .bar, step: .up, lastCollapsed: .mini, context: ctx), .window)
    }

    func testASpeakerViewOnScreenSkipsTheMini() {
        let ctx = MeetingCollapseContext(placedFull: true, meetingIsSlot: false, speakerViewOnScreen: true)
        XCTAssertEqual(MeetingCollapse.next(from: .window, step: .down, lastCollapsed: .mini, context: ctx), .bar)
        XCTAssertEqual(MeetingCollapse.next(from: .bar, step: .up, lastCollapsed: .mini, context: ctx), .window)
    }

    func testAFullSizePlacedMeetingUsesTheMiniAndHandsItsRoomToTheNeighbour() {
        let ctx = MeetingCollapseContext(placedFull: true, meetingIsSlot: false, speakerViewOnScreen: false)
        XCTAssertEqual(MeetingCollapse.next(from: .window, step: .down, lastCollapsed: .mini, context: ctx), .mini)
        XCTAssertTrue(MeetingCollapse.neighbourTakesRoom(going: .mini, context: ctx))
        XCTAssertTrue(MeetingCollapse.neighbourTakesRoom(going: .bar, context: ctx))
        XCTAssertFalse(MeetingCollapse.neighbourTakesRoom(going: .window, context: ctx))
    }

    func testNoNeighbourMovesWithoutAFullSizePlacedMeeting() {
        XCTAssertFalse(MeetingCollapse.neighbourTakesRoom(going: .mini, context: plain))
        let slot = MeetingCollapseContext(placedFull: true, meetingIsSlot: true, speakerViewOnScreen: false)
        XCTAssertFalse(MeetingCollapse.neighbourTakesRoom(going: .bar, context: slot))
    }

    // MARK: Remembering

    func testOnlyAStepDownIsRemembered() {
        XCTAssertEqual(MeetingCollapse.remembered(after: .down, from: .window, to: .bar, context: plain, current: .mini), .bar)
        XCTAssertEqual(MeetingCollapse.remembered(after: .down, from: .window, to: .mini, context: plain, current: .bar), .mini)
        XCTAssertEqual(MeetingCollapse.remembered(after: .up, from: .bar, to: .mini, context: plain, current: .bar), .bar)
        XCTAssertEqual(MeetingCollapse.remembered(after: .up, from: .mini, to: .window, context: plain, current: .mini), .mini)
    }

    func testALayoutForcedBarDoesNotOverwriteTheChoice() {
        let ctx = MeetingCollapseContext(placedFull: false, meetingIsSlot: true, speakerViewOnScreen: false)
        XCTAssertEqual(MeetingCollapse.remembered(after: .down, from: .window, to: .bar, context: ctx, current: .mini), .mini)
    }

    func testLastCollapsedDefaultsToTheMiniAndRoundTrips() {
        let d = freshDefaults()
        XCTAssertEqual(MeetingCollapse.lastCollapsed(d), .mini)
        MeetingCollapse.setLastCollapsed(.bar, d)
        XCTAssertEqual(MeetingCollapse.lastCollapsed(d), .bar)
        MeetingCollapse.setLastCollapsed(.window, d)
        XCTAssertEqual(MeetingCollapse.lastCollapsed(d), .bar)
        MeetingCollapse.setLastCollapsed(.mini, d)
        XCTAssertEqual(MeetingCollapse.lastCollapsed(d), .mini)
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

    // MARK: The Mini window plan

    func testAloneYouFillTheMini() {
        let c = MeetingMiniPlan.choose(spotlightID: nil, activeSpeakerID: nil, otherIDs: [], hasMe: true)
        XCTAssertEqual(c, MeetingMiniPlan.Choice(stage: nil, selfFills: true, showsInset: false))
    }

    func testTheActiveSpeakerIsTheStageAndYouAreTheInset() {
        let c = MeetingMiniPlan.choose(spotlightID: nil, activeSpeakerID: 7, otherIDs: [3, 7], hasMe: true)
        XCTAssertEqual(c, MeetingMiniPlan.Choice(stage: 7, selfFills: false, showsInset: true))
    }

    func testASpotlightPickReplacesTheActiveSpeaker() {
        let c = MeetingMiniPlan.choose(spotlightID: 3, activeSpeakerID: 7, otherIDs: [3, 7], hasMe: true)
        XCTAssertEqual(c.stage, 3)
    }

    func testAGonePickFallsBackThenToTheFirstPerson() {
        XCTAssertEqual(MeetingMiniPlan.choose(spotlightID: 99, activeSpeakerID: 7, otherIDs: [3, 7], hasMe: true).stage, 7)
        XCTAssertEqual(MeetingMiniPlan.choose(spotlightID: 99, activeSpeakerID: 98, otherIDs: [3, 7], hasMe: false).stage, 3)
        XCTAssertFalse(MeetingMiniPlan.choose(spotlightID: nil, activeSpeakerID: nil, otherIDs: [3], hasMe: false).showsInset)
    }

    func testTheInsetSitsTopRightInsideTheStage() {
        let size = CGSize(width: 320, height: 180)
        let f = MeetingMiniPlan.frames(in: size)
        XCTAssertEqual(f.stage, CGRect(origin: .zero, size: size))
        XCTAssertTrue(f.stage.contains(f.inset))
        XCTAssertEqual(f.inset.maxX, size.width - MeetingMiniPlan.insetGap)
        XCTAssertEqual(f.inset.maxY, size.height - MeetingMiniPlan.insetGap)
    }

    func testTheFirstFrameIsBottomRightWithMargins() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let f = MeetingMiniPlan.firstFrame(on: visible)
        XCTAssertEqual(f.maxX, visible.maxX - 20)
        XCTAssertEqual(f.minY, visible.minY + 20)
        XCTAssertEqual(f.width, 320)
        XCTAssertEqual(f.height, 180)
    }

    // MARK: The Mini is never a layout piece

    func testAllCasesLeaveOutTheMini() {
        XCTAssertFalse(MeetingView.allCases.contains(.mini))
        XCTAssertEqual(MeetingView.allCases.count, 9)
    }

    func testALayoutNamingTheMiniDoesNotDecode() {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode([MeetingView].self, from: Data("[\"mini\"]".utf8)))
        XCTAssertThrowsError(try decoder.decode([MeetingView].self, from: Data("[\"nonsense\"]".utf8)))
        XCTAssertEqual(try decoder.decode([MeetingView].self, from: Data("[\"gallery\"]".utf8)), [.gallery])
    }
}
