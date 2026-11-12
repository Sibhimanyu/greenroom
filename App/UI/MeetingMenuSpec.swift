//
//  MeetingMenuSpec.swift
//  Greenroom
//
//  The toolbar's menus as data. A menu is a list of entries (a checkmark item,
//  a header, a divider, a submenu); a separate AppKit file turns that into an
//  NSMenu to pop, and the off-screen render draws the same list. Keeping the
//  content apart from NSMenu is what makes "each Security item reflects live
//  state" something a test can check.
//
import Foundation

struct MenuEntry {
    enum Kind { case item, header, separator, submenu }

    var kind: Kind
    var title = ""
    var checked = false
    var enabled = true
    /// A second, quieter line (or the reason an item is off).
    var note: String?
    var children: [MenuEntry] = []
    var action: (() -> Void)?

    static func item(_ title: String, checked: Bool = false, enabled: Bool = true,
                     note: String? = nil, _ action: @escaping () -> Void) -> MenuEntry {
        MenuEntry(kind: .item, title: title, checked: checked, enabled: enabled, note: note, action: action)
    }
    static func header(_ title: String) -> MenuEntry { MenuEntry(kind: .header, title: title) }
    static var separator: MenuEntry { MenuEntry(kind: .separator) }
    static func submenu(_ title: String, enabled: Bool = true, _ children: [MenuEntry]) -> MenuEntry {
        MenuEntry(kind: .submenu, title: title, enabled: enabled, children: children)
    }

    /// Titles of the real items, top to bottom, for tests.
    var flatTitles: [String] {
        switch kind {
        case .item, .header: return [title]
        case .separator: return []
        case .submenu: return [title] + children.flatMap(\.flatTitles)
        }
    }
}

extension Array where Element == MenuEntry {
    var flatTitles: [String] { flatMap(\.flatTitles) }

    func entry(titled title: String) -> MenuEntry? {
        for entry in self {
            if entry.title == title { return entry }
            if let found = entry.children.entry(titled: title) { return found }
        }
        return nil
    }
}

// MARK: - Security (host and co-host)

struct SecurityMenuState: Equatable {
    var locked = false
    var waitingRoomSupported = true
    var waitingRoomOn = false
    /// The host's account setting can pin the waiting room on.
    var waitingRoomLocked = false
    /// Nil when the SDK would not say.
    var shareRule: ShareRule?
    var chat: ChatWho = .everyone
    var rename = true
    var unmuteSelf = true
    var startVideo = true
    var canSuspend = false
}

struct SecurityMenuActions {
    var setLocked: (Bool) -> Void = { _ in }
    var setWaitingRoom: (Bool) -> Void = { _ in }
    var setShareRule: (ShareRule) -> Void = { _ in }
    var setChat: (ChatWho) -> Void = { _ in }
    var setRename: (Bool) -> Void = { _ in }
    var setUnmuteSelf: (Bool) -> Void = { _ in }
    var setStartVideo: (Bool) -> Void = { _ in }
    var suspend: () -> Void = {}
}

enum MeetingMenus {

    /// Every toggle is a checkmark item that shows the state as it is now, and
    /// flips it when chosen.
    static func security(_ s: SecurityMenuState, _ a: SecurityMenuActions,
                         lastConcurrent: ConcurrentShare = .one) -> [MenuEntry] {
        var out: [MenuEntry] = [
            .item("Lock meeting", checked: s.locked) { a.setLocked(!s.locked) },
        ]
        if s.waitingRoomSupported {
            out.append(.item("Enable waiting room", checked: s.waitingRoomOn,
                             enabled: !s.waitingRoomLocked,
                             note: s.waitingRoomLocked ? "Set by your Zoom account" : nil) {
                a.setWaitingRoom(!s.waitingRoomOn)
            })
        }
        out.append(.separator)
        out.append(.header("Allow participants to"))

        let sharing = s.shareRule.map { $0.who == .everyone }
        out.append(.item("Share screen", checked: sharing ?? false, enabled: s.shareRule != nil) {
            let rule = s.shareRule ?? ShareRule(who: .everyone, concurrent: lastConcurrent)
            a.setShareRule(rule.setting(who: rule.who == .everyone ? .hostOnly : .everyone))
        })
        out.append(.submenu("Chat", chatChildren(s, a)))
        out.append(.item("Rename themselves", checked: s.rename) { a.setRename(!s.rename) })
        out.append(.item("Unmute themselves", checked: s.unmuteSelf) { a.setUnmuteSelf(!s.unmuteSelf) })
        out.append(.item("Start video", checked: s.startVideo) { a.setStartVideo(!s.startVideo) })

        if s.canSuspend {
            out.append(.separator)
            out.append(.item("Suspend participant activities\u{2026}", a.suspend))
        }
        return out
    }

    private static func chatChildren(_ s: SecurityMenuState, _ a: SecurityMenuActions) -> [MenuEntry] {
        ChatWho.allCases.map { who in
            .item(who.title, checked: s.chat == who) { a.setChat(who) }
        }
    }

    // MARK: Audio and camera (the carets beside Mute and Stop Video)

    struct Device: Equatable {
        var id: String
        var name: String
    }

    /// Microphone and speaker, and a way back onto the meeting's audio when this
    /// Mac is not on it (a different state from muted).
    static func audio(hasAudio: Bool, mics: [Device], micSelected: String?,
                      speakers: [Device], speakerSelected: String?,
                      joinAudio: @escaping () -> Void,
                      pickMic: @escaping (Device) -> Void,
                      pickSpeaker: @escaping (Device) -> Void) -> [MenuEntry] {
        var out: [MenuEntry] = []
        if !hasAudio {
            out.append(.item("Join audio", joinAudio))
            out.append(.separator)
        }
        out.append(.header("Microphone"))
        out += mics.map { d in .item(d.name, checked: d.id == micSelected) { pickMic(d) } }
        if mics.isEmpty { out.append(.item("No microphone found", enabled: false) {}) }
        out.append(.separator)
        out.append(.header("Speaker"))
        out += speakers.map { d in .item(d.name, checked: d.id == speakerSelected) { pickSpeaker(d) } }
        if speakers.isEmpty { out.append(.item("No speaker found", enabled: false) {}) }
        return out
    }

    /// Greenroom sends its own picture as the camera, so the note says what
    /// choosing another one does.
    static func video(cameras: [Device], selected: String?,
                      pick: @escaping (Device) -> Void) -> [MenuEntry] {
        var out: [MenuEntry] = [.header("Camera")]
        out += cameras.map { d in .item(d.name, checked: d.id == selected) { pick(d) } }
        if cameras.isEmpty { out.append(.item("No camera found", enabled: false) {}) }
        out.append(.separator)
        out.append(.item("Greenroom sends its own picture as your camera", enabled: false) {})
        return out
    }

    // MARK: React

    static func react(handRaised: Bool, reactions: [String],
                      toggleHand: @escaping () -> Void,
                      send: @escaping (String) -> Void) -> [MenuEntry] {
        [.item(handRaised ? "Lower my hand" : "Raise my hand", toggleHand), .separator]
            + reactions.map { name in .item(name) { send(name) } }
    }

    // MARK: Share

    struct ShareMenuState {
        var inMeeting = true
        /// You are sharing now.
        var sharing = false
        var displays: [(id: UInt32, label: String)] = []
        /// The reason sharing cannot start, if it cannot ("Sharing is locked").
        var cannotShare: String?
        var isHost = false
        var rule: ShareRule?
    }

    struct ShareMenuActions {
        var shareDisplay: (UInt32) -> Void = { _ in }
        var stop: () -> Void = {}
        var setRule: (ShareRule) -> Void = { _ in }
    }

    /// Zoom's share here is a whole display sent as its own thing. Greenroom's
    /// camera picture keeps running underneath, so the wording says "as well".
    static func share(_ s: ShareMenuState, _ a: ShareMenuActions,
                      lastConcurrent: ConcurrentShare = .one) -> [MenuEntry] {
        var out: [MenuEntry] = []
        if s.sharing {
            out.append(.item("Stop sharing", a.stop))
        } else {
            out.append(.header("Share a display, as well as your camera picture"))
            for display in s.displays {
                out.append(.item(display.label, enabled: s.inMeeting && s.cannotShare == nil,
                                 note: s.cannotShare) { a.shareDisplay(display.id) })
            }
            if s.displays.isEmpty {
                out.append(.item("No display to share", enabled: false) {})
            }
        }
        guard s.isHost else { return out }
        let rule = s.rule
        out.append(.separator)
        out.append(.header("Who can share"))
        out.append(.item("Only host", checked: rule?.who == .hostOnly, enabled: rule != nil) {
            a.setRule((rule ?? ShareRule(who: .everyone, concurrent: lastConcurrent)).setting(who: .hostOnly))
        })
        out.append(.item("All participants", checked: rule?.who == .everyone, enabled: rule != nil) {
            a.setRule((rule ?? ShareRule(who: .everyone, concurrent: lastConcurrent)).setting(who: .everyone))
        })
        out.append(.separator)
        out.append(.header("When someone is sharing"))
        let concurrentOn = rule?.who == .everyone
        out.append(.item("One participant can share at a time",
                         checked: concurrentOn && rule?.concurrent == .one, enabled: concurrentOn) {
            a.setRule(ShareRule(who: .everyone, concurrent: .one))
        })
        out.append(.item("Multiple participants can share simultaneously",
                         checked: concurrentOn && rule?.concurrent == .multiple, enabled: concurrentOn) {
            a.setRule(ShareRule(who: .everyone, concurrent: .multiple))
        })
        return out
    }

    // MARK: More

    struct MeetingFacts: Equatable {
        var number = ""
        var passcode = ""
        var joinURL = ""
        var hasInvite: Bool { !number.isEmpty || !joinURL.isEmpty }
    }

    struct MoreMenuActions {
        var copy: (String, String) -> Void = { _, _ in }   // (text, what it was)
        var openInZoom: () -> Void = {}
        /// Shrink the meeting window to the floating bar. Nil where there is no such window.
        var shrink: (() -> Void)?
    }

    /// The controls that did not fit, then Meeting info and the Zoom app. Meeting
    /// info is a submenu of copyable lines, so no dialog has to take focus.
    static func more(overflow: [MenuEntry], facts: MeetingFacts, _ a: MoreMenuActions) -> [MenuEntry] {
        var out = overflow
        if !out.isEmpty { out.append(.separator) }
        var info: [MenuEntry] = []
        if !facts.number.isEmpty {
            info.append(.item("Meeting ID: \(spaced(facts.number))") { a.copy(facts.number, "Meeting ID") })
        }
        if !facts.passcode.isEmpty {
            info.append(.item("Passcode: \(facts.passcode)") { a.copy(facts.passcode, "Passcode") })
        }
        if !facts.joinURL.isEmpty {
            info.append(.item("Invite link: \(abbreviated(facts.joinURL))") { a.copy(facts.joinURL, "Invite link") })
            info.append(.separator)
            info.append(.item("Copy invite link") { a.copy(facts.joinURL, "Invite link") })
        }
        if let shrink = a.shrink { out.append(.item("Shrink to the control bar", shrink)) }
        out.append(.submenu("Meeting info", enabled: facts.hasInvite, info))
        out.append(.item("Open this meeting in the Zoom app\u{2026}",
                         enabled: facts.hasInvite,
                         note: "For breakout rooms, polls and captions",
                         a.openInZoom))
        return out
    }

    /// "829 1639 0348" reads better than ten bare digits.
    static func spaced(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        guard digits.count >= 9 else { return number }
        let head = digits.prefix(3), mid = digits.dropFirst(3).prefix(4), tail = digits.dropFirst(7)
        return [head, mid, tail].map(String.init).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func abbreviated(_ link: String, limit: Int = 44) -> String {
        link.count <= limit ? link : String(link.prefix(limit - 1)) + "\u{2026}"
    }
}
