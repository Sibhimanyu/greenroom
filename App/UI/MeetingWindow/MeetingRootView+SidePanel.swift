//
//  MeetingRootView+SidePanel.swift
//  Greenroom
//
//  The side panel: People rows, the console state, the queue and Cues, and the selected person's context bar.
//
import AppKit
import SwiftUI
import Combine

@MainActor
extension MeetingRootView {

    private func updatePeopleRows() { applyPeople(to: peopleView) }

    /// The bar's People pop-out shows the same list. A row opens the Meeting
    /// window on that person, since their actions live in its inspector.
    func feedPeople(_ popOut: MeetingPeopleView) {
        popOut.onSelect = { [weak self] id in
            guard let self, id != ParticipantGridWindowController.myEntry?.id else { return }
            self.selected = id
            self.selectionChanged()
            self.controls?.openPeopleInWindow()
        }
        popOut.onAdmit = peopleView.onAdmit
        popOut.onDeny = peopleView.onDeny
        popOut.onInvite = peopleView.onInvite
        popOut.onAdmitAll = peopleView.onAdmitAll
        popOut.onMuteAll = peopleView.onMuteAll
        popOut.onAskAllToUnmute = peopleView.onAskAllToUnmute
        popOut.onQuick = peopleView.onQuick
        popOut.personMenu = peopleView.personMenu
        popOut.hostMenu = peopleView.hostMenu
        applyPeople(to: popOut)
    }

    private func applyPeople(to target: MeetingPeopleView) {
        let queue = handQueue
        let handIDs = Set(queue.map(\.id))
        let viewer = ParticipantGridWindowController.sdk.map {
            ParticipantActionRunner.viewer(me: ParticipantGridWindowController.myEntry, client: $0)
        } ?? ViewerFacts(role: .attendee)
        func row(_ entry: ZoomMeetingSDKClient.RosterEntry) -> MeetingPeopleView.Row {
            ParticipantActionRunner.row(entry, viewer: viewer, selected: selected == entry.id)
        }
        // You first, as Zoom lists you. Your own row opens nothing: there is no
        // inspector for yourself, and the toolbar is where your controls are.
        var mine: [MeetingPeopleView.Row] = []
        if let me = ParticipantGridWindowController.myEntry {
            var entry = row(me)
            if let sdk = ParticipantGridWindowController.sdk {
                entry.muted = sdk.iAmMuted
                entry.cameraOff = controls?.coordinator.ownCameraOff(zoomVideoOn: sdk.myVideoIsOn) ?? !sdk.myVideoIsOn
            }
            mine = [entry]
        }
        target.apply(waiting: waiting.map { .init(id: $0.id, name: $0.name) },
                         canDeny: ParticipantGridWindowController.sdk?.canExpelFromWaitingRoom() ?? false,
                         isHost: flags.iAmHostOrCoHost,
                         hands: queue.map(row),
                         everyone: mine + roster.filter { !handIDs.contains($0.id) }.map(row),
                         total: roster.count + 1)
    }

    func layoutSidePanel(_ panel: MeetingSidePanel) {
        let width = sidePanelHost.bounds.width, height = sidePanelHost.bounds.height
        let head: CGFloat = 44
        sidePanelBacking.frame = sidePanelHost.bounds
        sidePanelDivider.frame = NSRect(x: 0, y: 0, width: 1, height: height)
        // On top of the panel's contents: the people list and the chat are
        // opaque and covered it, so the line stopped under the queue (owner,
        // 2026-11-16: "a proper line should be drawn in between").
        if sidePanelHost.subviews.last !== sidePanelDivider {
            sidePanelHost.addSubview(sidePanelDivider, positioned: .above, relativeTo: nil)
        }
        // Zoom's panel headers: "Participants (N)" and "Chat".
        sidePanelTitle.stringValue = panel == .chat ? "Chat" : "Participants (\(roster.count + 1))"
        sidePanelTitle.sizeToFit()
        sidePanelTitle.frame = NSRect(x: 16, y: height - head + (head - sidePanelTitle.frame.height) / 2,
                                      width: min(sidePanelTitle.frame.width, max(0, width - 64)),
                                      height: sidePanelTitle.frame.height)
        sidePanelClose.frame = NSRect(x: width - 36, y: height - head + 10, width: 24, height: 24)
        // The count and Invite moved into the Participants panel itself (its
        // footer), as Zoom has them.
        sidePanelCount.isHidden = true
        inviteButton.isHidden = true
        let body = NSRect(x: 0, y: 0, width: width, height: max(0, height - head))

        switch panel {
        case .chat:
            if chatHost == nil, let bridge = ParticipantGridWindowController.chatBridge {
                let host = FirstMouseHostingView(rootView: ChatWindowView(chat: bridge).environment(\.meetingZoomChat, true).tint(Brand.green))
                sidePanelHost.addSubview(host)
                chatHost = host
            }
            chatHost?.isHidden = false
            chatHost?.frame = body
            queueScroll.isHidden = true
            peopleView.isHidden = true
        case .people:
            chatHost?.isHidden = true
            peopleView.isHidden = false
            // The needs block and Cues sit at the top, taking what they want up
            // to under half the panel and scrolling inside that; the roster has
            // the rest.
            let state = peoplePanelQueueState
            let wanted = liveQueue.height(for: state, width: width)
            let queueHeight = wanted == 0 ? 0 : min(wanted, (body.height * 0.45).rounded())
            queueScroll.isHidden = queueHeight <= 0
            queueScroll.frame = NSRect(x: 0, y: body.height - queueHeight, width: width, height: queueHeight)
            if queueHeight > 0 { placeQueue(height: queueHeight, width: width, state: state) }
            peopleView.frame = NSRect(x: 0, y: 0, width: width, height: max(0, body.height - queueHeight))
            updatePeopleRows()
        }
    }

    /// Raised hands in the order they went up.
    private var handQueue: [ZoomMeetingSDKClient.RosterEntry] {
        roster.filter(\.isRaisingHand).sorted {
            (handRaisedAt[$0.id] ?? .distantPast) < (handRaisedAt[$1.id] ?? .distantPast)
        }
    }

    /// Everything the window shows, as one value.
    ///
    /// Phase 1 of the redesign plan: the rail's blocks each used to work out
    /// their own idea of what mattered, so "what needs the teacher" was decided
    /// in more than one place and could disagree. It is decided here now, and
    /// the views read the answer. See ParticipantConsoleState.
    private var consoleState: ParticipantConsoleState {
        var state = ParticipantConsoleState()
        state.isLive = session.readiness.isLive
        state.meetingNumber = session.meetingNumber
        state.isRecording = session.isRecording
        state.students = roster.count
        state.waiting = waiting.map { .init(id: $0.id, name: $0.name) }
        state.hands = handQueue.map { .init(id: $0.id, name: $0.name) }
        state.selected = selected
        state.cuesCards = cuesBlock.cardCount
        state.cuesListening = cuesBlock.isActive
        return state
    }

    /// Everything the toolbar and context strip render from, flattened.
    func barSignature() -> String {
        let sdk = ParticipantGridWindowController.sdk
        var parts: [String] = [
            selected.map(String.init) ?? "-",
            String(page),
            String(roster.count),
            String(waiting.count),
            session.isRecording ? "rec" : "-",
            (sdk?.iAmMuted ?? false) ? "me-muted" : "-",
            (sdk?.myVideoIsOn ?? false) ? "me-video" : "-",
            (sdk?.myHandIsRaised ?? false) ? "me-hand" : "-",
            flags.chatAllowed ? "c" : "-",
            flags.shareAllowed ? "s" : "-",
            flags.renameAllowed ? "r" : "-",
            flags.startVideoAllowed ? "v" : "-",
            flags.unmuteSelfAllowed ? "u" : "-",
            flags.focusModeOn ? "f" : "-",
            flags.incomingAudioStopped ? "q" : "-",
            flags.canSuspend ? "z" : "-",
            roster.contains(where: \.isRaisingHand) ? "hands" : "-",
            roster.contains(where: \.isSpotlighted) ? "spots" : "-",
            // Readiness changes what the controls look like - dimmed or live -
            // so a step completing has to rebuild the rail like any other
            // state a button renders from.
            String(describing: session.readiness)
        ]
        // The context strip mirrors one student, so its state belongs here too.
        if let id = selected, let entry = roster.first(where: { $0.id == id }) {
            parts.append("\(entry.name)|\(entry.isMuted)|\(entry.videoOn)|\(entry.isSpotlighted)|\(entry.isPinned)|\(entry.isRaisingHand)|\(entry.isCoHost)|\(entry.isMyself)")
        }
        return parts.joined(separator: ";")
    }

    /// The People panel lists who is waiting and whose hand is up itself,
    /// with Admit and Deny on each row, so the queue above it keeps only
    /// Cues: the same person was shown twice (owner, 2026-11-16).
    private var peoplePanelQueueState: ParticipantConsoleState {
        var state = consoleState
        state.waiting = []
        state.hands = []
        return state
    }

    private func placeQueue(height queueHeight: CGFloat, width: CGFloat, state: ParticipantConsoleState) {
        // Where the teacher had scrolled the queue to, from its top, read
        // BEFORE the view is resized and rewritten below. This runs on
        // every one-second poll, and it used to end by scrolling the
        // queue back to the top unconditionally - so a scroll lasted until
        // the next tick and then snapped, which is what "laggy" was.
        let queueViewport = queueScroll.contentView.bounds
        let queueFromTop = liveQueue.bounds.height > 0
            ? max(0, liveQueue.bounds.height - queueViewport.maxY) : 0
        // Frame first, THEN write it: the view lays out from its own
        // height, so it has to know that height before it draws.
        // The VIEWPORT height, not what the queue wanted. Sized to the
        // want, the block fitted five cards into a 400pt document that an
        // 80pt scroller showed the top of - measured live, every card sat
        // below the window edge. Sized to what it has, the block fits whole
        // cards and counts the rest, which is what it was built to do.
        liveQueue.frame = NSRect(x: 0, y: 0, width: width, height: queueHeight)
        liveQueue.apply(state, width: width)
        // Non-flipped document views scroll to the bottom by default, which
        // would open the queue showing its last row - so the position is
        // put back counted from the top, clamped to what now exists.
        let maxFromTop = max(0, liveQueue.bounds.height - queueViewport.height)
        liveQueue.scroll(NSPoint(x: 0, y: liveQueue.bounds.height - queueViewport.height
                                         - min(queueFromTop, maxFromTop)))
    }

    /// Cues's state, once a second. Re-lays the rail only when the block
    /// changed height, so a stable set of cards costs nothing.
    func applyCues(_ state: CuesSurfaceState) {
        let hadCards = cuesBlock.hasCards
        guard cuesBlock.apply(state) || hadCards != cuesBlock.hasCards else { return }
        layoutEverything()
    }

    func rebuildContextBar() {
        guard let id = selected, let entry = roster.first(where: { $0.id == id }) else { return }

        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .labelColor
        var controls: [NSView] = [name]

        // The person's controls: one list for the drawer, the rows' "..." and
        // the Participants view window (ParticipantActionRules), one definition
        // of what each does (ParticipantActionRunner).
        if let sdk = ParticipantGridWindowController.sdk {
            let viewer = ParticipantActionRunner.viewer(me: ParticipantGridWindowController.myEntry, client: sdk)
            for action in ParticipantActionRules.actions(person: ParticipantActionRunner.facts(entry), viewer: viewer) {
                controls.append(Self.button(ParticipantActionRules.title(action),
                                            symbol: ParticipantActionRules.symbol(action),
                                            prominent: action == .spotlight,
                                            destructive: ParticipantActionRules.isDestructive(action)) {
                    ParticipantActionRunner.run(action, on: entry, surface: Self.actionSurface)
                })
            }
        }
        // Straight into the drawer. The strip along the bottom is gone: it was
        // always in the layout and empty most of the time, which is the third
        // competing region the plan asks to remove.
        let head = controls.first
        inspector.apply(name: entry.name,
                        status: Self.stateWords(for: entry),
                        controls: Array(controls.dropFirst()))
        _ = head
    }
}
