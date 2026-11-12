import XCTest
import CoreGraphics

final class MeetingToolbarLayoutTests: XCTestCase {
    private typealias L = MeetingToolbarLayout

    private func fit(host: Bool = true, _ width: CGFloat) -> L.Fit {
        L.fit(specs: L.specs(showsSecurity: host), width: width)
    }

    func testEverythingFitsWhenThereIsRoom() {
        let wide = fit(1600)
        XCTAssertEqual(wide.visible, [.mute, .video, .security, .people, .chat, .react, .share, .record, .notes])
        XCTAssertTrue(wide.overflow.isEmpty)
        XCTAssertTrue(wide.showsClock)
    }

    func testSecurityIsForHostsOnly() {
        XCTAssertFalse(fit(host: false, 1600).visible.contains(.security))
        XCTAssertTrue(fit(host: true, 1600).visible.contains(.security))
    }

    func testOrderIsMuteVideoThenMeetingToolsThenRecordNotes() {
        XCTAssertEqual(L.specs(showsSecurity: true).map(\.id),
                       [.mute, .video, .security, .people, .chat, .react, .share, .record, .notes])
        XCTAssertEqual(L.specs(showsSecurity: true).map(\.group), [0, 0, 1, 1, 1, 1, 1, 2, 2])
    }

    func testTheWidestFitIsTheExactRequirement() {
        let all = L.specs(showsSecurity: true)
        let need = L.required(items: all, showsClock: true)
        XCTAssertTrue(fit(need).overflow.isEmpty)
        XCTAssertFalse(fit(need - 1).overflow.isEmpty && fit(need - 1).showsClock,
                       "one point short must give something up")
    }

    func testNotesGoFirstThenRecordThenReact() {
        let all = L.specs(showsSecurity: true)
        let need = L.required(items: all, showsClock: true)
        XCTAssertEqual(fit(need - 1).overflow, [.notes])
        let withoutNotes = all.filter { $0.id != .notes }
        XCTAssertEqual(fit(L.required(items: withoutNotes, showsClock: true) - 1).overflow, [.record, .notes])
        let without2 = withoutNotes.filter { $0.id != .record }
        XCTAssertEqual(fit(L.required(items: without2, showsClock: true) - 1).overflow, [.react, .record, .notes])
    }

    func testTheClockGoesBeforeSecurityAndChat() {
        let all = L.specs(showsSecurity: true)
        let core = all.filter { ![.notes, .record, .react].contains($0.id) }
        let narrow = fit(L.required(items: core, showsClock: true) - 1)
        XCTAssertFalse(narrow.showsClock)
        XCTAssertEqual(narrow.overflow, [.react, .record, .notes])
        XCTAssertTrue(narrow.visible.contains(.security) && narrow.visible.contains(.chat))
    }

    func testMuteIsNeverDropped() {
        for width in stride(from: CGFloat(0), through: 1600, by: 20) {
            XCTAssertTrue(fit(width).visible.contains(.mute), "mute missing at \(width)")
        }
    }

    func testVisiblePlusOverflowIsAlwaysEverything() {
        for width in stride(from: CGFloat(100), through: 1700, by: 7) {
            let f = fit(width)
            XCTAssertEqual(Set(f.visible + f.overflow), Set(L.specs(showsSecurity: true).map(\.id)))
            XCTAssertEqual(f.visible.count + f.overflow.count, 9)
        }
    }

    func testNarrowerNeverShowsMore() {
        var previous = Int.max
        for width in stride(from: CGFloat(1700), through: 100, by: -5) {
            let count = fit(width).visible.count
            XCTAssertLessThanOrEqual(count, previous)
            previous = count
        }
    }

    func testTheWindowsMinimumWidthStillHasTheEssentials() {
        // The meeting window's minimum is 760pt.
        let f = fit(760)
        XCTAssertTrue(f.visible.starts(with: [.mute, .video]))
        XCTAssertTrue(f.visible.contains(.people) && f.visible.contains(.chat) && f.visible.contains(.share))
    }
}

final class MeetingShareRuleTests: XCTestCase {

    func testSdkValuesMapToTheTwoChoices() {
        // ZoomSDKErrors.h:1178-1186
        XCTAssertEqual(ShareRule(sdkRaw: 0), ShareRule(who: .everyone, concurrent: .one))
        XCTAssertEqual(ShareRule(sdkRaw: 1)?.who, .hostOnly)
        XCTAssertEqual(ShareRule(sdkRaw: 2), ShareRule(who: .everyone, concurrent: .one))
        XCTAssertEqual(ShareRule(sdkRaw: 3), ShareRule(who: .everyone, concurrent: .multiple))
        XCTAssertNil(ShareRule(sdkRaw: 4))
        XCTAssertNil(ShareRule(sdkRaw: 99))
    }

    func testChoicesMapBackToTheSdk() {
        XCTAssertEqual(ShareRule(who: .hostOnly, concurrent: .one).sdkRaw, 1)
        XCTAssertEqual(ShareRule(who: .hostOnly, concurrent: .multiple).sdkRaw, 1)
        XCTAssertEqual(ShareRule(who: .everyone, concurrent: .one).sdkRaw, 0)
        XCTAssertEqual(ShareRule(who: .everyone, concurrent: .multiple).sdkRaw, 3)
    }

    func testHostOnlyRemembersTheConcurrencyChoice() {
        XCTAssertEqual(ShareRule(sdkRaw: 1, remembering: .multiple)?.concurrent, .multiple)
        let back = ShareRule(sdkRaw: 1, remembering: .multiple)?.setting(who: .everyone)
        XCTAssertEqual(back?.sdkRaw, 3)
    }

    func testChatPrivilegeMapping() {
        // ZoomSDKErrors.h:1383-1395
        XCTAssertEqual(ChatWho.nobody.sdkRaw, 3)
        XCTAssertEqual(ChatWho.hostOnly.sdkRaw, 2)
        XCTAssertEqual(ChatWho.everyonePublicly.sdkRaw, 4)
        XCTAssertEqual(ChatWho.everyone.sdkRaw, 0)
        XCTAssertNil(ChatWho(sdkRaw: 1), "to-panelist is a webinar value")
        for who in ChatWho.allCases { XCTAssertEqual(ChatWho(sdkRaw: who.sdkRaw), who) }
    }

    // MARK: Which share is on the stage

    func testTheNewestSharerWins() {
        var s = ShareStageSelection()
        s.began(10)
        XCTAssertEqual(s.current, 10)
        s.began(20)
        XCTAssertEqual(s.current, 20)
        XCTAssertTrue(s.hasChoice)
    }

    func testAPickHoldsUntilSomeoneNewerStarts() {
        var s = ShareStageSelection()
        s.began(10); s.began(20)
        s.pick(10)
        XCTAssertEqual(s.current, 10)
        s.began(30)
        XCTAssertEqual(s.current, 30, "newest wins again")
    }

    func testWhenTheCurrentShareEndsTheNextNewestTakesOver() {
        var s = ShareStageSelection()
        s.began(10); s.began(20)
        s.ended(20)
        XCTAssertEqual(s.current, 10)
        s.ended(10)
        XCTAssertNil(s.current)
        XCTAssertFalse(s.hasChoice)
    }

    func testAPickedShareThatEndsFallsBackToNewest() {
        var s = ShareStageSelection()
        s.began(10); s.began(20); s.began(30)
        s.pick(10)
        s.ended(10)
        XCTAssertEqual(s.current, 30)
    }

    func testPickingAnUnknownSourceDoesNothing() {
        var s = ShareStageSelection()
        s.began(10)
        s.pick(99)
        XCTAssertEqual(s.current, 10)
    }

    func testTheSameSourceStartingAgainMovesToTheFront() {
        var s = ShareStageSelection()
        s.began(10); s.began(20); s.began(10)
        XCTAssertEqual(s.order, [20, 10])
        XCTAssertEqual(s.current, 10)
    }

    // MARK: The Zoom-app link

    func testZoomAppLinkFromAJoinURL() {
        let url = ZoomAppLink.make(joinURL: "https://us02web.zoom.us/j/82916390348?pwd=abcDEF123",
                                   number: "829 1639 0348", passcode: "plain")
        XCTAssertEqual(url?.absoluteString, "zoommtg://us02web.zoom.us/join?confno=82916390348&pwd=abcDEF123")
    }

    func testZoomAppLinkFallsBackToTheNumberAndPasscode() {
        let url = ZoomAppLink.make(joinURL: "", number: "829 1639 0348", passcode: "pass1")
        XCTAssertEqual(url?.absoluteString, "zoommtg://zoom.us/join?confno=82916390348&pwd=pass1")
        XCTAssertEqual(ZoomAppLink.make(joinURL: "", number: "829 1639 0348", passcode: "")?.absoluteString,
                       "zoommtg://zoom.us/join?confno=82916390348")
        XCTAssertNil(ZoomAppLink.make(joinURL: "", number: "", passcode: "x"))
    }
}

final class MeetingRoomLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testWaitingRoomIsLongestWaitingFirst() {
        var ledger = WaitingRoomLedger()
        ledger.arrived(3, at: t0.addingTimeInterval(10))
        ledger.arrived(1, at: t0.addingTimeInterval(30))
        ledger.arrived(2, at: t0.addingTimeInterval(20))
        let ordered = ledger.ordered([.init(id: 1, name: "Ana"), .init(id: 2, name: "Bo"), .init(id: 3, name: "Cy")])
        XCTAssertEqual(ordered.map(\.id), [3, 2, 1])
    }

    func testAnArrivalIsStampedOnceSoARepeatDoesNotMoveThemBack() {
        var ledger = WaitingRoomLedger()
        ledger.arrived(1, at: t0)
        ledger.arrived(2, at: t0.addingTimeInterval(5))
        ledger.arrived(1, at: t0.addingTimeInterval(60))
        XCTAssertEqual(ledger.ordered([.init(id: 2, name: "B"), .init(id: 1, name: "A")]).map(\.id), [1, 2])
    }

    func testPeopleThereBeforeWeWatchedGoFirstThenByNameThenId() {
        var ledger = WaitingRoomLedger()
        ledger.arrived(9, at: t0)
        let ordered = ledger.ordered([.init(id: 9, name: "Zed"), .init(id: 5, name: "bea"),
                                      .init(id: 4, name: "Ann"), .init(id: 6, name: "Ann")])
        XCTAssertEqual(ordered.map(\.id), [4, 6, 5, 9])
    }

    func testTheOrderDoesNotDependOnTheInputOrder() {
        var ledger = WaitingRoomLedger()
        ledger.arrived(1, at: t0); ledger.arrived(2, at: t0.addingTimeInterval(1))
        let people: [WaitingPerson] = [.init(id: 1, name: "A"), .init(id: 2, name: "B")]
        XCTAssertEqual(ledger.ordered(people), ledger.ordered(people.reversed()))
    }

    func testLeavingForgetsThem() {
        var ledger = WaitingRoomLedger()
        ledger.arrived(1, at: t0); ledger.arrived(2, at: t0.addingTimeInterval(5))
        ledger.left(1)
        ledger.arrived(1, at: t0.addingTimeInterval(99))
        XCTAssertEqual(ledger.ordered([.init(id: 1, name: "A"), .init(id: 2, name: "B")]).map(\.id), [2, 1])
        ledger.keep(only: [1])
        XCTAssertEqual(ledger.ordered([.init(id: 1, name: "A"), .init(id: 2, name: "B")]).map(\.id), [2, 1],
                       "2 is unstamped again, so it goes first")
    }

    func testReactionsLastThreeSecondsAndFeedbackStays() {
        var ledger = ReactionLedger()
        ledger.reacted(7, glyph: "\u{1F44D}", at: t0)
        ledger.gaveFeedback(7, label: "Slow down")
        XCTAssertEqual(ledger.reaction(for: 7, now: t0.addingTimeInterval(2.9)), "\u{1F44D}")
        XCTAssertNil(ledger.reaction(for: 7, now: t0.addingTimeInterval(3)))
        XCTAssertEqual(ledger.feedbackLabel(for: 7), "Slow down")
        ledger.canceledFeedback(7)
        XCTAssertNil(ledger.feedbackLabel(for: 7))
    }

    func testANewReactionRestartsTheClockAndPruneDropsTheGone() {
        var ledger = ReactionLedger()
        ledger.reacted(1, glyph: "a", at: t0)
        ledger.reacted(1, glyph: "b", at: t0.addingTimeInterval(2))
        XCTAssertEqual(ledger.reaction(for: 1, now: t0.addingTimeInterval(4)), "b")
        XCTAssertTrue(ledger.hasLiveReaction(now: t0.addingTimeInterval(4)))
        ledger.gaveFeedback(2, label: "Yes")
        ledger.prune(now: t0.addingTimeInterval(4), present: [2])
        XCTAssertNil(ledger.reaction(for: 1, now: t0.addingTimeInterval(4)))
        XCTAssertEqual(ledger.feedbackLabel(for: 2), "Yes")
    }

    func testSdkReactionAndFeedbackValuesBecomeWords() {
        XCTAssertNotNil(ReactionWords.glyph(reactionRaw: 1))
        XCTAssertNil(ReactionWords.glyph(reactionRaw: 0))
        XCTAssertEqual(ReactionWords.label(feedbackRaw: 3), "Speed up")
        XCTAssertEqual(ReactionWords.label(feedbackRaw: 4), "Slow down")
        XCTAssertNil(ReactionWords.label(feedbackRaw: 0))
    }

    func testWaitingToastWords() {
        XCTAssertEqual(WaitingRoomWords.joined("Ana", total: 1).title, "Ana is waiting to join")
        XCTAssertEqual(WaitingRoomWords.joined("", total: 3).title, "Someone is waiting to join")
        XCTAssertTrue(WaitingRoomWords.joined("Ana", total: 3).detail.contains("3 people"))
    }
}

final class MeetingMenuSpecTests: XCTestCase {

    private func entries(_ s: SecurityMenuState = .init(), _ a: SecurityMenuActions = .init()) -> [MenuEntry] {
        MeetingMenus.security(s, a)
    }

    func testSecurityHasEveryItemTheOwnerAskedFor() {
        let titles = entries(.init(canSuspend: true)).flatTitles
        for wanted in ["Lock meeting", "Enable waiting room", "Allow participants to", "Share screen", "Chat",
                       "Rename themselves", "Unmute themselves", "Start video",
                       "Suspend participant activities\u{2026}"] {
            XCTAssertTrue(titles.contains(wanted), "missing \(wanted)")
        }
    }

    func testSuspendOnlyWhenTheSdkOffersIt() {
        XCTAssertNil(entries(.init(canSuspend: false)).entry(titled: "Suspend participant activities\u{2026}"))
    }

    func testWaitingRoomOnlyWhenSupportedAndLockedWhenTheAccountPinsIt() {
        XCTAssertNil(entries(.init(waitingRoomSupported: false)).entry(titled: "Enable waiting room"))
        let pinned = entries(.init(waitingRoomOn: true, waitingRoomLocked: true)).entry(titled: "Enable waiting room")
        XCTAssertEqual(pinned?.enabled, false)
        XCTAssertEqual(pinned?.checked, true)
    }

    func testChecksReflectTheLiveState() {
        let on = entries(.init(locked: true, waitingRoomOn: true, shareRule: ShareRule(sdkRaw: 0),
                               chat: .hostOnly, rename: true, unmuteSelf: false, startVideo: true))
        XCTAssertEqual(on.entry(titled: "Lock meeting")?.checked, true)
        XCTAssertEqual(on.entry(titled: "Enable waiting room")?.checked, true)
        XCTAssertEqual(on.entry(titled: "Share screen")?.checked, true)
        XCTAssertEqual(on.entry(titled: "Rename themselves")?.checked, true)
        XCTAssertEqual(on.entry(titled: "Unmute themselves")?.checked, false)
        XCTAssertEqual(on.entry(titled: "Host only")?.checked, true)
        XCTAssertEqual(on.entry(titled: "No one")?.checked, false)

        let off = entries(.init(shareRule: ShareRule(sdkRaw: 1), chat: .nobody, rename: false, startVideo: false))
        XCTAssertEqual(off.entry(titled: "Share screen")?.checked, false)
        XCTAssertEqual(off.entry(titled: "Rename themselves")?.checked, false)
        XCTAssertEqual(off.entry(titled: "Start video")?.checked, false)
        XCTAssertEqual(off.entry(titled: "No one")?.checked, true)
    }

    func testChoosingAnItemFlipsIt() {
        var got: [String] = []
        var actions = SecurityMenuActions()
        actions.setLocked = { got.append("lock=\($0)") }
        actions.setWaitingRoom = { got.append("wait=\($0)") }
        actions.setRename = { got.append("rename=\($0)") }
        actions.setUnmuteSelf = { got.append("unmute=\($0)") }
        actions.setStartVideo = { got.append("video=\($0)") }
        actions.setChat = { got.append("chat=\($0.title)") }
        actions.setShareRule = { got.append("share=\($0.sdkRaw)") }
        let menu = entries(.init(locked: false, waitingRoomOn: true, shareRule: ShareRule(sdkRaw: 3),
                                 rename: true, unmuteSelf: false, startVideo: true), actions)
        for title in ["Lock meeting", "Enable waiting room", "Rename themselves", "Unmute themselves",
                      "Start video", "Share screen", "Host only"] {
            menu.entry(titled: title)?.action?()
        }
        XCTAssertEqual(got, ["lock=true", "wait=false", "rename=false", "unmute=true", "video=false",
                             "share=1", "chat=Host only"])
    }

    func testSharingAgainAfterHostOnlyRestoresTheLastConcurrency() {
        var got: [Int] = []
        var actions = SecurityMenuActions()
        actions.setShareRule = { got.append($0.sdkRaw) }
        MeetingMenus.security(.init(shareRule: ShareRule(sdkRaw: 1, remembering: .multiple)), actions)
            .entry(titled: "Share screen")?.action?()
        XCTAssertEqual(got, [3])
    }

    // MARK: Share menu

    private func share(_ s: MeetingMenus.ShareMenuState) -> [MenuEntry] {
        MeetingMenus.share(s, .init())
    }

    func testAGuestSeesOnlyTheirOwnShareItems() {
        let titles = share(.init(displays: [(1, "Display 1")], isHost: false)).flatMap(\.flatTitles)
        XCTAssertTrue(titles.contains("Display 1"))
        XCTAssertFalse(titles.contains("Who can share"))
    }

    func testTheHostSeesBothShareRules() {
        let menu = share(.init(displays: [(1, "Display 1")], isHost: true, rule: ShareRule(sdkRaw: 0)))
        XCTAssertEqual(menu.entry(titled: "All participants")?.checked, true)
        XCTAssertEqual(menu.entry(titled: "Only host")?.checked, false)
        XCTAssertEqual(menu.entry(titled: "One participant can share at a time")?.checked, true)
        XCTAssertEqual(menu.entry(titled: "Multiple participants can share simultaneously")?.checked, false)
        let multi = share(.init(isHost: true, rule: ShareRule(sdkRaw: 3)))
        XCTAssertEqual(multi.entry(titled: "Multiple participants can share simultaneously")?.checked, true)
    }

    func testHostOnlyDisablesTheConcurrencyChoice() {
        let menu = share(.init(isHost: true, rule: ShareRule(sdkRaw: 1)))
        XCTAssertEqual(menu.entry(titled: "Only host")?.checked, true)
        XCTAssertEqual(menu.entry(titled: "One participant can share at a time")?.enabled, false)
        XCTAssertEqual(menu.entry(titled: "One participant can share at a time")?.checked, false)
    }

    func testShareRuleItemsHandTheRightValueToTheSdk() {
        var got: [Int] = []
        var actions = MeetingMenus.ShareMenuActions()
        actions.setRule = { got.append($0.sdkRaw) }
        let menu = MeetingMenus.share(.init(isHost: true, rule: ShareRule(sdkRaw: 0)), actions)
        menu.entry(titled: "Only host")?.action?()
        menu.entry(titled: "Multiple participants can share simultaneously")?.action?()
        menu.entry(titled: "One participant can share at a time")?.action?()
        XCTAssertEqual(got, [1, 3, 0])
    }

    func testWhileSharingTheMenuOffersStopAndNotAnotherShare() {
        let menu = share(.init(sharing: true, displays: [(1, "Display 1")]))
        XCTAssertNotNil(menu.entry(titled: "Stop sharing"))
        XCTAssertNil(menu.entry(titled: "Display 1"))
    }

    func testShareItemsAreOffWithAReasonWhenSharingIsNotAllowed() {
        let menu = share(.init(displays: [(1, "Display 1")], cannotShare: "The host has locked sharing"))
        XCTAssertEqual(menu.entry(titled: "Display 1")?.enabled, false)
        XCTAssertEqual(menu.entry(titled: "Display 1")?.note, "The host has locked sharing")
    }

    func testTheShareHeaderSaysTheCameraPictureKeepsGoing() {
        let menu = share(.init(displays: [(1, "Display 1")]))
        XCTAssertTrue(menu.flatTitles.contains { $0.contains("as well as your camera picture") })
    }

    // MARK: More

    func testMoreListsOverflowThenMeetingInfoThenTheZoomApp() {
        let facts = MeetingMenus.MeetingFacts(number: "82916390348", passcode: "abc", joinURL: "https://zoom.us/j/1")
        let more = MeetingMenus.more(overflow: [.item("Notes") {}], facts: facts, .init())
        XCTAssertEqual(more.map(\.title).filter { !$0.isEmpty }, ["Notes", "Meeting info", "Open this meeting in the Zoom app\u{2026}"])
        let info = more.entry(titled: "Meeting info")?.children.map(\.title) ?? []
        XCTAssertTrue(info.contains("Meeting ID: 829 1639 0348"))
        XCTAssertTrue(info.contains("Passcode: abc"))
        XCTAssertTrue(info.contains("Copy invite link"))
    }

    func testMeetingInfoLinesCopyTheirRawValue() {
        var copied: [String] = []
        var actions = MeetingMenus.MoreMenuActions()
        actions.copy = { text, _ in copied.append(text) }
        let facts = MeetingMenus.MeetingFacts(number: "82916390348", passcode: "abc", joinURL: "https://zoom.us/j/82916390348?pwd=x")
        let more = MeetingMenus.more(overflow: [], facts: facts, actions)
        more.entry(titled: "Meeting ID: 829 1639 0348")?.action?()
        more.entry(titled: "Passcode: abc")?.action?()
        more.entry(titled: "Copy invite link")?.action?()
        XCTAssertEqual(copied, ["82916390348", "abc", "https://zoom.us/j/82916390348?pwd=x"])
    }

    func testMoreIsOffWithoutAnInvite() {
        let more = MeetingMenus.more(overflow: [], facts: .init(), .init())
        XCTAssertEqual(more.entry(titled: "Meeting info")?.enabled, false)
        XCTAssertEqual(more.entry(titled: "Open this meeting in the Zoom app\u{2026}")?.enabled, false)
    }

    func testAudioMenuOffersJoinAudioOnlyWhenNotOnAudio() {
        let mics = [MeetingMenus.Device(id: "m1", name: "Built-in Mic")]
        let spk = [MeetingMenus.Device(id: "s1", name: "Speakers"), .init(id: "s2", name: "Headphones")]
        let off = MeetingMenus.audio(hasAudio: false, mics: mics, micSelected: "m1", speakers: spk,
                                     speakerSelected: "s2", joinAudio: {}, pickMic: { _ in }, pickSpeaker: { _ in })
        XCTAssertEqual(off.first?.title, "Join audio")
        XCTAssertEqual(off.entry(titled: "Headphones")?.checked, true)
        XCTAssertEqual(off.entry(titled: "Speakers")?.checked, false)
        let on = MeetingMenus.audio(hasAudio: true, mics: mics, micSelected: "m1", speakers: spk,
                                    speakerSelected: "s1", joinAudio: {}, pickMic: { _ in }, pickSpeaker: { _ in })
        XCTAssertNil(on.entry(titled: "Join audio"))
        XCTAssertEqual(on.entry(titled: "Built-in Mic")?.checked, true)
    }
}
