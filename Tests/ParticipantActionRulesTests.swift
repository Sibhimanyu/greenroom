import XCTest

/// Which person controls a Participants row offers, for each viewer and each
/// person (ParticipantActionRules). One table, read as a whole: the drawer in
/// the Meeting window, the row's hover Mute and "..." and the Participants
/// view window all take their list from these rules.
final class ParticipantActionRulesTests: XCTestCase {

    typealias A = PersonAction

    private func person(me: Bool = false, host: Bool = false, coHost: Bool = false, audio: Bool = true,
                        muted: Bool = false, video: Bool = true, spotlit: Bool = false, pinned: Bool = false,
                        hand: Bool = false) -> PersonFacts {
        PersonFacts(isMe: me, isHost: host, isCoHost: coHost, hasAudio: audio, muted: muted, videoOn: video,
                    spotlighted: spotlit, pinned: pinned, handUp: hand)
    }

    private func viewer(_ role: MeetingRole, waitingRoom: Bool = true, renameAllowed: Bool = true) -> ViewerFacts {
        ViewerFacts(role: role, waitingRoomAvailable: waitingRoom, renameAllowed: renameAllowed)
    }

    func testTheTable() {
        let rows: [(String, PersonFacts, ViewerFacts, [A])] = [
            ("host on an attendee", person(), viewer(.host),
             [.mute, .stopVideo, .spotlight, .pin, .rename, .makeCoHost, .putInWaitingRoom, .makeHost, .remove]),
            ("host on a muted attendee, camera off, hand up", person(muted: true, video: false, hand: true), viewer(.host),
             [.askToUnmute, .askToStartVideo, .spotlight, .pin, .lowerHand, .rename, .makeCoHost, .putInWaitingRoom, .makeHost, .remove]),
            ("host on someone not on audio", person(audio: false), viewer(.host),
             [.stopVideo, .spotlight, .pin, .rename, .makeCoHost, .putInWaitingRoom, .makeHost, .remove]),
            ("host on a co-host, spotlit and pinned", person(coHost: true, spotlit: true, pinned: true), viewer(.host),
             [.mute, .stopVideo, .removeSpotlight, .unpin, .rename, .removeCoHost, .putInWaitingRoom, .makeHost, .remove]),
            ("host with no waiting room", person(), viewer(.host, waitingRoom: false),
             [.mute, .stopVideo, .spotlight, .pin, .rename, .makeCoHost, .makeHost, .remove]),
            ("co-host on an attendee", person(), viewer(.coHost),
             [.mute, .stopVideo, .spotlight, .pin, .rename, .putInWaitingRoom, .remove]),
            ("co-host on the host", person(host: true), viewer(.coHost),
             [.mute, .stopVideo, .spotlight, .pin]),
            ("attendee on anyone", person(hand: true), viewer(.attendee),
             [.pin]),
            ("host on me", person(me: true, host: true), viewer(.host),
             [.spotlight, .pin, .rename]),
            ("host on me, hand up", person(me: true, host: true, hand: true), viewer(.host),
             [.spotlight, .pin, .lowerHand, .rename]),
            ("attendee on me, rename allowed", person(me: true, hand: true), viewer(.attendee),
             [.pin, .lowerHand, .rename]),
            ("attendee on me, rename not allowed", person(me: true), viewer(.attendee, renameAllowed: false),
             [.pin]),
        ]
        var failures: [String] = []
        for (name, p, v, expected) in rows {
            let got = ParticipantActionRules.actions(person: p, viewer: v)
            if got != expected { failures.append("\(name): got \(got), want \(expected)") }
        }
        XCTAssert(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testQuickButton() {
        let rows: [(String, PersonFacts, ViewerFacts, A?)] = [
            ("host, unmuted attendee", person(), viewer(.host), .mute),
            ("host, muted attendee", person(muted: true), viewer(.host), .askToUnmute),
            ("co-host, attendee", person(), viewer(.coHost), .mute),
            ("host, not on audio", person(audio: false), viewer(.host), nil),
            ("never for yourself", person(me: true, host: true), viewer(.host), nil),
            ("attendee viewer", person(), viewer(.attendee), nil),
        ]
        for (name, p, v, expected) in rows {
            XCTAssertEqual(ParticipantActionRules.quick(person: p, viewer: v), expected, name)
        }
    }

    func testEveryActionHasWordsAndASymbol() {
        for action in PersonAction.allCases {
            XCTAssertFalse(ParticipantActionRules.title(action).isEmpty, "\(action)")
            XCTAssertFalse(ParticipantActionRules.symbol(action).isEmpty, "\(action)")
            XCTAssertFalse(ParticipantActionRules.sentence(action, name: "Ana").isEmpty, "\(action)")
        }
        // Unmuting and starting someone's camera are requests in Zoom, and say so.
        XCTAssertEqual(ParticipantActionRules.title(.askToUnmute), "Ask to unmute")
        XCTAssertEqual(ParticipantActionRules.sentence(.askToUnmute, name: "Ana"), "Asked Ana to unmute")
        XCTAssertEqual(ParticipantActionRules.title(.askToStartVideo), "Ask to start video")
        // Only the ones that cannot be undone from here ask first.
        let confirmed = PersonAction.allCases.filter { ParticipantActionRules.confirmation($0, name: "Ana") != nil }
        XCTAssertEqual(confirmed, [.makeHost, .remove])
        XCTAssertTrue(ParticipantActionRules.isDestructive(.remove))
        XCTAssertFalse(ParticipantActionRules.isDestructive(.putInWaitingRoom))
    }

    func testPersonMenuGroupsAndRuns() {
        var ran: [A] = []
        let actions: [A] = [.mute, .stopVideo, .spotlight, .pin, .rename, .makeCoHost, .putInWaitingRoom, .makeHost, .remove]
        let menu = ParticipantActionRules.menu(actions) { ran.append($0) }
        XCTAssertEqual(menu.flatTitles, ["Mute", "Stop video", "Spotlight for everyone", "Pin for me", "Rename\u{2026}",
                                         "Make co-host", "Put in waiting room", "Make host\u{2026}", "Remove\u{2026}"])
        // Groups: audio and video, then view, then roles, then remove.
        XCTAssertEqual(menu.map { $0.kind == .separator }, [false, false, true, false, false, false, true,
                                                             false, false, false, true, false])
        menu.entry(titled: "Mute")?.action?()
        menu.entry(titled: "Remove\u{2026}")?.action?()
        XCTAssertEqual(ran, [.mute, .remove])
        XCTAssertTrue(ParticipantActionRules.menu([]) { _ in }.isEmpty)
    }

    // MARK: The footer's "..." (host and co-host)

    func testHostMenuListsWhatZoomOffers() {
        var s = ParticipantsHostMenuState()
        s.muteOnEntryAvailable = true
        s.handsUp = 2
        let menu = MeetingMenus.participantsHost(s, ParticipantsHostMenuActions())
        XCTAssertEqual(menu.flatTitles, [
            "Ask All to Unmute", "Mute participants on entry",
            "Allow participants to", "Unmute themselves", "Rename themselves", "Start video",
            "Lower all hands",
            "Enable waiting room", "Lock meeting",
        ])
    }

    func testHostMenuShowsStateAndFlipsIt() {
        var s = ParticipantsHostMenuState()
        s.unmuteSelf = false
        s.rename = true
        s.locked = true
        s.waitingRoomOn = true
        var log: [String] = []
        var a = ParticipantsHostMenuActions()
        a.setUnmuteSelf = { log.append("unmuteSelf \($0)") }
        a.setRename = { log.append("rename \($0)") }
        a.setLocked = { log.append("locked \($0)") }
        a.setWaitingRoom = { log.append("waiting \($0)") }
        a.askAllToUnmute = { log.append("ask all") }
        let menu = MeetingMenus.participantsHost(s, a)
        XCTAssertEqual(menu.entry(titled: "Unmute themselves")?.checked, false)
        XCTAssertEqual(menu.entry(titled: "Rename themselves")?.checked, true)
        XCTAssertEqual(menu.entry(titled: "Lock meeting")?.checked, true)
        XCTAssertEqual(menu.entry(titled: "Enable waiting room")?.checked, true)
        for title in ["Ask All to Unmute", "Unmute themselves", "Rename themselves", "Lock meeting", "Enable waiting room"] {
            menu.entry(titled: title)?.action?()
        }
        XCTAssertEqual(log, ["ask all", "unmuteSelf true", "rename false", "locked false", "waiting false"])
    }

    func testHostMenuLeavesOutWhatThisMeetingCannotDo() {
        var s = ParticipantsHostMenuState()
        s.muteOnEntryAvailable = false
        s.waitingRoomSupported = false
        s.handsUp = 0
        let titles = MeetingMenus.participantsHost(s, ParticipantsHostMenuActions()).flatTitles
        XCTAssertFalse(titles.contains("Mute participants on entry"))
        XCTAssertFalse(titles.contains("Enable waiting room"))
        XCTAssertFalse(titles.contains("Lower all hands"))
        // The account can pin the waiting room on: shown, greyed, with the reason.
        s.waitingRoomSupported = true
        s.waitingRoomLocked = true
        let entry = MeetingMenus.participantsHost(s, ParticipantsHostMenuActions()).entry(titled: "Enable waiting room")
        XCTAssertEqual(entry?.enabled, false)
        XCTAssertEqual(entry?.note, "Set by your Zoom account")
    }
}
