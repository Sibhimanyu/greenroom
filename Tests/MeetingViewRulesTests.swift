import XCTest

/// Speaker / Gallery / Multi-speaker, the share layouts, the split, the two
/// filters and who gets a tile (MeetingViewRules.swift).
final class MeetingViewRulesTests: XCTestCase {

    private func people(_ spec: [(UInt32, Bool)]) -> [MeetingTileCandidate] {
        spec.map { MeetingTileCandidate(id: $0.0, videoOn: $0.1) }
    }
    private let four = [(UInt32(2), true), (3, true), (4, false), (5, true)]

    // MARK: Modes and layouts

    func testViewOrderIsSpeakerGalleryMultiSpeaker() {
        XCTAssertEqual(MeetingViewMode.menuOrder, [.speaker, .gallery, .multiSpeaker])
        XCTAssertEqual(MeetingViewMode.menuOrder.map(\.title), ["Speaker", "Gallery", "Multi-speaker"])
        for mode in MeetingViewMode.allCases { XCTAssertEqual(MeetingViewMode(segment: mode.segmentIndex), mode) }
    }

    func testCycleGoesSpeakerGalleryMultiSpeaker() {
        XCTAssertEqual(MeetingViewMode.speaker.next(), .gallery)
        XCTAssertEqual(MeetingViewMode.gallery.next(), .multiSpeaker)
        XCTAssertEqual(MeetingViewMode.multiSpeaker.next(), .speaker)
    }

    func testCycleSkipsMultiSpeakerWhenItWouldOnlyShowSpeaker() {
        XCTAssertEqual(MeetingViewMode.gallery.next(multiSpeakerAvailable: false), .speaker)
        XCTAssertEqual(MeetingViewMode.speaker.next(multiSpeakerAvailable: false), .gallery)
    }

    func testShareLayoutsAndTheirTitles() {
        XCTAssertEqual(MeetingShareLayout.allCases.map(\.menuTitle),
                       ["Standard", "Side-by-side: Speaker", "Side-by-side: Gallery", "Side-by-side: Multi-speaker"])
        XCTAssertNil(MeetingShareLayout.standard.sideMode)
        for mode in MeetingViewMode.allCases {
            XCTAssertEqual(MeetingShareLayout.sideBySide(mode).sideMode, mode)
            XCTAssertTrue(MeetingShareLayout.sideBySide(mode).isSideBySide)
        }
    }

    // MARK: The split

    func testSplitDefaultsTo70AndClampsTo50And85() {
        XCTAssertEqual(MeetingSplit.defaultFraction, 0.70)
        XCTAssertEqual(MeetingSplit.clamp(0.1), 0.50)
        XCTAssertEqual(MeetingSplit.clamp(0.99), 0.85)
        XCTAssertEqual(MeetingSplit.clamp(0.62), 0.62)
        XCTAssertEqual(MeetingSplit.clamp(.nan), 0.70)
    }

    func testDraggingTheBoundaryIsClampedToTheStage() {
        let stage = CGRect(x: 0, y: 64, width: 1000, height: 600)
        XCTAssertEqual(MeetingSplit.fraction(forBoundaryX: 600, in: stage), 0.60, accuracy: 0.0001)
        XCTAssertEqual(MeetingSplit.fraction(forBoundaryX: 10, in: stage), 0.50)
        XCTAssertEqual(MeetingSplit.fraction(forBoundaryX: 990, in: stage), 0.85)
    }

    func testRegionsPutTheShareLeftAndLeaveFourPointsBetweenPanes() {
        let stage = CGRect(x: 0, y: 64, width: 1000, height: 600)
        let r = MeetingSplit.regions(stage: stage, fraction: 0.7)
        XCTAssertEqual(r.share.minX, 4)
        XCTAssertEqual(r.share.maxX, 698)                       // boundary 700, 2 pt short
        // The video rect is inset by the layouts' own 4 pt, so panes end up 4 apart.
        XCTAssertEqual((r.video.minX + 4) - r.share.maxX, 4)
        XCTAssertEqual(r.video.maxX, 1000)
        XCTAssertEqual(r.divider.midX, 700)
        XCTAssertEqual(r.share.height, 592)
    }

    func testRegionsClampAnOutOfRangeFraction() {
        let stage = CGRect(x: 0, y: 0, width: 1000, height: 500)
        XCTAssertEqual(MeetingSplit.regions(stage: stage, fraction: 0.2).divider.midX, 500)
        XCTAssertEqual(MeetingSplit.regions(stage: stage, fraction: 0.99).divider.midX, 850)
    }

    // MARK: Per Mac

    func testPrefsRememberEverythingAndDefaultSensibly() {
        let suite = "MeetingViewRulesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = MeetingViewPrefs(defaults: defaults)
        XCTAssertEqual(prefs.view, .gallery)
        XCTAssertEqual(prefs.shareLayout, .standard)
        XCTAssertEqual(prefs.splitFraction, 0.70)
        XCTAssertFalse(prefs.hideSelfView)
        XCTAssertFalse(prefs.hideNoVideo)

        prefs.view = .multiSpeaker
        prefs.shareLayout = .sideBySideGallery
        prefs.splitFraction = 0.6
        prefs.hideSelfView = true
        prefs.hideNoVideo = true
        let again = MeetingViewPrefs(defaults: defaults)
        XCTAssertEqual(again.view, .multiSpeaker)
        XCTAssertEqual(again.shareLayout, .sideBySideGallery)
        XCTAssertEqual(again.splitFraction, 0.6, accuracy: 0.0001)
        XCTAssertTrue(again.hideSelfView)
        XCTAssertTrue(again.hideNoVideo)

        prefs.splitFraction = 0.2
        XCTAssertEqual(again.splitFraction, 0.50, "stored clamped")
    }

    func testTheOldTwoViewValuesStillRead() {
        let suite = "MeetingViewRulesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("speaker", forKey: MeetingViewPrefs.viewKey)
        XCTAssertEqual(MeetingViewPrefs(defaults: defaults).view, .speaker)
    }

    // MARK: Filters

    func testHideVideoOffKeepsOrderAndDropsOnlyThoseWithoutVideo() {
        let all = people(four)
        XCTAssertEqual(MeetingTileFilter.apply(all, hideNoVideo: false), all)
        XCTAssertEqual(MeetingTileFilter.apply(all, hideNoVideo: true).map(\.id), [2, 3, 5])
    }

    func testTheEmptyNoteSaysEveryoneElseHasVideoOff() {
        XCTAssertEqual(MeetingTileFilter.emptyNote, "Everyone else has video off")
    }

    // MARK: Tile assignment

    private func plan(_ spec: [(UInt32, Bool)], _ mode: MeetingViewMode, hide: Bool = false, stage: UInt32? = nil,
                      recent: [UInt32] = [], share: Bool = false) -> MeetingTilePlan {
        MeetingTilePlan.make(others: people(spec), mode: mode, hideNoVideo: hide, stageChoice: stage,
                             recentSpeakers: recent, shareOnStage: share)
    }

    func testGalleryListsEveryone() {
        let p = plan(four, .gallery)
        XCTAssertEqual(p.mode, .gallery)
        XCTAssertEqual(p.rest, [2, 3, 4, 5])
        XCTAssertTrue(p.large.isEmpty)
        XCTAssertNil(p.stage)
    }

    func testSpeakerPutsTheChoiceOnTheStageAndTheRestInTheStrip() {
        let p = plan(four, .speaker, stage: 3)
        XCTAssertEqual(p.stage, 3)
        XCTAssertEqual(p.rest, [2, 4, 5])
    }

    func testSpeakerWithNoChoiceHasNoStagePersonAndListsEveryone() {
        let p = plan(four, .speaker)
        XCTAssertNil(p.stage)
        XCTAssertEqual(p.rest, [2, 3, 4, 5])
    }

    func testAShareOnTheStageMovesEveryoneToTheStrip() {
        let p = plan(four, .speaker, stage: 3, share: true)
        XCTAssertNil(p.stage)
        XCTAssertEqual(p.rest, [2, 3, 4, 5])
    }

    func testHidingVideoOffMovesTheStageToTheFirstWhoShows() {
        let p = plan(four, .speaker, hide: true, stage: 4)
        XCTAssertEqual(p.stage, 2)
        XCTAssertEqual(p.rest, [3, 5])
    }

    func testMultiSpeakerWithFewerThanThreePeopleIsSpeaker() {
        // You and one other.
        let two = plan([(2, true)], .multiSpeaker, stage: 2, recent: [2])
        XCTAssertEqual(two.mode, .speaker)
        XCTAssertEqual(two.stage, 2)
        XCTAssertTrue(two.large.isEmpty)
        // You and two others is enough.
        XCTAssertEqual(plan([(2, true), (3, true)], .multiSpeaker).mode, .multiSpeaker)
    }

    func testMultiSpeakerShowsRecentSpeakersLargeAndTheRestInAStrip() {
        let spec = (2...8).map { (UInt32($0), true) }
        let p = plan(spec, .multiSpeaker, recent: [5, 3, 7])
        XCTAssertEqual(p.large, [5, 3, 7])
        XCTAssertEqual(p.rest, [2, 4, 6, 8])
        XCTAssertEqual(p.listed, [5, 3, 7, 2, 4, 6, 8])
    }

    func testMultiSpeakerAlwaysHasAtLeastTwoLargeTiles() {
        let spec = (2...6).map { (UInt32($0), true) }
        XCTAssertEqual(plan(spec, .multiSpeaker, recent: [4]).large, [4, 2])
        XCTAssertEqual(plan(spec, .multiSpeaker, recent: []).large, [2, 3])
    }

    func testMultiSpeakerNeverHasMoreThanFourLargeTiles() {
        let spec = (2...10).map { (UInt32($0), true) }
        XCTAssertEqual(plan(spec, .multiSpeaker, recent: [2, 3, 4, 5, 6]).large, [2, 3, 4, 5])
    }

    func testMultiSpeakerIgnoresSpeakersTheFilterHid() {
        let spec: [(UInt32, Bool)] = [(2, true), (3, false), (4, true), (5, true)]
        let p = plan(spec, .multiSpeaker, hide: true, recent: [3, 4])
        XCTAssertEqual(p.large, [4, 2])
        XCTAssertEqual(p.rest, [5])
    }

    func testEveryoneHiddenOnlyWhenThereAreOthersAndAllHaveVideoOff() {
        let off = [(UInt32(2), false), (3, false)]
        XCTAssertTrue(plan(off, .gallery, hide: true).everyoneHidden)
        XCTAssertFalse(plan(off, .gallery, hide: false).everyoneHidden)
        XCTAssertFalse(plan([], .gallery, hide: true).everyoneHidden, "an empty room is a different note")
        XCTAssertFalse(plan(four, .gallery, hide: true).everyoneHidden)
    }

    // MARK: Multi-speaker hysteresis (the tracker the window feeds)

    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func talk(_ r: inout RecentSpeakers, _ id: UInt32, from: TimeInterval, length: TimeInterval, present: Set<UInt32>) {
        var t = from
        while t <= from + length {
            r.heard([id], selfID: nil, now: at(t))
            r.update(present: present, now: at(t))
            t += 0.5
        }
    }

    func testTheWindowTrackerKeepsFourPlacesAndEveryoneForThreeSeconds() {
        var r = RecentSpeakers(limit: 4, minimumStay: 3)
        XCTAssertEqual(r.limit, 4)
        XCTAssertEqual(r.minimumStay, 3)
        let present: Set<UInt32> = [2, 3, 4, 5, 6]
        talk(&r, 2, from: 0, length: 2, present: present)
        talk(&r, 3, from: 2.5, length: 2, present: present)
        talk(&r, 4, from: 5, length: 2, present: present)
        talk(&r, 5, from: 7.5, length: 2, present: present)
        XCTAssertEqual(r.occupied.map(\.userID), [2, 3, 4, 5])
        // 6 starts talking straight away: 5 arrived under 3 s ago, but 2 has been there for ten.
        talk(&r, 6, from: 10, length: 2, present: present)
        XCTAssertEqual(r.occupied.first { $0.userID == 6 }?.slot, 0, "took the least recent speaker's place")
        XCTAssertFalse(r.occupied.map(\.userID).contains(2))
    }

    func testACoughNeverMovesATile() {
        var r = RecentSpeakers(limit: 2, minimumStay: 3)
        let present: Set<UInt32> = [2, 3, 4]
        talk(&r, 2, from: 0, length: 2, present: present)
        talk(&r, 3, from: 2.5, length: 2, present: present)
        let before = r.occupied.map(\.userID)
        r.heard([4], selfID: nil, now: at(5))
        r.update(present: present, now: at(5))
        r.heard([], selfID: nil, now: at(5.5))
        r.update(present: present, now: at(5.6))
        XCTAssertEqual(r.occupied.map(\.userID), before)
    }

    func testNobodyIsReplacedBeforeThreeSeconds() {
        var r = RecentSpeakers(limit: 1, minimumStay: 3)
        let present: Set<UInt32> = [2, 3]
        talk(&r, 2, from: 0, length: 2, present: present)         // joins at 1.5
        talk(&r, 3, from: 2, length: 1.4, present: present)       // 3 is eligible at 3.5; 2 has been in 2 s
        XCTAssertEqual(r.occupied.map(\.userID), [2])
        talk(&r, 3, from: 3.5, length: 2, present: present)
        XCTAssertEqual(r.occupied.map(\.userID), [3])
    }

    // MARK: Rectangles

    func testMultiSpeakerPutsLargeTilesAboveAndAStripBelow() {
        let size = CGSize(width: 1200, height: 600)
        let f = MeetingVideoLayout.multiSpeaker(largeCount: 3, stripCount: 4, in: size, stripHeight: 104)
        XCTAssertEqual(f.large.count, 3)
        XCTAssertEqual(f.strip.count, 4)
        let stripTop = f.strip.map(\.maxY).max()!
        XCTAssertLessThanOrEqual(stripTop, f.large.map(\.minY).min()!, "the strip is below the large tiles")
        XCTAssertEqual(f.strip.map(\.minY).min()!, 0)
        for rect in f.large + f.strip {
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
        }
        // No overlaps anywhere.
        let all = f.large + f.strip
        for (i, a) in all.enumerated() { for b in all[(i + 1)...] { XCTAssertFalse(a.intersects(b)) } }
    }

    func testMultiSpeakerWithNoStripGivesTheLargeTilesEverything() {
        let size = CGSize(width: 1200, height: 600)
        let f = MeetingVideoLayout.multiSpeaker(largeCount: 2, stripCount: 0, in: size, stripHeight: 104)
        XCTAssertTrue(f.strip.isEmpty)
        XCTAssertEqual(f.large.map(\.height).max()!, 336, "two 598-wide tiles side by side")
    }

    func testTheStripLeavesRoomForYourPreview() {
        let size = CGSize(width: 1000, height: 600)
        let fits = MeetingVideoLayout.stripCapacity(width: 1000 - 180, tileHeight: 96)
        let f = MeetingVideoLayout.multiSpeaker(largeCount: 2, stripCount: fits, in: size, stripHeight: 104, reservedStripRight: 180)
        XCTAssertLessThanOrEqual(f.strip.map(\.maxX).max()!, 1000 - 180)
    }

    func testGalleryOfOneFillsTheAreaAs16By9() {
        let f = MeetingVideoLayout.gallery(count: 1, in: CGSize(width: 1600, height: 900))
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].width / f[0].height, 16.0 / 9.0, accuracy: 0.02)
    }
}
