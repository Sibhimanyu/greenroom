//
//  MeetingControls.swift
//  Greenroom
//
//  One set of meeting controls, drawn in two places.
//
//  `MeetingControlsModel` is the single source of truth: the coordinator owns
//  one per session and two views read it. The toolbar along the foot of the
//  meeting window (ParticipantGridWindow.swift) is the everyday surface. The
//  floating pill is what is left when that window is closed, minimised or
//  fully covered: mute, camera, record, chat, who is here, how long, End.
//
//  The pill's panel is the same kind as the readiness card: it can never become
//  key or main, so a click works the meeting without pulling Greenroom in front
//  of whatever the teacher is teaching from.
//
import SwiftUI
import AppKit
import Combine

// MARK: - State

/// Which panel the meeting window's right column shows. One at a time.
enum MeetingSidePanel: Equatable { case chat, people }

/// What the controls show. The SDK has no change callbacks for your own mic and
/// camera, so they are polled once a second, as the participant panel does.
@MainActor
final class MeetingControlsModel: ObservableObject {
    @Published private(set) var muted = false
    @Published private(set) var cameraOn = true
    @Published private(set) var inMeeting = false
    /// False when this Mac is not on the meeting's audio at all, which is a
    /// different state from muted and has a different answer ("Join audio").
    @Published private(set) var hasAudio = true
    @Published private(set) var participantCount = 0
    @Published private(set) var waitingCount = 0
    @Published private(set) var raisedHands = 0
    @Published private(set) var handRaised = false
    @Published private(set) var isHost = false
    @Published private(set) var locked = false
    @Published private(set) var sharing = false
    @Published private(set) var chatOpen = false
    @Published private(set) var unread = 0
    /// Greenroom's own meeting window, on screen or not.
    @Published private(set) var meetingWindowOpen = false
    @Published private(set) var micDevices: [(id: String, name: String)] = []
    @Published private(set) var micSelectedID: String?
    @Published private(set) var speakerDevices: [(id: String, name: String)] = []
    @Published private(set) var speakerSelectedID: String?
    @Published private(set) var cameraDevices: [MeetingMenus.Device] = []
    @Published private(set) var cameraSelectedID: String?
    /// The Security menu's live state (host and co-host only).
    @Published private(set) var security = SecurityMenuState()
    /// Why sharing is off for this Mac right now, if it is.
    @Published private(set) var cannotShare: String?
    /// People at the door, longest waiting first.
    @Published private(set) var waitingPeople: [WaitingPerson] = []
    /// The meeting window's right column. Lives here so the toolbar button and
    /// the window it opens a panel in cannot disagree about which is showing.
    @Published var sidePanel: MeetingSidePanel?
    /// Drives the two clocks; the views redraw on it.
    @Published private(set) var now = Date()

    /// The meeting window (and so the Meeting window toggle) exists only when
    /// the SDK really started in custom UI: Zoom then opens no windows.
    var videoButtons: Bool { coordinator.zoomChatClient.didInit }

    let coordinator: CoordinatorController
    private var timer: Timer?
    private var chatSub: AnyCancellable?
    private var ticks = 0
    /// Incoming messages the teacher has had the chance to read.
    private var seenIncoming = 0

    init(coordinator: CoordinatorController) {
        self.coordinator = coordinator
        chatSub = coordinator.zoomChatBridge.$messages.sink { [weak self] _ in
            // Published fires before the value lands; read it next turn.
            Task { @MainActor in self?.refresh() }
        }
        // Events from the room redraw at once rather than at the next tick: a hand
        // going up, a share starting, someone at the door, a rule changing.
        let client = coordinator.zoomChatClient
        let redraw: () -> Void = { [weak self] in
            self?.refresh()
            ParticipantGridWindowController.refreshNow()
        }
        client.roomEvents.onChange = redraw
        client.shareViewer.onChange = redraw
        client.roomEvents.onWaitingJoin = { [weak self] person, total in
            let words = WaitingRoomWords.joined(person.name, total: total)
            // A click on the island opens the Meeting window on People, wherever
            // it is, to admit them (owner, 2026-11-16). Only with Greenroom's own
            // meeting window; the Zoom app's own windows are Zoom's.
            let open: (() -> Void)? = client.didInit ? { self?.openPeopleInWindow() } : nil
            ToastController.show(words.title, detail: words.detail, kind: .working, dismissAfter: 6, action: open)
            coordinator.log(words.title + ".")
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func stop() {
        timer?.invalidate()
        timer = nil
        chatSub = nil
        let client = coordinator.zoomChatClient
        client.roomEvents.onChange = nil
        client.roomEvents.onWaitingJoin = nil
        client.shareViewer.onChange = nil
    }

    func refresh() {
        now = Date()
        ticks += 1
        let client = coordinator.zoomChatClient
        inMeeting = client.myUserID != nil
        if inMeeting {
            muted = client.iAmMuted
            cameraOn = client.myVideoIsOn
            hasAudio = client.iHaveJoinedAudio
            handRaised = client.myHandIsRaised
            isHost = client.roomFlags().iAmHostOrCoHost
            locked = client.meetingIsLocked
            // Others, plus you: the number Zoom's own Participants button shows.
            participantCount = client.participantUserIDs(excludingSelf: false).count
            let waitingList = client.waitingRoomNames()
            waitingCount = waitingList.count
            waitingPeople = waitingList.map { WaitingPerson(id: $0.id, name: $0.name) }
            sharing = client.shareViewer.selfSharing
            if isHost {
                security = client.securityState()
                cannotShare = client.cannotShareReason()
            }
            raisedHands = client.meetingRoster().filter { $0.isRaisingHand && !$0.isMyself }.count
            if PeoplePopOutController.isOpen { PeoplePopOutController.feedWithoutWindow(client: client, controls: self) }
            // Device lists are not worth asking for every second.
            if ticks % 5 == 1 { refreshDevices() }
            // Stale reactions clear themselves from the ledger.
            client.roomEvents.pruneReactions(present: Set(client.participantUserIDs(excludingSelf: false)))
        }
        meetingWindowOpen = coordinator.meetingWindowOpen
        if !meetingWindowOpen, sidePanel != nil { sidePanel = nil }
        // A chat panel in a hidden window is not an open chat: the bar would
        // offer "Close Chat" for something nobody can see.
        chatOpen = (sidePanel == .chat && ParticipantGridWindowController.meetingWindowIsShowing)
            || ChatWindowController.isOpen
        let incoming = coordinator.zoomChatBridge.messages.filter { !$0.isOutgoing }.count
        if chatOpen { seenIncoming = incoming }
        unread = max(0, incoming - seenIncoming)
    }

    private func refreshDevices() {
        let client = coordinator.zoomChatClient
        let mics = client.microphoneDevices()
        micDevices = mics.devices
        micSelectedID = mics.selectedID
        let speakers = client.speakerDevices()
        speakerDevices = speakers.devices
        speakerSelectedID = speakers.selectedID
        let cameras = client.cameraDevices()
        cameraDevices = cameras.devices
        cameraSelectedID = cameras.selectedID
    }

    // MARK: Actions

    /// Runs an SDK call and says what happened in the status log, the way the
    /// participant window's own controls do. Never touches Greenroom's windows.
    private func act(_ success: String, code: String,
                     _ body: (ZoomMeetingSDKClient) -> Bool) {
        let ok = body(coordinator.zoomChatClient)
        Analytics.track(.controlAction, [.action: code, .refused: ok ? "no" : "yes"])
        coordinator.log(ok ? success : "Zoom refused that \u{2014} nothing changed. (\(success))")
        refresh()
        ParticipantGridWindowController.refreshNow()
    }

    func toggleMute() {
        let client = coordinator.zoomChatClient
        _ = client.setMyMute(!client.iAmMuted)
        refresh()
    }

    func toggleCamera() {
        let client = coordinator.zoomChatClient
        _ = client.setMyVideo(on: !client.myVideoIsOn)
        refresh()
    }

    /// Hides or shows the floating camera bubble on your own screen. The class
    /// and the recording keep seeing the camera.
    func toggleBubble() {
        coordinator.presenceBubbleHidden.toggle()
        refresh()
    }

    func joinAudio() {
        act("Joined the meeting's audio", code: "join_audio") { $0.joinAudio() }
    }

    func selectMicrophone(id: String, name: String) {
        act("Microphone: \(name)", code: "select_mic") { $0.selectMicrophone(id: id, name: name) }
        refreshDevices()
    }

    func selectSpeaker(id: String, name: String) {
        act("Speaker: \(name)", code: "select_speaker") { $0.selectSpeaker(id: id, name: name) }
        refreshDevices()
    }

    /// Zoom's own share of a whole display, which is separate from the picture
    /// Greenroom sends as the camera. Whether it is running is the SDK's word
    /// (`ShareViewer.selfSharing`), read at the next refresh.
    func startShare(displayID: CGDirectDisplayID) {
        act("Sharing a display through Zoom", code: "share_start") { $0.startShare(displayID: displayID) }
    }

    func stopShare() {
        act("Stopped sharing", code: "share_stop") { $0.stopShare() }
    }

    func setShareRule(_ rule: ShareRule) {
        act("Sharing: " + (rule.who == .hostOnly ? "only the host"
                           : rule.concurrent == .multiple ? "everyone, several at once" : "everyone, one at a time"),
            code: "share_rule") { $0.setShareRule(rule) }
    }

    // MARK: Security (host and co-host)

    func setLocked(_ lock: Bool) {
        act(lock ? "Meeting locked" : "Meeting unlocked", code: "other") { $0.setMeetingLocked(lock) }
        locked = lock
    }

    func setWaitingRoom(_ on: Bool) {
        act(on ? "Waiting room on" : "Waiting room off", code: "waiting_room") { $0.setWaitingRoomOn(on) }
    }

    func setChat(_ who: ChatWho) {
        act("Participants can chat with: \(who.title.lowercased())", code: "chat_rule") { $0.setChatWho(who) }
    }

    func setRename(_ on: Bool) {
        act(on ? "Participants may rename themselves" : "Participants may not rename themselves",
            code: "other") { $0.setAllowRename(on) }
    }

    func setUnmuteSelf(_ on: Bool) {
        act(on ? "Participants may unmute themselves" : "Participants may not unmute themselves",
            code: "other") { $0.setAllowUnmuteSelf(on) }
    }

    func setStartVideo(_ on: Bool) {
        act(on ? "Participants may start video" : "Participants may not start video",
            code: "other") { $0.setAllowStartVideo(on) }
    }

    func suspendActivities() {
        act("Suspended all participant activities", code: "other") { $0.suspendAllActivities() }
    }

    // MARK: Waiting room

    func admit(_ person: WaitingPerson) {
        act("Admitted \(person.name)", code: "admit") { $0.admitFromWaitingRoom(userID: person.id) }
    }

    func deny(_ person: WaitingPerson) {
        act("Denied \(person.name)", code: "deny") { $0.denyWaiting(userID: person.id) }
    }

    func selectCamera(_ device: MeetingMenus.Device) {
        act("Camera: \(device.name)", code: "select_camera") { $0.selectCamera(id: device.id) }
        refreshDevices()
    }

    // MARK: Invite and the Zoom app

    var meetingFacts: MeetingMenus.MeetingFacts {
        guard let invite = coordinator.zoomChatClient.meetingInvite() else { return .init() }
        return .init(number: invite.number, passcode: invite.passcode, joinURL: invite.joinURL)
    }

    /// Puts text on the pasteboard and says so. No window, so focus stays where it is.
    func copy(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastController.show("\(what) copied", detail: nil, kind: .success)
    }

    /// Copies the link a guest would click (`meetingInvite().joinURL`).
    func copyInviteLink() {
        let link = meetingFacts.joinURL
        guard !link.isEmpty else {
            coordinator.log("The invite link is not available yet.")
            return
        }
        copy(link, what: "Invite link")
    }

    /// Opens the same meeting in the Zoom app, which has what this window does
    /// not: breakout rooms, polls and captions. A second connection under the
    /// same account may push this one out, so the log says what to expect.
    func openInZoomApp() {
        guard let url = coordinator.zoomChatClient.zoomAppLink() else {
            coordinator.log("The meeting link is not available yet.")
            return
        }
        coordinator.log("Opening this meeting in the Zoom app. Make that copy a co-host to use breakout rooms and polls.")
        NSWorkspace.shared.open(url)
    }

    func react(_ reaction: ZoomMeetingSDKClient.Reaction) {
        act("Sent \(reaction.rawValue.lowercased())", code: "reaction") { $0.send(reaction) }
    }

    func toggleHand() {
        let raised = handRaised
        act(raised ? "Lowered your hand" : "Raised your hand", code: "other") { $0.setMyHand(raised: !raised) }
    }

    func muteAll() { act("Muted everyone", code: "mute_all") { $0.muteEveryone() } }
    func askAllToUnmute() { act("Asked everyone to unmute", code: "ask_unmute_all") { $0.askEveryoneToUnmute() } }
    func admitAll() { act("Admitted everyone waiting", code: "admit_all") { $0.admitEveryoneWaiting() } }

    /// With the meeting window open the chat is a panel in it (or the column
    /// window, in an arranged session); closed, it is a window of its own,
    /// opened on demand and then left alone: no layout, so no tiling pass ever
    /// claims it (the follow loops only run for an arranged session).
    /// The chat in one place: the pop-out opened from the bar folds into the
    /// window's Chat panel once the window is in view (back on its desktop, or
    /// brought here). Called whenever the bar decides again, and every second.
    /// The People pop-out folds the same way, into the People panel.
    func foldPopOutChatIntoWindow() {
        if MeetingSurfaces.foldsPopOutChat(windowShowing: ParticipantGridWindowController.meetingWindowIsShowing,
                                           popOutOpen: PeoplePopOutController.isOpen, arranged: false) {
            PeoplePopOutController.close()
            sidePanel = .people
            refresh()
        }
        guard coordinator.zoomChatClient.didInit,
              MeetingSurfaces.foldsPopOutChat(windowShowing: ParticipantGridWindowController.meetingWindowIsShowing,
                                              popOutOpen: ChatWindowController.isOpen,
                                              arranged: coordinator.sessionArranges) else { return }
        ChatWindowController.close()
        sidePanel = .chat
        refresh()
    }

    func toggleChat() {
        // The window must be SHOWING, not just open: collapsed into the bar it
        // is open but hidden, and the chat panel then opened inside a window
        // nobody could see. The bar's Chat button did nothing (owner, 2026-11-14).
        if ParticipantGridWindowController.meetingWindowIsShowing, !coordinator.sessionArranges {
            sidePanel = sidePanel == .chat ? nil : .chat
        } else if ParticipantGridWindowController.meetingWindowIsElsewhere, !coordinator.sessionArranges {
            // Up on another desktop: brought to this one, chat open (owner, 2026-11-16).
            coordinator.openMeetingWindow()
            sidePanel = .chat
        } else if ChatWindowController.isOpenHere {
            ChatWindowController.close()
        } else if ChatWindowController.isOpen {
            ChatWindowController.reveal() // on another desktop: brings it to this one
        } else {
            coordinator.revealChatWindow()
        }
        refresh()
    }

    /// The roster panel in the meeting window; with no window up, it is the
    /// window that opens, People panel showing.
    func togglePeople() {
        if coordinator.meetingWindowOpen {
            sidePanel = sidePanel == .people ? nil : .people
        } else {
            sidePanel = .people
            coordinator.toggleMeetingWindow()
        }
        refresh()
    }

    /// The bar's people count. With the window showing it toggles the panel
    /// like the window's own button; otherwise the list opens as a small window
    /// beside the bar, not the whole meeting (owner, 2026-11-16), and a second
    /// click closes it. With the window up on another desktop, it comes here,
    /// People open.
    func showPeople() {
        if ParticipantGridWindowController.meetingWindowIsShowing {
            sidePanel = sidePanel == .people ? nil : .people
        } else if ParticipantGridWindowController.meetingWindowIsElsewhere {
            PeoplePopOutController.close()
            coordinator.openMeetingWindow()
            sidePanel = .people
        } else if PeoplePopOutController.isOpenHere {
            PeoplePopOutController.close()
        } else if PeoplePopOutController.isOpen {
            PeoplePopOutController.reveal()
        } else {
            PeoplePopOutController.show(near: MeetingControlBarController.currentFrame)
        }
        refresh()
    }

    /// From a row in the People pop-out: the Meeting window, People panel open.
    func openPeopleInWindow() {
        PeoplePopOutController.close()
        sidePanel = .people
        coordinator.expandMeetingFromBar()
        refresh()
    }

    /// The Views menu: the Meeting window and every view, a checkmark on each that
    /// is open. Empty without Greenroom's own meeting UI.
    func viewsMenu() -> [MenuEntry] {
        guard coordinator.zoomChatClient.didInit else { return [] }
        var out = MeetingMenus.views(MeetingViewWindows.menuState,
                                  toggleMeetingWindow: { [weak self] in self?.coordinator.toggleMeetingWindow() },
                                  toggleView: { MeetingViewWindows.toggle($0) })
        // A layout's content views carry no controls, and the bar is the only
        // surface when the Meeting window is away: what the window's toolbar
        // had that the bar's cells do not (devices, hand and reactions,
        // Security, display share, meeting info, the Zoom app) comes here.
        if coordinator.sessionArranges, !ParticipantGridWindowController.meetingWindowIsShowing {
            let m = MeetingToolbarView.menus(for: self)
            var extras: [MenuEntry] = []
            extras.append(.submenu("Microphone and speaker", m.audio()))
            extras.append(.submenu("Camera", m.video()))
            extras.append(.submenu("Raise hand and react", m.react()))
            if isHost { extras.append(.submenu("Security", m.security())) }
            extras.append(.submenu("Sharing", m.sharing()))
            let pickers = MeetingViewWindows.pickerMenuEntries()
            if !pickers.isEmpty { extras += [.separator] + pickers }
            extras.append(.separator)
            var a = MeetingMenus.MoreMenuActions()
            a.copy = copy
            a.openInZoom = openInZoomApp
            out += [.separator] + MeetingMenus.more(overflow: extras, facts: meetingFacts, views: [], a)
        }
        return out
    }

    /// The bar's Meeting button. The bar is up only while the window is not, so
    /// this brings the Meeting window straight back.
    func toggleMeetingWindow() {
        if ParticipantGridWindowController.meetingWindowIsShowing {
            coordinator.toggleMeetingWindow()
        } else {
            coordinator.expandMeetingFromBar()
        }
        refresh()
    }

    /// The puck menu's "Expand to meeting window": always the window.
    func expandToMeetingWindow() {
        coordinator.expandMeetingFromBar()
        refresh()
    }

    /// The meeting window's Smaller button, Minimize and Command-M: one size down.
    func collapseMeeting() {
        coordinator.collapseMeeting()
        refresh()
    }

    /// m:ss, or h:mm:ss past the hour.
    static func clock(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func elapsed(since start: Date?) -> String {
        guard let start else { return "0:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Toolbar (the meeting window's foot)

/// The toolbar, wired to the model. The drawing, and how much of it fits, are in
/// MeetingToolbar.swift and MeetingToolbarLayout.swift; this fills in the live
/// state, builds each menu when it is opened (so it shows the state of that
/// moment) and says what a press does.
struct MeetingToolbarView: View {
    @ObservedObject var model: MeetingControlsModel
    @ObservedObject var coordinator: CoordinatorController
    @ObservedObject private var notes = SessionNotes.shared

    static let height: CGFloat = MeetingToolbarBar.height

    var body: some View {
        MeetingToolbarBar(state: state, menus: menus, actions: actions)
    }

    private var state: MeetingToolbarState {
        var s = MeetingToolbarState()
        s.inMeeting = model.inMeeting
        s.muted = model.muted
        s.hasAudio = model.hasAudio
        s.cameraOn = model.cameraOn
        s.bubbleHidden = coordinator.presenceBubbleHidden
        s.isHost = model.isHost
        s.participants = model.participantCount
        s.waiting = model.waitingCount
        s.peopleOpen = model.sidePanel == .people
        s.chatOpen = model.sidePanel == .chat || (model.chatOpen && model.sidePanel == nil)
        s.unread = model.unread
        s.handRaised = model.handRaised
        s.sharing = model.sharing
        s.recording = coordinator.isRecording
        s.recordingPaused = coordinator.isRecordingPaused
        s.saving = coordinator.isSavingRecording
        s.recordCaption = coordinator.isRecording
            ? MeetingControlsModel.clock(seconds: { _ = model.now; return coordinator.recordingElapsed() ?? 0 }())
            : "Record"
        s.notesOn = notes.effectiveEnabled
        s.drawing = coordinator.isDrawing
        s.canDraw = coordinator.canDraw
        let host = coordinator.liveExitState.kind == .host
        s.endsForAll = host
        s.endName = host ? LiveExitChoice.endMeetingForAll.title : LiveExitChoice.leaveMeeting.title
        s.clock = MeetingControlsModel.elapsed(since: { _ = model.now; return coordinator.sessionStartedAt }())
        return s
    }

    private var actions: MeetingToolbarActions {
        var a = MeetingToolbarActions()
        a.toggleMute = model.toggleMute
        a.joinAudio = model.joinAudio
        a.toggleVideo = model.toggleCamera
        a.toggleBubble = model.toggleBubble
        a.togglePeople = model.togglePeople
        a.toggleChat = model.toggleChat
        a.toggleRecording = { coordinator.toggleRecording() }
        a.togglePause = { coordinator.togglePauseRecording() }
        a.toggleNotes = notes.toggle
        a.toggleDraw = { coordinator.toggleDrawing() }
        a.stopSharing = model.stopShare
        a.end = { coordinator.stop() }
        return a
    }

    private var menus: MeetingToolbarMenus { Self.menus(for: model) }

    /// The toolbar's menus, also the Control bar's extras when the bar carries
    /// the controls of a layout's content views.
    static func menus(for model: MeetingControlsModel) -> MeetingToolbarMenus {
        var m = MeetingToolbarMenus()
        m.audio = {
            MeetingMenus.audio(hasAudio: model.hasAudio || !model.inMeeting,
                               mics: model.micDevices.map { .init(id: $0.id, name: $0.name) },
                               micSelected: model.micSelectedID,
                               speakers: model.speakerDevices.map { .init(id: $0.id, name: $0.name) },
                               speakerSelected: model.speakerSelectedID,
                               joinAudio: model.joinAudio,
                               pickMic: { model.selectMicrophone(id: $0.id, name: $0.name) },
                               pickSpeaker: { model.selectSpeaker(id: $0.id, name: $0.name) })
        }
        m.video = { () -> [MenuEntry] in
            let hidden = model.coordinator.presenceBubbleHidden
            var bubble: (hidden: Bool, toggle: () -> Void)?
            if model.cameraOn { bubble = (hidden: hidden, toggle: { model.toggleBubble() }) }
            return MeetingMenus.video(cameras: model.cameraDevices, selected: model.cameraSelectedID,
                                      bubble: bubble, pick: { model.selectCamera($0) })
        }
        m.security = {
            var a = SecurityMenuActions()
            a.setLocked = model.setLocked
            a.setWaitingRoom = model.setWaitingRoom
            a.setShareRule = model.setShareRule
            a.setChat = model.setChat
            a.setRename = model.setRename
            a.setUnmuteSelf = model.setUnmuteSelf
            a.setStartVideo = model.setStartVideo
            a.suspend = {
                ParticipantGridWindowController.confirmSuspend { model.suspendActivities() }
            }
            return MeetingMenus.security(model.security, a,
                                         lastConcurrent: model.coordinator.zoomChatClient.roomEvents.lastConcurrent)
        }
        m.react = {
            MeetingMenus.react(handRaised: model.handRaised,
                               reactions: ZoomMeetingSDKClient.Reaction.allCases.map(\.rawValue),
                               toggleHand: model.toggleHand,
                               send: { name in
                                   if let r = ZoomMeetingSDKClient.Reaction(rawValue: name) { model.react(r) }
                               })
        }
        func shareEntries(present: [MenuEntry]) -> [MenuEntry] {
            var s = MeetingMenus.ShareMenuState()
            s.inMeeting = model.inMeeting
            s.sharing = model.sharing
            s.displays = model.coordinator.zoomChatClient.shareableDisplays().map { ($0.id, $0.label) }
            s.cannotShare = model.cannotShare
            s.isHost = model.isHost
            s.rule = model.security.shareRule
            var a = MeetingMenus.ShareMenuActions()
            a.shareDisplay = { model.startShare(displayID: CGDirectDisplayID($0)) }
            a.stop = model.stopShare
            a.setRule = model.setShareRule
            return MeetingMenus.share(s, a, lastConcurrent: model.coordinator.zoomChatClient.roomEvents.lastConcurrent,
                                      present: present)
        }
        m.share = { shareEntries(present: model.coordinator.presentMenuEntries()) }
        m.sharing = { shareEntries(present: []) }
        m.more = { overflow in
            var a = MeetingMenus.MoreMenuActions()
            a.copy = model.copy
            a.openInZoom = model.openInZoomApp
            a.shrink = model.videoButtons ? { model.collapseMeeting() } : nil
            return MeetingMenus.more(overflow: overflow, facts: model.meetingFacts, views: model.viewsMenu(), a)
        }
        return m
    }
}

// MARK: - Pill and puck

/// Whether the bar is the full pill or the small round puck. One value, read by
/// the view and written by the controller, which also moves the window.
@MainActor
final class MeetingBarState: ObservableObject {
    @Published var collapsed: Bool
    init(collapsed: Bool) { self.collapsed = collapsed }
}

/// The window's whole content: a capsule that fills the panel, holding the pill
/// or the puck. The controller animates the panel's frame between the two sizes
/// and this crossfades what is inside, so the capsule is always exactly the
/// window and the shadow follows it.
struct MeetingControlBarRoot: View {
    @ObservedObject var model: MeetingControlsModel
    @ObservedObject var coordinator: CoordinatorController
    @ObservedObject var state: MeetingBarState

    var body: some View {
        let collapsed = state.collapsed
        // While the meeting comes up the bar says so, and offers Cancel; the
        // live cells fade in when it is live (StartChoreography.swift).
        let starting = coordinator.startBarText != nil
        // The content is overlaid, never measured: the capsule is exactly the
        // window however wide the pill inside is, so a half-collapsed window
        // clips the pill instead of stretching the capsule.
        Color.clear.overlay {
          ZStack {
            MeetingControlBarView(model: model, coordinator: coordinator)
                .frame(width: MeetingControlBarController.width(videoButtons: model.videoButtons),
                       height: MeetingControlBarController.height)
                .opacity(collapsed || starting ? 0 : 1)
                .allowsHitTesting(!collapsed && !starting)
                .accessibilityHidden(collapsed || starting)
            MeetingPuckView(model: model, coordinator: coordinator)
                .opacity(collapsed && !starting ? 1 : 0)
                .allowsHitTesting(collapsed && !starting)
                .accessibilityHidden(!collapsed || starting)
            MeetingStartingBarView(text: coordinator.startBarText ?? "Starting\u{2026}",
                                   cancel: { coordinator.cancelStart() })
                .frame(width: StartChoreography.startingBarWidth, height: MeetingControlBarController.height)
                .opacity(starting ? 1 : 0)
                .allowsHitTesting(starting)
                .accessibilityHidden(!starting)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Capsule())
        .greenroomGlass(in: Capsule(), interactive: true)
        .animation(Collapse.animation, value: collapsed)
        .animation(Collapse.animation, value: starting)
    }
}

/// The bar while the meeting starts: the grip, a spinner, what is happening in
/// plain words, and Cancel where End will be. Nothing else works yet, so
/// nothing else is drawn.
private struct MeetingStartingBarView: View {
    var text: String
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MeetingBarGrip()
            ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 16, height: 16)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(minWidth: 62, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: cancel) {
                Text("Cancel")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Cancel starting the meeting")
            .accessibilityLabel("Cancel starting the meeting")
            .padding(.trailing, 6)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Six dots, two by three: the handle. The pill's buttons cover nearly all of
/// it, so this is the part that is plainly meant to be grabbed.
private struct MeetingBarGrip: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
                }
            }
        }
        .foregroundStyle(Color.secondary.opacity(0.7))
        .frame(width: 18, height: MeetingControlBarController.height)
        .overlay {
            MeetingBarPointerSurface(kind: .grip, label: "Move meeting controls",
                                     value: nil, onClick: nil, menu: nil)
        }
        .help("Drag to move the meeting controls")
    }
}

/// The compact form: 44pt round, the Greenroom mark, a red dot while recording
/// and a muted badge while muted. Clicking expands it; a right-click offers the
/// few things worth doing without expanding.
private struct MeetingPuckView: View {
    @ObservedObject var model: MeetingControlsModel
    @ObservedObject var coordinator: CoordinatorController

    private var recording: Bool { coordinator.isRecording }
    private var muted: Bool { model.inMeeting && model.muted }

    /// What VoiceOver says after the label.
    private var stateText: String {
        var parts: [String] = []
        if recording { parts.append(coordinator.isRecordingPaused ? "Recording paused" : "Recording") }
        if muted { parts.append("Muted") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        ZStack {
            Image("MenuBarMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 18)
                .foregroundStyle(Color.primary)
            // Both badges sit inside the 44pt circle (centre to badge edge under
            // 22pt at 45 degrees): the capsule clips its content, so a badge on
            // the square's corner would be cut off flat.
            if recording {
                // Red is the recording signal everywhere else in the bar.
                Circle().fill(coordinator.isRecordingPaused ? Color.secondary : Color.red)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 6).padding(.trailing, 6)
            }
            if muted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 15, height: 15)
                    .background(Color.red, in: Circle())
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, 5).padding(.trailing, 5)
            }
        }
        .frame(width: MeetingControlBarController.puckSize, height: MeetingControlBarController.puckSize)
        .overlay {
            MeetingBarPointerSurface(kind: .puck, label: "Meeting controls, collapsed",
                                     value: stateText,
                                     onClick: { MeetingControlBarController.setCollapsed(false) },
                                     menu: { MeetingControlBarController.puckMenu() })
        }
        .help("Meeting controls. Click to expand, drag to move.")
    }
}

// MARK: Pointer surface

/// One AppKit view that tells a click from a drag. The panel is non-activating,
/// so a press here works the bar without bringing Greenroom forward, and the
/// drag moves the panel itself (not `isMovableByWindowBackground`, which the
/// buttons defeat and which cannot tell a click from the start of a drag).
private struct MeetingBarPointerSurface: NSViewRepresentable {
    enum Kind { case grip, puck }
    let kind: Kind
    let label: String
    let value: String?
    let onClick: (() -> Void)?
    let menu: (() -> [MenuEntry])?

    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.kind = kind
        view.onClick = onClick
        view.menuProvider = menu
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
        view.setAccessibilityRole(kind == .puck ? .button : .handle)
        view.setAccessibilityHelp(kind == .puck ? "Press to expand. Drag to move." : "Drag to move.")
    }

    final class SurfaceView: NSView {
        var kind: Kind = .grip
        var onClick: (() -> Void)?
        var menuProvider: (() -> [MenuEntry])?
        private var startMouse = NSPoint.zero
        private var startOrigin = NSPoint.zero
        private var dragging = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func isAccessibilityElement() -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: kind == .grip ? .openHand : .arrow)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            MeetingControlBarController.cancelSettling()
            startMouse = NSEvent.mouseLocation
            startOrigin = window.frame.origin
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x, dy = now.y - startMouse.y
            if !dragging {
                guard hypot(dx, dy) > MeetingBarPlacement.dragThreshold else { return }
                dragging = true
            }
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            if dragging {
                dragging = false
                MeetingControlBarController.dropped()
            } else {
                onClick?()
            }
        }

        // Right-click: expand, mute, stop recording, end. Our own panel, since an
        // NSMenu shows nothing while Greenroom is not the active app.
        override func rightMouseDown(with event: NSEvent) {
            if let entries = menuProvider?() { MeetingMenuPanel.show(entries, for: event) }
        }

        // VoiceOver: press expands; the menu's items are offered as actions.
        override func accessibilityPerformPress() -> Bool {
            guard let onClick else { return false }
            onClick()
            return true
        }

        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            guard kind == .puck, let entries = menuProvider?() else { return nil }
            return entries.compactMap { entry -> NSAccessibilityCustomAction? in
                guard entry.kind == .item, entry.enabled, let action = entry.action else { return nil }
                return NSAccessibilityCustomAction(name: entry.title) { action(); return true }
            }
        }
    }
}

// MARK: Pill

/// The live bar: the coordinator's state in, `MeetingBarContent` out. What each
/// cell says and holds is decided in MeetingBarModel.swift.
private struct MeetingControlBarView: View {
    @ObservedObject var model: MeetingControlsModel
    @ObservedObject var coordinator: CoordinatorController
    @ObservedObject private var notes = SessionNotes.shared
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        MeetingBarContent(s: snapshot, bindings: shortcuts.bindings, a: actions, grip: AnyView(MeetingBarGrip()))
    }

    private var snapshot: MeetingBarSnapshot {
        _ = model.now // read, so the tick redraws the clocks
        var s = MeetingBarSnapshot()
        s.inMeeting = model.inMeeting
        s.muted = model.muted
        s.cameraOn = model.cameraOn
        s.bubbleHidden = coordinator.presenceBubbleHidden
        s.videoButtons = model.videoButtons
        s.unread = model.unread
        s.participants = model.participantCount
        s.phase = MeetingBarRecordPhase(recording: coordinator.isRecording, paused: coordinator.isRecordingPaused,
                                        saving: coordinator.isSavingRecording,
                                        countdown: coordinator.recordingCountdown != nil)
        s.classSeconds = coordinator.sessionStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        // Paused time is not recording time: the same clock as the file.
        s.recordingSeconds = coordinator.recordingElapsed() ?? 0
        s.drawing = coordinator.isDrawing
        s.canDraw = coordinator.canDraw
        s.chatOpen = model.chatOpen
        s.notesOpen = notes.effectiveEnabled
        s.hasViews = MeetingViewPieces.enabled
        s.endName = coordinator.liveExitState.kind == .host ? LiveExitChoice.endMeetingForAll.title
                                                            : LiveExitChoice.leaveMeeting.title
        s.endArmed = coordinator.exitAsk == .end
        s.recStopArmed = coordinator.exitAsk == .stopRecording
        s.endAskTitle = coordinator.exitAskTitle
        s.endAskDetail = coordinator.exitAskDetail
        s.endAskStartedAt = coordinator.exitAskStartedAt
        s.endAskTimeout = coordinator.exitAskTimeout
        return s
    }

    private var actions: MeetingBarActions {
        let model = self.model, coordinator = self.coordinator, notes = self.notes
        var a = MeetingBarActions()
        a.toggleMute = model.toggleMute
        a.toggleCamera = model.toggleCamera
        a.toggleBubble = model.toggleBubble
        a.meeting = model.toggleMeetingWindow
        a.toggleChat = model.toggleChat
        a.people = model.showPeople
        a.toggleDraw = { coordinator.toggleDrawing() }
        a.togglePause = { coordinator.togglePauseRecording() }
        a.startRecording = { coordinator.toggleRecording() }
        a.stopRecording = { coordinator.confirmStopRecording() }
        // Asks first, exactly as the close and quit prompts do.
        a.end = { coordinator.confirmAndStop() }
        a.keepGoing = { coordinator.disarmExit() }
        a.recordMenu = { [bindings = shortcuts.bindings] in
            var r = MeetingBarModel.RecordActions()
            r.start = { coordinator.toggleRecording() }
            r.stop = { coordinator.toggleRecording() }
            r.togglePause = { coordinator.togglePauseRecording() }
            r.cancelCountdown = { coordinator.toggleRecording() }
            let phase = MeetingBarRecordPhase(recording: coordinator.isRecording, paused: coordinator.isRecordingPaused,
                                              saving: coordinator.isSavingRecording,
                                              countdown: coordinator.recordingCountdown != nil)
            return MeetingBarModel.recordMenu(phase, bindings, r)
        }
        a.presentMenu = { coordinator.presentMenuEntries() }
        a.toggleNotes = { notes.toggle() }
        a.viewsMenu = { model.viewsMenu() }
        a.collapse = { MeetingControlBarController.setCollapsed(true) }
        return a
    }
}

// MARK: - Panel

/// The pill's window. It exists for the whole session but is on screen only
/// while there is no meeting window to carry the controls: closed, minimised or
/// fully covered.
///
/// It is either the full pill or a 44pt puck, remembered across launches, and
/// it can be dragged by its grip (or anywhere on the puck). Where it sits, for
/// each form, is remembered too. The arithmetic is in MeetingBarPlacement.swift.
@MainActor
enum MeetingControlBarController {
    /// The pill's width, from its cells (MeetingBarLayout in MeetingBarModel.swift):
    /// grip, Meeting, mic and camera, the REC pill with Pause, Share, Draw, chat, people,
    /// More and End. Without Greenroom's own meeting window there is no Meeting button.
    static let width: CGFloat = MeetingBarLayout.width(videoButtons: false)
    static func width(videoButtons: Bool) -> CGFloat { MeetingBarLayout.width(videoButtons: videoButtons) }
    static let height: CGFloat = MeetingBarLayout.height
    static let puckSize: CGFloat = 44
    /// Gap under the pill, and between it and what stacks above it.
    static let bottomInset: CGFloat = MeetingBarPlacement.edgeMargin

    private static let collapsedKey = "meetingControlBar.collapsed"
    private static let pillFrameKey = "meetingControlBar.pillFrame"
    private static let puckFrameKey = "meetingControlBar.puckFrame"
    /// What the single remembered frame was called before there were two forms.
    private static let legacyFrameKey = "NSWindow Frame MeetingControlBar"

    /// Where the notes bar rests, and the lowest a toast may sit: each clear of
    /// the bar, wherever the bar is. The bar elsewhere (or off this screen)
    /// leaves them at their own defaults.
    static func notesBarRestingY(in area: CGRect) -> CGFloat {
        MeetingBarPlacement.notesRestingY(bar: barFrame(in: area), area: area, notesSize: SessionNotes.barSize)
    }

    static func toastFloorY(in area: CGRect) -> CGFloat {
        MeetingBarPlacement.toastFloorY(bar: barFrame(in: area), area: area,
                                        notesHeight: SessionNotes.barSize.height)
    }

    /// The bar as the stack sees it: where it is now, or where it would sit by
    /// default before it has been built.
    /// The bar where it is now; nil while it is not built.
    static var currentFrame: NSRect? { panel?.frame }

    private static func barFrame(in area: CGRect) -> CGRect {
        panel?.frame ?? MeetingBarPlacement.defaultFrame(size: CGSize(width: width, height: height), in: area)
    }

    /// Never key, never main: a click works the meeting and leaves focus where
    /// the teacher had it. (So there is no keyboard focus on the bar either: the
    /// "Collapse or expand the meeting bar" shortcut is the keyboard route, and
    /// VoiceOver reaches the puck, the grip and the menu through accessibility.)
    private final class BarPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A click on an inactive panel is the click, not a request to focus.
    private final class FirstMouseHost<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private static var panel: BarPanel?
    private static var state: MeetingBarState?
    private static var model: MeetingControlsModel?
    private static var coordinator: CoordinatorController?
    private static var observers: [NSObjectProtocol] = []
    private static var spaceObserver: NSObjectProtocol?
    private static var settleTimer: Timer?
    /// The safety check: while a meeting is live, once a second.
    private static var safetyTimer: Timer?
    /// The bar is in its Starting state: it stays on screen whatever the Meeting
    /// window does, and keeps the narrow form.
    private(set) static var isStarting = false
    /// A fade-out is running; the panel goes when it ends.
    private static var fading = false

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Whether the pill is on screen right now.
    static var isVisible: Bool { panel?.isVisible ?? false }
    static var isCollapsed: Bool { state?.collapsed ?? false }

    private static var screenAreas: [CGRect] { NSScreen.screens.map(\.visibleFrame) }
    private static var mainArea: CGRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func size(collapsed: Bool) -> CGSize {
        if isStarting { return CGSize(width: StartChoreography.startingBarWidth, height: height) }
        return collapsed ? CGSize(width: puckSize, height: puckSize)
                  : CGSize(width: width(videoButtons: model?.videoButtons ?? false), height: height)
    }

    /// Builds the pill for this session and starts watching the meeting window.
    /// It is shown or hidden by `reconcile`, which runs at once the first time.
    /// `starting` builds it in its Starting state, on screen at once and fading
    /// in: the first thing a Start click shows.
    static func install(coordinator: CoordinatorController, model: MeetingControlsModel, starting: Bool = false) {
        if fading { close() }
        guard panel == nil else { render(); return }
        guard NSScreen.main ?? NSScreen.screens.first != nil else { return }
        isStarting = starting
        self.model = model
        self.coordinator = coordinator
        let collapsed = !starting && UserDefaults.standard.bool(forKey: collapsedKey)
        let barState = MeetingBarState(collapsed: collapsed)
        state = barState

        // Moved once, stays moved. A saved spot on a display that is gone
        // would strand the bar, so it is kept only if some screen still holds it.
        let frame = MeetingBarPlacement.restore(saved: savedFrame(collapsed: collapsed),
                                                size: size(collapsed: collapsed),
                                                areas: screenAreas, defaultArea: mainArea)
        let created = BarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        // Hover help shows while another app is in front: the bar is used
        // from over the shared app, and Greenroom is rarely active (owner, 2026-11-17).
        created.allowsToolTipsWhenApplicationIsInactive = true
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The grip and the puck move the panel themselves.
        created.isMovableByWindowBackground = false
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true

        let host = FirstMouseHost(rootView: MeetingControlBarRoot(model: model, coordinator: coordinator,
                                                                  state: barState).tint(Brand.green))
        host.frame = NSRect(origin: .zero, size: frame.size)
        created.contentView = host
        panel = created

        // The meeting window's own state, whichever way it changes: covered,
        // uncovered, minimised, restored or closed. All of them land on one
        // debounced decision, so a window dragged across the screen or a
        // Mission Control sweep does not make the pill flicker.
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification,
                     NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow,
                          ParticipantGridWindowController.owns(window) else { return }
                    MeetingSurfaceOwner.syncWindowFacts()
                }
            })
        }
        // The meeting window counts as showing only on the desktop in view, so a
        // desktop switch changes the answer without the window changing at all.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MeetingSurfaceOwner.syncWindowFacts() }
        }
        // A display unplugged, or the Dock or menu bar moved: a spot that is now
        // off screen goes back to the default, one that is merely close to an
        // edge is pulled in.
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { revalidatePosition() }
        })
        if starting {
            // First thing on screen at the click: fades in, no debounce.
            created.alphaValue = reduceMotion ? 1 : 0
            render()
            startSafetyCheck()
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = StartChoreography.homeSeconds
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    created.animator().alphaValue = 1
                }
            }
            return
        }
        // The model says which surface shows; a window opened a moment ago that has
        // not reported its occlusion yet is a settle, not a flash.
        MeetingSurfaceOwner.syncWindowFacts()
        render()
        startSafetyCheck()
    }

    /// The meeting is live: the bar grows from the Starting state to the live
    /// bar (or the puck it was left as), then the usual one-surface rule applies.
    /// `windowOpening`: the Meeting window has just been opened, so the rule is
    /// applied at once and the bar does not linger beside it.
    static func finishStarting(windowOpening: Bool = false) {
        guard isStarting else { return }
        isStarting = false
        guard let panel, let state else { return }
        let collapsed = UserDefaults.standard.bool(forKey: collapsedKey)
        let old = panel.frame
        let area = MeetingBarPlacement.area(for: old, in: screenAreas) ?? mainArea
        let target = MeetingBarPlacement.resized(from: old, to: size(collapsed: collapsed), in: area)
        state.collapsed = collapsed
        move(to: target)
        avoidBar(target)
        render()
    }

    /// Draws what `MeetingSurfaceOwner.model` says: the Bar shows when the model's
    /// surface is the Bar, and steps aside when it is the Window. Not while a morph
    /// runs or is owed (the morph owns the Bar and the window) and not during a settle (the
    /// screen stays as it is until `settleElapsed`). The window itself is shown and
    /// hidden by the actions that change the model (the morph, open, close, hide).
    static func render() {
        guard let panel, morphTimeline == nil else { return }
        // Starting: the bar is the only surface, whatever else is up.
        if isStarting {
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        let model = MeetingSurfaceOwner.model
        // A morph the model owes is drawn by the morph (or finished on the next turn).
        guard model.isLive, !model.isSettling, !model.isMorphing else { return }
        if model.surface == .window {
            panel.orderOut(nil)
        } else if !panel.isVisible {
            // Without activating the app: Zoom or the slides stay in front.
            panel.orderFrontRegardless()
        }
        self.model?.foldPopOutChatIntoWindow()
    }

    // MARK: The safety check

    /// Starts the once-a-second look at whether the screen agrees with the model.
    /// It is owned here, not by the coordinator's follow loop, so it also runs after
    /// the person has closed the Meeting window (that loop stops then).
    private static func startSafetyCheck() {
        guard safetyTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { safetyCheck() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    /// One call to `screenMatches`. Quiet when it agrees. When it does not, the
    /// model wins: missed window events are read again, the Bar is drawn from the
    /// model, and a window that should not be up goes (or one that should be, comes
    /// back). In DEBUG the correction is logged, so a missed event gets found.
    private static func safetyCheck() {
        guard let panel, !isStarting, morphTimeline == nil else { return }
        let model = MeetingSurfaceOwner.model
        // A settle or a morph legitimately has both up.
        guard model.isLive, !model.isMorphing, !model.isSettling else { return }
        var onScreen = Set<MeetingSurface.Surface>()
        if ParticipantGridWindowController.windowIsOnScreen { onScreen.insert(.window) }
        if panel.isVisible { onScreen.insert(.bar) }
        guard !model.screenMatches(onScreen) else { return }
        #if DEBUG
        MeetingSurfaceOwner.debugLog("screen did not match the model, corrected. model: \(model). on screen: \(onScreen.map { "\($0)" }.sorted())")
        #endif
        MeetingSurfaceOwner.syncWindowFacts()
        render()
        let now = MeetingSurfaceOwner.model
        guard now.isLive, !now.isSettling, !now.isMorphing else { return }
        if now.surface == .bar, ParticipantGridWindowController.windowIsOnScreen {
            ParticipantGridWindowController.hide()
        } else if now.surface == .window, !ParticipantGridWindowController.windowIsOnScreen,
                  ParticipantGridWindowController.windowFacts == (exists: true, minimised: false, elsewhere: false, covered: false) {
            ParticipantGridWindowController.show(takingYouThere: false)
        }
    }

    /// A shrink or expand animation is running.
    static var morphRunning: Bool { morphTimeline != nil }

    // MARK: Shrink to the bar, and back

    private static var morphTimeline: MeetingMorph.Timeline?
    private static var morphTimer: Timer?
    private static var morphSnapshot: NSPanel?
    private static var morphWindowFrame = CGRect.zero

    /// Where a morph in progress is heading: 0 the bar, 1 the window. Nil at rest.
    static var morphTarget: CGFloat? { morphTimeline?.to }

    /// Morphs between the meeting window and the bar (0 the bar, 1 the window).
    /// A snapshot of the window travels and fades while the real bar fades the
    /// other way; the window is hidden, not closed, so its video elements stay
    /// attached and coming back is instant. A call during a morph turns it
    /// round from wherever it has got to.
    static func morph(toward target: CGFloat) {
        guard let panel else {
            // No bar built (not a custom-UI session): nothing to morph into.
            if target == 1 { ParticipantGridWindowController.show() }
            return
        }
        let now = CACurrentMediaTime()
        if let current = morphTimeline {
            if let next = MeetingMorph.retarget(current, toward: target, at: now) { morphTimeline = next }
            return
        }
        guard let shot = ParticipantGridWindowController.morphSnapshot() else {
            // Nothing to draw: do it plainly.
            if target == 1 { ParticipantGridWindowController.show(); panel.orderOut(nil) }
            else { ParticipantGridWindowController.hide(); render() }
            return
        }
        cancelSettling()
        morphWindowFrame = shot.frame

        let ghost = NSPanel(contentRect: shot.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        ghost.isReleasedWhenClosed = false
        ghost.level = .floating
        ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ghost.backgroundColor = .clear
        ghost.isOpaque = false
        ghost.hasShadow = false
        ghost.ignoresMouseEvents = true      // click-through: it is only a picture
        let picture = NSImageView(frame: NSRect(origin: .zero, size: shot.frame.size))
        picture.image = shot.image
        picture.imageScaling = .scaleAxesIndependently
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 10
        picture.layer?.masksToBounds = true
        picture.autoresizingMask = [.width, .height]
        ghost.contentView = picture
        morphSnapshot = ghost

        let from: CGFloat = target == 0 ? 1 : 0
        morphTimeline = .start(from: from, to: target, at: now)
        if target == 0 {
            // The window goes away behind its own picture; the bar starts invisible.
            ParticipantGridWindowController.hide()
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        applyMorph(at: now)
        ghost.orderFrontRegardless()

        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { tickMorph() }
        }
        RunLoop.main.add(timer, forMode: .common)
        morphTimer = timer
    }

    private static func applyMorph(at now: TimeInterval) {
        guard let panel, let ghost = morphSnapshot, let timeline = morphTimeline else { return }
        let key = MeetingMorph.keyframe(window: morphWindowFrame, bar: panel.frame,
                                        windowness: timeline.windowness(at: now),
                                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        ghost.setFrame(key.frame, display: true)
        ghost.alphaValue = key.snapshotAlpha
        panel.alphaValue = key.barAlpha
    }

    private static func tickMorph() {
        let now = CACurrentMediaTime()
        guard let timeline = morphTimeline else { return }
        applyMorph(at: now)
        guard timeline.isDone(at: now) else { return }
        morphTimer?.invalidate()
        morphTimer = nil
        morphSnapshot?.orderOut(nil)
        morphSnapshot = nil
        morphTimeline = nil
        panel?.alphaValue = 1
        if timeline.to == 1 {
            // The real window takes over from its picture, in front, without
            // activating the app; the bar steps aside.
            ParticipantGridWindowController.show()
            panel?.orderOut(nil)
        } else {
            panel?.orderFrontRegardless()
        }
        // Tells the model, which draws.
        MeetingSurfaceOwner.send(.morphFinished)
    }

    // MARK: Collapse and expand

    /// The shortcut: flips the form, but only while the bar is on screen.
    static func toggleCollapsed() {
        guard isVisible, !isStarting else { return }
        setCollapsed(!isCollapsed)
    }

    /// Shrinks the pill to the puck, or grows the puck back, keeping the edge or
    /// corner nearest the screen edge in place so it grows away from the edge.
    /// The panel's frame follows a spring (nothing under Reduce Motion) while
    /// the content crossfades inside it.
    static func setCollapsed(_ collapsed: Bool) {
        guard let panel, let state, state.collapsed != collapsed, !isStarting else { return }
        cancelSettling()
        let old = panel.frame
        saveFrame(old, collapsed: state.collapsed)
        UserDefaults.standard.set(collapsed, forKey: collapsedKey)
        let area = MeetingBarPlacement.area(for: old, in: screenAreas) ?? mainArea
        let target = MeetingBarPlacement.resized(from: old, to: size(collapsed: collapsed), in: area)
        state.collapsed = collapsed
        move(to: target)
        avoidBar(target)
    }

    // MARK: Moving

    /// The pointer let go after a drag: dock to a near edge and keep inside the
    /// screen it landed on.
    static func dropped() {
        guard let panel else { return }
        let target = MeetingBarPlacement.drop(panel.frame, areas: screenAreas)
        move(to: target)
        avoidBar(target)
    }

    /// A press began while the frame was still settling: stop where it is.
    static func cancelSettling() {
        settleTimer?.invalidate()
        settleTimer = nil
    }

    /// Settles the panel at `target` on a spring, or at once under Reduce
    /// Motion, and remembers it for the form it is now in.
    private static func move(to target: CGRect) {
        guard let panel else { return }
        cancelSettling()
        let collapsed = isCollapsed
        let start = panel.frame
        guard Collapse.animation != nil, start != target else {
            panel.setFrame(target, display: true)
            saveFrame(target, collapsed: collapsed)
            return
        }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
            MainActor.assumeIsolated {
                let t = CACurrentMediaTime() - began
                let done = t >= MeetingBarPlacement.settleSeconds
                panel.setFrame(done ? target : MeetingBarPlacement.lerp(start, target, MeetingBarPlacement.spring(t)),
                               display: true)
                // A borderless clear panel keeps the shadow of the shape it had.
                panel.invalidateShadow()
                if done {
                    timer.invalidate()
                    settleTimer = nil
                    saveFrame(target, collapsed: collapsed)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// The notes bar rests above the bar; if the bar has just landed on it,
    /// it moves up out of the way.
    private static func avoidBar(_ frame: CGRect) {
        SessionNotes.shared.keepClear(of: frame)
    }

    private static func revalidatePosition() {
        guard let panel else { return }
        cancelSettling()
        let frame = MeetingBarPlacement.restore(saved: panel.frame, size: panel.frame.size,
                                                areas: screenAreas, defaultArea: mainArea)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        saveFrame(frame, collapsed: isCollapsed)
        avoidBar(frame)
    }

    // MARK: Remembering

    private static func saveFrame(_ frame: CGRect, collapsed: Bool) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: collapsed ? puckFrameKey : pillFrameKey)
    }

    private static func savedFrame(collapsed: Bool) -> CGRect? {
        let defaults = UserDefaults.standard
        if let s = defaults.string(forKey: collapsed ? puckFrameKey : pillFrameKey) {
            let r = NSRectFromString(s)
            return r.isEmpty ? nil : r
        }
        guard !collapsed, let legacy = defaults.string(forKey: legacyFrameKey) else { return nil }
        // "x y w h screenX screenY screenW screenH": the window's own frame is the first four.
        let n = legacy.split(separator: " ").compactMap { Double($0) }
        guard n.count >= 4, n[2] > 0, n[3] > 0 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    // MARK: The puck's menu

    /// Right-click on the puck: expand, mute, stop recording, end.
    static func puckMenu() -> [MenuEntry] {
        let model = self.model, coordinator = self.coordinator
        var menu: [MenuEntry] = [.item("Expand") { setCollapsed(false) }]
        if model?.videoButtons ?? false {
            menu.append(.item("Expand to meeting window") { model?.expandToMeetingWindow() })
        }
        if let views = model?.viewsMenu(), !views.isEmpty {
            menu.append(.submenu("Views", views))
        }
        let inMeeting = model?.inMeeting ?? false
        menu.append(.item((model?.muted ?? false) ? "Unmute" : "Mute", enabled: inMeeting) {
            model?.toggleMute()
        })
        // The pill has no room for Share or Security (it is already 532pt wide), so
        // the one share control that matters when the window is away is here.
        if model?.sharing ?? false {
            menu.append(.item("Stop Share") { model?.stopShare() })
        }
        let recording = coordinator?.isRecording ?? false
        if recording {
            menu.append(.item((coordinator?.isRecordingPaused ?? false) ? "Resume recording" : "Pause recording",
                              enabled: !(coordinator?.isSavingRecording ?? false)) {
                coordinator?.togglePauseRecording()
            })
        }
        menu.append(.item("Stop Recording",
                          enabled: recording && !(coordinator?.isSavingRecording ?? false)) {
            coordinator?.toggleRecording()
        })
        menu.append(.separator)
        // Asks first, exactly as the pill's End does.
        menu.append(.item("End\u{2026}") { coordinator?.confirmAndStop() })
        return menu
    }

    /// A deliberate way back (Dock click, menu choice): the bar comes forward,
    /// without taking key from whatever the teacher is using.
    /// False when there is no bar to bring (none installed), so the caller falls
    /// back to a surface that exists.
    @discardableResult
    static func bringForward() -> Bool {
        guard let panel else { return false }
        // A morph in progress is already bringing a surface up.
        guard morphTimeline == nil else { return true }
        panel.orderFrontRegardless()
        return true
    }

    /// The bar has been built for this meeting.
    static var isInstalled: Bool { panel != nil }

    /// With `fade`, the bar fades out first (a start that failed or was
    /// cancelled); instant under Reduce Motion.
    static func close(fade: Bool) {
        guard fade, !reduceMotion, let panel, panel.isVisible, !fading else { close(); return }
        fading = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard fading, Self.panel === panel else { return }
                close()
            }
        })
    }

    static func close() {
        fading = false
        isStarting = false
        morphTimer?.invalidate()
        morphTimer = nil
        morphSnapshot?.orderOut(nil)
        morphSnapshot = nil
        morphTimeline = nil
        cancelSettling()
        safetyTimer?.invalidate()
        safetyTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        panel?.close()
        panel = nil
        state = nil
        model = nil
        coordinator = nil
    }
}
