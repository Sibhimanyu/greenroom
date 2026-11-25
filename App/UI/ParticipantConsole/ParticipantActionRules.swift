//
//  ParticipantActionRules.swift
//  Greenroom
//
//  Pure: which person controls a Participants row offers, and the host's
//  "..." menu at the foot of the list. Foundation only, test-compiled
//  (Tests/ParticipantActionRulesTests.swift holds the table).
//
//  One list for every surface: the Meeting window's drawer draws it as
//  buttons, a row's "..." and a click on a row in the Participants view window
//  draw it as a menu, and the row's hover button is `quick`. The SDK calls
//  behind each action live in ParticipantActionRunner.
//
//  Who may do what follows Zoom's own Participants panel:
//    - the host: everything, on anyone but themselves;
//    - a co-host: the same, except roles (make host, co-host), and nothing
//      that removes or renames the host;
//    - an attendee: pin, which only changes their own view;
//    - yourself: only what applies to you (spotlight yourself as host or
//      co-host, pin, lower your hand, rename when allowed). Your microphone
//      and camera are the toolbar's.
//
import Foundation

enum MeetingRole: Equatable { case host, coHost, attendee }

/// The person a row is about, as plain facts.
struct PersonFacts: Equatable {
    var isMe = false
    var isHost = false
    var isCoHost = false
    /// On the meeting's audio at all (not the same as unmuted).
    var hasAudio = true
    var muted = false
    var videoOn = true
    var spotlighted = false
    var pinned = false
    var handUp = false
}

/// The person looking at the list.
struct ViewerFacts: Equatable {
    var role: MeetingRole
    var waitingRoomAvailable = false
    /// "Allow participants to rename themselves" (an attendee renaming themselves).
    var renameAllowed = true
}

enum PersonAction: String, CaseIterable {
    case mute, askToUnmute, stopVideo, askToStartVideo
    case spotlight, removeSpotlight, pin, unpin, lowerHand, rename
    case makeCoHost, removeCoHost, putInWaitingRoom, makeHost
    case remove
}

enum ParticipantActionRules {

    /// Everything the row offers, in the order the drawer and the menu show it.
    static func actions(person p: PersonFacts, viewer v: ViewerFacts) -> [PersonAction] {
        let runsRoom = v.role != .attendee
        var out: [PersonAction] = []
        if p.isMe {
            if runsRoom { out.append(p.spotlighted ? .removeSpotlight : .spotlight) }
            out.append(p.pinned ? .unpin : .pin)
            if p.handUp { out.append(.lowerHand) }
            if runsRoom || v.renameAllowed { out.append(.rename) }
            return out
        }
        guard runsRoom else { return [p.pinned ? .unpin : .pin] }
        // A co-host does not act on the host's place in the meeting.
        let protected = v.role == .coHost && p.isHost
        if p.hasAudio { out.append(p.muted ? .askToUnmute : .mute) }
        out.append(p.videoOn ? .stopVideo : .askToStartVideo)
        out.append(p.spotlighted ? .removeSpotlight : .spotlight)
        out.append(p.pinned ? .unpin : .pin)
        if p.handUp { out.append(.lowerHand) }
        if protected { return out }
        out.append(.rename)
        if v.role == .host, !p.isHost { out.append(p.isCoHost ? .removeCoHost : .makeCoHost) }
        if v.waitingRoomAvailable, !p.isHost { out.append(.putInWaitingRoom) }
        if v.role == .host, !p.isHost { out.append(.makeHost) }
        if !p.isHost { out.append(.remove) }
        return out
    }

    /// The one button a row shows on hover, as Zoom's list does: Mute, or
    /// Ask to unmute. Never on your own row (the toolbar has yours).
    static func quick(person p: PersonFacts, viewer v: ViewerFacts) -> PersonAction? {
        guard !p.isMe, v.role != .attendee, p.hasAudio else { return nil }
        return p.muted ? .askToUnmute : .mute
    }

    static func title(_ action: PersonAction) -> String {
        switch action {
        case .mute: return "Mute"
        case .askToUnmute: return "Ask to unmute"
        case .stopVideo: return "Stop video"
        case .askToStartVideo: return "Ask to start video"
        case .spotlight: return "Spotlight for everyone"
        case .removeSpotlight: return "Remove spotlight"
        case .pin: return "Pin for me"
        case .unpin: return "Unpin"
        case .lowerHand: return "Lower hand"
        case .rename: return "Rename\u{2026}"
        case .makeCoHost: return "Make co-host"
        case .removeCoHost: return "Remove co-host"
        case .putInWaitingRoom: return "Put in waiting room"
        case .makeHost: return "Make host\u{2026}"
        case .remove: return "Remove\u{2026}"
        }
    }

    /// The row's hover button is short: no ellipsis, nothing after the verb.
    static func shortTitle(_ action: PersonAction) -> String {
        title(action).replacingOccurrences(of: "\u{2026}", with: "")
    }

    static func symbol(_ action: PersonAction) -> String {
        switch action {
        case .mute: return "mic.slash"
        case .askToUnmute: return "mic"
        case .stopVideo: return "video.slash"
        case .askToStartVideo: return "video"
        case .spotlight: return "star"
        case .removeSpotlight: return "star.slash"
        case .pin: return "pin"
        case .unpin: return "pin.slash"
        case .lowerHand: return "hand.raised.slash"
        case .rename: return "pencil"
        case .makeCoHost, .removeCoHost: return "person.2"
        case .putInWaitingRoom: return "door.left.hand.closed"
        case .makeHost: return "person.badge.key"
        case .remove: return "person.fill.xmark"
        }
    }

    /// The status line after it worked. Unmuting someone and starting their
    /// camera are requests in Zoom, so those say "Asked".
    static func sentence(_ action: PersonAction, name: String) -> String {
        switch action {
        case .mute: return "Muted \(name)"
        case .askToUnmute: return "Asked \(name) to unmute"
        case .stopVideo: return "Stopped \(name)'s video"
        case .askToStartVideo: return "Asked \(name) to start video"
        case .spotlight: return "Spotlighted \(name) for everyone"
        case .removeSpotlight: return "Removed \(name) from spotlight"
        case .pin: return "Pinned \(name) on this Mac only"
        case .unpin: return "Unpinned \(name)"
        case .lowerHand: return "Lowered \(name)'s hand"
        case .rename: return "Renamed \(name)"
        case .makeCoHost: return "\(name) is now a co-host"
        case .removeCoHost: return "\(name) is no longer a co-host"
        case .putInWaitingRoom: return "Sent \(name) back to the waiting room"
        case .makeHost: return "\(name) is now the host"
        case .remove: return "Removed \(name)"
        }
    }

    /// Asked first: only what cannot be undone from here. Putting someone in
    /// the waiting room is undone by Admit, so it does not ask.
    static func confirmation(_ action: PersonAction, name: String) -> (title: String, message: String, confirm: String)? {
        switch action {
        case .makeHost:
            return ("Make \(name) the host?",
                    "You become a co-host. You cannot take the host role back without the host key.",
                    "Make host")
        case .remove:
            return ("Remove \(name) from the meeting?", "They cannot rejoin this meeting.", "Remove")
        default:
            return nil
        }
    }

    static func isDestructive(_ action: PersonAction) -> Bool { action == .remove }

    /// What each action belongs with, for the menu's dividers.
    private static func group(_ action: PersonAction) -> Int {
        switch action {
        case .mute, .askToUnmute, .stopVideo, .askToStartVideo: return 0
        case .spotlight, .removeSpotlight, .pin, .unpin, .lowerHand, .rename: return 1
        case .makeCoHost, .removeCoHost, .putInWaitingRoom, .makeHost: return 2
        case .remove: return 3
        }
    }

    /// The actions as a menu, a divider between groups.
    static func menu(_ actions: [PersonAction], run: @escaping (PersonAction) -> Void) -> [MenuEntry] {
        var out: [MenuEntry] = []
        var last: Int?
        for action in actions {
            let g = group(action)
            if let last, last != g { out.append(.separator) }
            last = g
            out.append(.item(title(action)) { run(action) })
        }
        return out
    }
}

// MARK: - The footer's "..." (host and co-host)

/// What Zoom's Participants "..." offers a host, as far as the SDK reaches.
/// Left out because the SDK cannot do them or cannot read them back:
/// "Play sound when someone joins or leaves" (a setting with no getter, so the
/// checkmark could lie), "Allow participants to request to record"
/// (cloud/local recording is not used here), and "Merge to meeting window"
/// (the view window is its own place on purpose).
struct ParticipantsHostMenuState: Equatable {
    var muteOnEntryAvailable = false
    var muteOnEntry = false
    var unmuteSelf = true
    var rename = true
    var startVideo = true
    var handsUp = 0
    var waitingRoomSupported = true
    var waitingRoomOn = false
    /// The host's account setting can pin the waiting room on.
    var waitingRoomLocked = false
    var locked = false
}

struct ParticipantsHostMenuActions {
    var askAllToUnmute: () -> Void = {}
    var setMuteOnEntry: (Bool) -> Void = { _ in }
    var setUnmuteSelf: (Bool) -> Void = { _ in }
    var setRename: (Bool) -> Void = { _ in }
    var setStartVideo: (Bool) -> Void = { _ in }
    var lowerAllHands: () -> Void = {}
    var setWaitingRoom: (Bool) -> Void = { _ in }
    var setLocked: (Bool) -> Void = { _ in }
}

extension MeetingMenus {

    /// Each toggle shows the state as it is now and flips it when chosen,
    /// worded as the toolbar's Security menu words the same switches.
    static func participantsHost(_ s: ParticipantsHostMenuState, _ a: ParticipantsHostMenuActions) -> [MenuEntry] {
        var out: [MenuEntry] = [.item("Ask All to Unmute", a.askAllToUnmute)]
        if s.muteOnEntryAvailable {
            out.append(.item("Mute participants on entry", checked: s.muteOnEntry) { a.setMuteOnEntry(!s.muteOnEntry) })
        }
        out.append(.separator)
        out.append(.header("Allow participants to"))
        out.append(.item("Unmute themselves", checked: s.unmuteSelf) { a.setUnmuteSelf(!s.unmuteSelf) })
        out.append(.item("Rename themselves", checked: s.rename) { a.setRename(!s.rename) })
        out.append(.item("Start video", checked: s.startVideo) { a.setStartVideo(!s.startVideo) })
        if s.handsUp > 0 {
            out.append(.separator)
            out.append(.item("Lower all hands", a.lowerAllHands))
        }
        out.append(.separator)
        if s.waitingRoomSupported {
            out.append(.item("Enable waiting room", checked: s.waitingRoomOn, enabled: !s.waitingRoomLocked,
                             note: s.waitingRoomLocked ? "Set by your Zoom account" : nil) {
                a.setWaitingRoom(!s.waitingRoomOn)
            })
        }
        out.append(.item("Lock meeting", checked: s.locked) { a.setLocked(!s.locked) })
        return out
    }
}
