import AppKit

/// The Control bar's People button, as a small window of its own beside the bar
/// rather than the whole Meeting window (owner, 2026-11-16: "can also bring it
/// as a popup instead of triggering the entire zoom window"). It is the same
/// Participants panel the window has, fed by the same roster; once the Meeting
/// window is in view again it folds into the window's People panel, like the
/// chat pop-out, so the list is never in two places.
@MainActor
enum PeoplePopOutController {
    private static var window: NSWindow?
    /// The list the meeting window's grid feeds while the pop-out is open.
    private(set) static var view: MeetingPeopleView?

    static let size = NSSize(width: 320, height: 440)

    /// Opens beside the bar (`anchor`, AppKit coordinates), on the desktop in view.
    static func show(near anchor: NSRect?) {
        if window == nil {
            let people = MeetingPeopleView(frame: NSRect(origin: .zero, size: size))
            people.autoresizingMask = [.width, .height]
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            container.addSubview(people)
            let made = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            made.title = "Participants"
            made.contentView = container
            made.appearance = NSAppearance(named: .darkAqua)
            made.minSize = NSSize(width: 260, height: 260)
            made.isReleasedWhenClosed = false
            // On every desktop, full-screen ones too, like the bar it opens
            // from: `.moveToActiveSpace` left it on the desktop of Greenroom's
            // main window, out of sight (2026-11-16).
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            made.setFrame(frame(near: anchor, size: made.frame.size), display: false)
            // Only you see this window: a dark frost behind, opaque rows on top.
            WindowFrost.install(in: made, solid: MeetingTheme.windowNS)
            WindowShareController.attach(to: made, dark: true)
            window = made
            view = people
        }
        window?.orderFrontRegardless()
        ParticipantGridWindowController.refreshNow() // rows now, not on the next tick
    }

    static var isOpen: Bool { window?.isVisible ?? false }
    static var isOpenHere: Bool { isOpen && (window?.isOnActiveSpace ?? false) }

    /// Left on another desktop, it comes to this one.
    static func reveal() {
        guard let window else { return }
        if MeetingSurfaces.comesHereFirst(visible: window.isVisible, onActiveSpace: window.isOnActiveSpace) {
            window.orderOut(nil)
        }
        window.orderFrontRegardless()
    }

    static func close() {
        window?.close()
        window = nil
        view = nil
    }

    static func owns(_ candidate: NSWindow) -> Bool { candidate == window }

    /// A start alone goes straight to the bar and never builds the meeting
    /// window, whose grid is what fills this list. Until that window exists,
    /// the bar's one-second tick fills it straight from Zoom, so the waiting
    /// room can be answered from here (it was empty, 2026-11-16).
    static func feedWithoutWindow(client: ZoomMeetingSDKClient, controls: MeetingControlsModel) {
        guard let view, !ParticipantGridWindowController.isOpen else { return }
        let roster = client.meetingRoster()
        let myID = roster.first(where: \.isMyself)?.id
        func row(_ entry: ZoomMeetingSDKClient.RosterEntry) -> MeetingPeopleView.Row {
            var tags: [String] = []
            if entry.isHost { tags.append("Host") } else if entry.isCoHost { tags.append("Co-host") }
            if entry.isMyself { tags.append("me") }
            var entryRow = MeetingPeopleView.Row(
                id: entry.id, name: entry.name, tags: tags, detail: entry.isSpotlighted ? "spotlit" : "",
                handUp: entry.isRaisingHand, muted: entry.isMuted, hasAudio: entry.hasJoinedAudio,
                cameraOff: !entry.videoOn, selected: false)
            if entry.isMyself {
                entryRow.muted = client.iAmMuted
                entryRow.cameraOff = !client.myVideoIsOn
            }
            return entryRow
        }
        let hands = roster.filter { $0.isRaisingHand && !$0.isMyself }
        let handIDs = Set(hands.map(\.id))
        let mine = roster.filter(\.isMyself)
        let others = roster.filter { !$0.isMyself && !handIDs.contains($0.id) }
        let waiting = client.waitingRoomNames()
        func act(_ body: @escaping (ZoomMeetingSDKClient) -> Bool) -> () -> Void {
            { [weak client, weak controls] in
                guard let client else { return }
                _ = body(client)
                controls?.refresh()
            }
        }
        view.onSelect = { [weak controls] id in
            guard id != myID else { return }
            controls?.openPeopleInWindow()
        }
        view.onAdmit = { id in act { $0.admitFromWaitingRoom(userID: id) }() }
        view.onDeny = { id in act { $0.denyWaiting(userID: id) }() }
        view.onInvite = { [weak controls] in controls?.copyInviteLink() }
        view.onAdmitAll = act { $0.admitEveryoneWaiting() }
        view.onMuteAll = act { $0.muteEveryone() }
        view.onAskAllToUnmute = act { $0.askEveryoneToUnmute() }
        view.apply(waiting: waiting.map { .init(id: $0.id, name: $0.name) },
                   canDeny: client.canExpelFromWaitingRoom(),
                   isHost: client.roomFlags().iAmHostOrCoHost,
                   hands: hands.map(row),
                   everyone: (mine + others).map(row),
                   total: roster.count)
    }

    #if DEBUG
    static var debugRowCount: Int { view?.debugRowCount ?? -1 }
    #endif

    /// Under the bar's right end when the bar is in the top half of its screen,
    /// above it otherwise; kept on the screen. Centred with no bar to go by.
    private static func frame(near anchor: NSRect?, size: NSSize) -> NSRect {
        guard let anchor,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else {
            let area = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        return PeoplePopOutPlacement.frame(size: size, bar: anchor, area: screen.visibleFrame)
    }
}
