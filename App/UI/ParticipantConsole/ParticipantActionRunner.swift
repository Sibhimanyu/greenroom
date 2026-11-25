//
//  ParticipantActionRunner.swift
//  Greenroom
//
//  What each person control does, and the rows and menus every Participants
//  list is built from. ParticipantActionRules decides which controls a row
//  offers; this file makes the SDK call behind each one, asks first where the
//  rules say so, and turns the list into a menu or a row. The Meeting window's
//  drawer, its People panel, the bar's People pop-out and the Participants
//  view window all come through here, so a control means the same everywhere.
//
//  A surface supplies two things: how to run an action (its own status line
//  and redraw) and how to show an alert (the Meeting window steps its panel
//  down first, see RootView.runAboveEverything).
//
import AppKit

@MainActor
enum ParticipantActionRunner {

    typealias Entry = ZoomMeetingSDKClient.RosterEntry

    struct Surface {
        /// Runs the SDK call and reports `sentence` (or the refusal).
        var perform: (_ sentence: String, _ body: (ZoomMeetingSDKClient) -> Bool) -> Void
        var runAlert: (NSAlert) -> NSApplication.ModalResponse = ParticipantActionRunner.plainAlert
    }

    /// An alert for a window at the normal level: Greenroom comes forward for
    /// the one moment a question needs an answer.
    static func plainAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    // MARK: Facts

    static func facts(_ e: Entry) -> PersonFacts {
        PersonFacts(isMe: e.isMyself, isHost: e.isHost, isCoHost: e.isCoHost, hasAudio: e.hasJoinedAudio,
                    muted: e.isMuted, videoOn: e.videoOn, spotlighted: e.isSpotlighted, pinned: e.isPinned,
                    handUp: e.isRaisingHand)
    }

    static func viewer(me: Entry?, client: ZoomMeetingSDKClient) -> ViewerFacts {
        let role: MeetingRole = me?.isHost == true ? .host : (me?.isCoHost == true ? .coHost : .attendee)
        return ViewerFacts(role: role, waitingRoomAvailable: client.waitingRoomAvailable,
                           renameAllowed: client.roomFlags().renameAllowed)
    }

    /// One row of a Participants list, the hover button included.
    static func row(_ e: Entry, viewer: ViewerFacts, selected: Bool = false) -> MeetingParticipantRow {
        var tags: [String] = []
        if e.isHost { tags.append("Host") } else if e.isCoHost { tags.append("Co-host") }
        if e.isMyself { tags.append("me") }
        let person = facts(e)
        return MeetingParticipantRow(
            id: e.id, name: e.name, tags: tags, detail: e.isSpotlighted ? "spotlit" : "",
            handUp: e.isRaisingHand, muted: e.isMuted, hasAudio: e.hasJoinedAudio, cameraOff: !e.videoOn,
            selected: selected,
            quick: ParticipantActionRules.quick(person: person, viewer: viewer).map(ParticipantActionRules.shortTitle),
            hasMore: !ParticipantActionRules.actions(person: person, viewer: viewer).isEmpty)
    }

    // MARK: One person

    /// The person's controls as a menu, read fresh from Zoom at the click.
    static func menu(userID: UInt32, client: ZoomMeetingSDKClient, surface: Surface) -> [MenuEntry] {
        let roster = client.meetingRoster()
        guard let entry = roster.first(where: { $0.id == userID }) else { return [] }
        let viewer = viewer(me: roster.first(where: \.isMyself), client: client)
        let actions = ParticipantActionRules.actions(person: facts(entry), viewer: viewer)
        return ParticipantActionRules.menu(actions) { run($0, on: entry, surface: surface) }
    }

    /// The row's hover button (Mute, or Ask to unmute).
    static func runQuick(userID: UInt32, client: ZoomMeetingSDKClient, surface: Surface) {
        let roster = client.meetingRoster()
        guard let entry = roster.first(where: { $0.id == userID }),
              let action = ParticipantActionRules.quick(
                person: facts(entry), viewer: viewer(me: roster.first(where: \.isMyself), client: client))
        else { return }
        run(action, on: entry, surface: surface)
    }

    static func run(_ action: PersonAction, on entry: Entry, surface: Surface) {
        let id = entry.id
        let sentence = ParticipantActionRules.sentence(action, name: entry.name)
        if action == .rename {
            prompt(title: "Rename \(entry.name)", current: entry.name, surface: surface) { newName in
                surface.perform("\(sentence) to \(newName)") { $0.rename(userID: id, to: newName) }
            }
            return
        }
        let body: (ZoomMeetingSDKClient) -> Bool
        switch action {
        case .mute: body = { $0.setMuted(true, userID: id) }
        case .askToUnmute: body = { $0.setMuted(false, userID: id) }
        case .stopVideo: body = { $0.setVideoMuted(true, userID: id) }
        case .askToStartVideo: body = { $0.setVideoMuted(false, userID: id) }
        case .spotlight: body = { $0.spotlight(true, userID: id) }
        case .removeSpotlight: body = { $0.spotlight(false, userID: id) }
        case .pin: body = { $0.pin(true, userID: id) }
        case .unpin: body = { $0.pin(false, userID: id) }
        case .lowerHand: body = { $0.lowerHand(userID: id) }
        case .makeCoHost: body = { $0.setCoHost(true, userID: id) }
        case .removeCoHost: body = { $0.setCoHost(false, userID: id) }
        case .putInWaitingRoom: body = { $0.putInWaitingRoom(userID: id) }
        case .makeHost: body = { $0.makeHost(userID: id) }
        case .remove: body = { $0.expel(userID: id) }
        case .rename: return
        }
        if let ask = ParticipantActionRules.confirmation(action, name: entry.name) {
            let alert = NSAlert()
            alert.messageText = ask.title
            alert.informativeText = ask.message
            alert.addButton(withTitle: ask.confirm)
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard surface.runAlert(alert) == .alertFirstButtonReturn else { return }
        }
        surface.perform(sentence, body)
    }

    private static func prompt(title: String, current: String, surface: Surface, action: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        let response = surface.runAlert(alert)
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if response == .alertFirstButtonReturn, !trimmed.isEmpty, trimmed != current { action(trimmed) }
    }

    // MARK: The footer's "..."

    /// The host's room-wide switches, read fresh from Zoom as the menu opens.
    static func hostMenu(client: ZoomMeetingSDKClient, surface: Surface) -> [MenuEntry] {
        let security = client.securityState()
        var s = ParticipantsHostMenuState()
        s.muteOnEntryAvailable = client.muteOnEntryAvailable
        s.muteOnEntry = client.muteOnEntryOn
        s.unmuteSelf = security.unmuteSelf
        s.rename = security.rename
        s.startVideo = security.startVideo
        s.handsUp = client.meetingRoster().filter { $0.isRaisingHand && !$0.isMyself }.count
        s.waitingRoomSupported = security.waitingRoomSupported
        s.waitingRoomOn = security.waitingRoomOn
        s.waitingRoomLocked = security.waitingRoomLocked
        s.locked = security.locked
        var a = ParticipantsHostMenuActions()
        a.askAllToUnmute = { surface.perform("Asked everyone to unmute") { $0.askEveryoneToUnmute() } }
        a.setMuteOnEntry = { on in
            surface.perform(on ? "Mute on entry on" : "Mute on entry off") { $0.setMuteOnEntry(on) }
        }
        a.setUnmuteSelf = { on in
            surface.perform(on ? "Participants can unmute themselves" : "Participants can no longer unmute themselves") {
                $0.setAllowUnmuteSelf(on)
            }
        }
        a.setRename = { on in
            surface.perform(on ? "Participants can rename themselves" : "Participants can no longer rename themselves") {
                $0.setAllowRename(on)
            }
        }
        a.setStartVideo = { on in
            surface.perform(on ? "Participants can start their video" : "Participants can no longer start their video") {
                $0.setAllowStartVideo(on)
            }
        }
        a.lowerAllHands = { surface.perform("Lowered all hands") { $0.lowerEveryHand() } }
        a.setWaitingRoom = { on in surface.perform(on ? "Waiting room on" : "Waiting room off") { $0.setWaitingRoomOn(on) } }
        a.setLocked = { on in surface.perform(on ? "Meeting locked" : "Meeting unlocked") { $0.setMeetingLocked(on) } }
        return MeetingMenus.participantsHost(s, a)
    }
}
