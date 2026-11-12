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
    /// The meeting window's right column. Lives here so the toolbar button and
    /// the window it opens a panel in cannot disagree about which is showing.
    @Published var sidePanel: MeetingSidePanel?
    /// Drives the two clocks; the views redraw on it.
    @Published private(set) var now = Date()

    /// The meeting window (and so the Meeting window toggle) exists only when
    /// the SDK really started in custom UI: Zoom then opens no windows.
    var videoButtons: Bool { coordinator.zoomChatClient.didUseCustomUI }

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
            waitingCount = client.waitingRoomNames().count
            raisedHands = client.meetingRoster().filter { $0.isRaisingHand && !$0.isMyself }.count
            // Device lists are not worth asking for every second.
            if ticks % 5 == 1 { refreshDevices() }
        }
        meetingWindowOpen = coordinator.meetingWindowOpen
        if !meetingWindowOpen, sidePanel != nil { sidePanel = nil }
        chatOpen = sidePanel == .chat || ChatWindowController.isOpen
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
    /// Greenroom sends as the camera.
    func startShare(displayID: CGDirectDisplayID) {
        act("Sharing a display through Zoom", code: "share_start") { $0.startShare(displayID: displayID) }
        sharing = true
    }

    func stopShare() {
        act("Stopped sharing", code: "share_stop") { $0.stopShare() }
        sharing = false
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

    func toggleLock() {
        let lock = !locked
        act(lock ? "Meeting locked" : "Meeting unlocked", code: "other") { $0.setMeetingLocked(lock) }
        locked = lock
    }

    /// With the meeting window open the chat is a panel in it (or the column
    /// window, in an arranged session); closed, it is a window of its own,
    /// opened on demand and then left alone: no layout, so no tiling pass ever
    /// claims it (the follow loops only run for an arranged session).
    func toggleChat() {
        if coordinator.meetingWindowOpen, !coordinator.sessionArranges {
            sidePanel = sidePanel == .chat ? nil : .chat
        } else if ChatWindowController.isOpen {
            ChatWindowController.close()
        } else {
            ChatWindowController.show(chat: coordinator.zoomChatBridge,
                                      layout: coordinator.sessionArranges ? coordinator.workspaceLayout : nil)
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

    func toggleMeetingWindow() {
        coordinator.toggleMeetingWindow()
        refresh()
    }

    static func elapsed(since start: Date?) -> String {
        guard let start else { return "0:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Toolbar (the meeting window's foot)

/// Glyph over a short caption, in Zoom's own words where Zoom has one, per
/// DESIGN.md. Below `compactWidth` the captions go and it is icons only, which
/// is what the small arranged slot gets.
struct MeetingToolbarView: View {
    @ObservedObject var model: MeetingControlsModel
    @ObservedObject var coordinator: CoordinatorController
    @ObservedObject private var notes = SessionNotes.shared
    /// End asks again in place. A modal alert would activate the app, which
    /// brings the main window forward over whatever is being taught from.
    @State private var confirmingEnd = false

    static let height: CGFloat = 64
    private static let compactWidth: CGFloat = 780

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < Self.compactWidth
            HStack(spacing: 2) {
                audioControl(compact: compact)
                cell("Video", compact: compact,
                     symbol: model.cameraOn ? "video.fill" : "video.slash.fill",
                     caption: model.cameraOn ? "Stop Video" : "Start Video",
                     tint: model.cameraOn ? .primary : .red,
                     action: model.toggleCamera)
                    .disabled(!model.inMeeting)
                shareControl(compact: compact)
                divider
                cell("People", compact: compact, symbol: "person.2.fill", caption: "People",
                     on: model.sidePanel == .people, badge: peopleBadge, action: model.togglePeople)
                cell("Chat", compact: compact, symbol: "bubble.left.fill", caption: "Chat",
                     on: model.sidePanel == .chat || (model.chatOpen && model.sidePanel == nil),
                     badge: model.unread > 0 ? (model.unread > 9 ? "9+" : "\(model.unread)") : nil,
                     action: model.toggleChat)
                reactControl(compact: compact)
                divider
                recordControl(compact: compact)
                cell("Notes", compact: compact, symbol: "note.text", caption: "Notes",
                     on: notes.effectiveEnabled, action: notes.toggle)
                if model.isHost { hostControl(compact: compact) }
                Spacer(minLength: 8)
                Text(MeetingControlsModel.elapsed(since: { _ = model.now; return coordinator.sessionStartedAt }()))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52)
                    .help("How long the meeting has run")
                endControl
            }
            .padding(.horizontal, 12)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.height)
    }

    // MARK: Pieces

    private var peopleBadge: String? {
        let count = model.participantCount
        if model.waitingCount > 0 { return "\(model.waitingCount) waiting" }
        return count > 0 ? "\(count)" : nil
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 28).padding(.horizontal, 6)
    }

    private func glyph(_ symbol: String, caption: String, compact: Bool, tint: Color = .primary,
                       on: Bool = false, badge: String? = nil) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(height: 20)
                .overlay(alignment: .topTrailing) { badgeView(badge).offset(x: 14, y: -6) }
            if !compact {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: compact ? 36 : 60, minHeight: 44)
        .padding(.horizontal, compact ? 2 : 8)
        .background(on ? Brand.green.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    /// The lime is a fill, never text (DESIGN.md), so the count is dark on it.
    @ViewBuilder private func badgeView(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Brand.fill, in: Capsule())
                .accessibilityLabel(text)
        }
    }

    private func cell(_ label: String, compact: Bool, symbol: String, caption: String,
                      tint: Color = .primary, on: Bool = false, badge: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph(symbol, caption: caption, compact: compact, tint: tint, on: on, badge: badge)
        }
        .buttonStyle(.plain)
        .help(caption)
        .accessibilityLabel(caption)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func menuCell<Items: View>(compact: Bool, symbol: String, caption: String,
                                       tint: Color = .primary, on: Bool = false,
                                       @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            glyph(symbol, caption: caption, compact: compact, tint: tint, on: on)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(caption)
        .accessibilityLabel(caption)
    }

    // MARK: Audio

    @ViewBuilder private func audioControl(compact: Bool) -> some View {
        if model.inMeeting && !model.hasAudio {
            cell("Join audio", compact: compact, symbol: "headphones", caption: "Join audio",
                 tint: .red, action: model.joinAudio)
        } else {
            HStack(spacing: 0) {
                cell("Mic", compact: compact,
                     symbol: model.muted ? "mic.slash.fill" : "mic.fill",
                     caption: model.muted ? "Unmute" : "Mute",
                     tint: model.muted ? .red : .primary,
                     action: model.toggleMute)
                    .disabled(!model.inMeeting)
                Menu {
                    Section("Microphone") {
                        ForEach(model.micDevices, id: \.id) { device in
                            Button {
                                model.selectMicrophone(id: device.id, name: device.name)
                            } label: {
                                deviceLabel(device.name, selected: device.id == model.micSelectedID)
                            }
                        }
                    }
                    Section("Speaker") {
                        ForEach(model.speakerDevices, id: \.id) { device in
                            Button {
                                model.selectSpeaker(id: device.id, name: device.name)
                            } label: {
                                deviceLabel(device.name, selected: device.id == model.speakerSelectedID)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Microphone and speaker")
                .accessibilityLabel("Choose microphone and speaker")
            }
        }
    }

    @ViewBuilder private func deviceLabel(_ name: String, selected: Bool) -> some View {
        if selected { Label(name, systemImage: "checkmark") } else { Text(name) }
    }

    // MARK: Share

    @ViewBuilder private func shareControl(compact: Bool) -> some View {
        if model.sharing {
            cell("Stop share", compact: compact, symbol: "rectangle.on.rectangle.slash",
                 caption: "Stop Share", tint: .red, action: model.stopShare)
        } else {
            menuCell(compact: compact, symbol: "arrow.up.forward.app", caption: "Share") {
                // Zoom's own share of a whole display: a different thing from
                // the picture Greenroom sends as the camera.
                ForEach(coordinator.zoomChatClient.shareableDisplays(), id: \.id) { display in
                    Button(display.label) { model.startShare(displayID: display.id) }
                }
            }
            .disabled(!model.inMeeting)
        }
    }

    // MARK: React

    private func reactControl(compact: Bool) -> some View {
        menuCell(compact: compact, symbol: "hand.thumbsup", caption: "React", on: model.handRaised) {
            Button(model.handRaised ? "Lower my hand" : "Raise my hand", action: model.toggleHand)
            Divider()
            ForEach(ZoomMeetingSDKClient.Reaction.allCases, id: \.self) { reaction in
                Button(reaction.rawValue) { model.react(reaction) }
            }
        }
        .disabled(!model.inMeeting)
    }

    // MARK: Record

    private func recordControl(compact: Bool) -> some View {
        let recording = coordinator.isRecording
        let saving = coordinator.isSavingRecording
        let caption = saving ? "Saving\u{2026}"
            : recording ? MeetingControlsModel.elapsed(since: { _ = model.now; return coordinator.recordingStartedAt }())
            : "Record"
        return Button { coordinator.toggleRecording() } label: {
            glyph(recording ? "stop.circle.fill" : "record.circle", caption: caption, compact: compact,
                  tint: recording ? .red : .primary)
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .help(recording ? "Stop recording" : "Record this class")
        .accessibilityLabel(recording ? "Stop recording" : "Record")
    }

    // MARK: Host tools

    private func hostControl(compact: Bool) -> some View {
        menuCell(compact: compact, symbol: "shield.lefthalf.filled", caption: "Host tools") {
            Button("Mute all", action: model.muteAll)
            Button("Ask all to unmute", action: model.askAllToUnmute)
            if model.waitingCount > 0 {
                Button("Admit all waiting (\(model.waitingCount))", action: model.admitAll)
            }
            Divider()
            Button(model.locked ? "Unlock meeting" : "Lock meeting", action: model.toggleLock)
        }
    }

    // MARK: End

    @ViewBuilder private var endControl: some View {
        if confirmingEnd {
            HStack(spacing: 6) {
                Button("Cancel") { confirmingEnd = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button {
                    confirmingEnd = false
                    coordinator.stop()
                } label: {
                    Text("End for everyone")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help("Ends the meeting for everyone, saves any recording and turns the camera off")
            }
        } else {
            Button { confirmingEnd = true } label: {
                Text("End")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 28)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("End the session")
            .accessibilityLabel("End session")
        }
    }
}

// MARK: - Pill

private struct MeetingControlBarView: View {
    @ObservedObject var model: MeetingControlsModel
    @ObservedObject var coordinator: CoordinatorController
    @ObservedObject private var notes = SessionNotes.shared

    var body: some View {
        HStack(spacing: 4) {
            iconButton(model.muted ? "mic.slash.fill" : "mic.fill",
                       tint: model.muted ? .red : .primary,
                       help: model.muted ? "Unmute" : "Mute",
                       action: model.toggleMute)
                .disabled(!model.inMeeting)
            iconButton(model.cameraOn ? "video.fill" : "video.slash.fill",
                       tint: model.cameraOn ? .primary : .red,
                       help: model.cameraOn ? "Stop video" : "Start video",
                       action: model.toggleCamera)
                .disabled(!model.inMeeting)

            divider
            recordButton
            divider

            iconButton("bubble.left.fill", tint: .primary,
                       help: model.chatOpen ? "Close chat" : "Open chat",
                       action: model.toggleChat)
                .overlay(alignment: .topTrailing) { unreadBadge }
            notesButton
            if model.videoButtons {
                // One button for the meeting window. The pill is up only while
                // that window is closed, minimised or covered, so this brings it
                // back; it also closes it if the pill is still showing.
                iconButton("rectangle.inset.filled.on.rectangle", tint: .primary,
                           help: "Meeting window: video, people, chat and controls",
                           action: model.toggleMeetingWindow)
                    .accessibilityLabel("Meeting window")
            }
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.system(size: 13))
                Text("\(model.participantCount)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .frame(width: 48, height: 32)
            .help("People in the meeting")

            divider
            Text(MeetingControlsModel.elapsed(since: { _ = model.now; return coordinator.sessionStartedAt }()))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56)
                .help("How long the meeting has run")

            Button { coordinator.confirmAndStop() } label: {
                Text("End")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 28)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("End the session")
            .accessibilityLabel("End session")
        }
        .padding(.horizontal, 8)
        .frame(width: MeetingControlBarController.width(videoButtons: model.videoButtons), height: MeetingControlBarController.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 20).padding(.horizontal, 4)
    }

    private func iconButton(_ symbol: String, tint: Color, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Filled with the brand tint while the notes bar is open.
    private var notesButton: some View {
        toggleButton("note.text", on: notes.effectiveEnabled,
                     label: notes.effectiveEnabled ? "Close notes" : "Open notes",
                     help: notes.effectiveEnabled ? "Close notes" : "Open notes",
                     action: notes.toggle)
    }

    /// An icon button that shows whether its window is open.
    private func toggleButton(_ symbol: String, on: Bool, label: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
                .background(on ? Brand.green.opacity(0.28) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var recordButton: some View {
        Button { coordinator.toggleRecording() } label: {
            HStack(spacing: 6) {
                Image(systemName: coordinator.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(coordinator.isRecording ? Color.red : Color.primary)
                Text(recordLabel)
                    .font(.system(size: 12, weight: .medium,
                                  design: coordinator.isRecording ? .monospaced : .default))
                    .foregroundStyle(coordinator.isRecording ? Color.primary : Color.secondary)
            }
            .frame(width: 84, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(coordinator.isSavingRecording)
        .help(coordinator.isRecording ? "Stop recording" : "Record this class")
        .accessibilityLabel(coordinator.isRecording ? "Stop recording" : "Record")
    }

    private var recordLabel: String {
        if coordinator.isSavingRecording { return "Saving\u{2026}" }
        guard coordinator.isRecording else { return "Record" }
        _ = model.now // read, so the tick redraws it
        return MeetingControlsModel.elapsed(since: coordinator.recordingStartedAt)
    }

    /// The lime is a fill, never text (DESIGN.md), so the count is dark on it.
    @ViewBuilder private var unreadBadge: some View {
        if model.unread > 0 {
            Text(model.unread > 9 ? "9+" : "\(model.unread)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Brand.fill, in: Capsule())
                .offset(x: 2, y: -1)
                .accessibilityLabel("\(model.unread) unread messages")
        }
    }
}

// MARK: - Panel

/// The pill's window. It exists for the whole session but is on screen only
/// while there is no meeting window to carry the controls: closed, minimised or
/// fully covered. With Zoom's own window as the picture (custom UI off) there
/// is never a meeting window, so it simply stays up.
@MainActor
enum MeetingControlBarController {
    static let width: CGFloat = 448
    /// One more 32pt button (and its gap) when the meeting window is offered.
    static func width(videoButtons: Bool) -> CGFloat { videoButtons ? width + 36 : width }
    static let height: CGFloat = 44
    /// Gap under the pill, and between it and what stacks above it.
    static let bottomInset: CGFloat = 16
    private static let gap: CGFloat = 12

    /// Where the notes bar rests (its height is SessionNotesBar.barSize) and the
    /// lowest a toast may sit: each clear of the bar below it.
    static let notesBarRestingY: CGFloat = bottomInset + height + gap
    static let toastFloorY: CGFloat = notesBarRestingY + SessionNotes.barSize.height + gap

    /// Never key, never main: a click works the meeting and leaves focus where
    /// the teacher had it.
    private final class BarPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A click on an inactive panel is the click, not a request to focus.
    private final class FirstMouseHost<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private static var panel: BarPanel?
    private static var observers: [NSObjectProtocol] = []
    private static var pending: DispatchWorkItem?

    /// Whether the pill is on screen right now.
    static var isVisible: Bool { panel?.isVisible ?? false }

    /// Builds the pill for this session and starts watching the meeting window.
    /// It is shown or hidden by `reconcile`, which runs at once the first time.
    static func install(coordinator: CoordinatorController, model: MeetingControlsModel) {
        guard panel == nil else { reconcile(immediately: false); return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let barWidth = width(videoButtons: model.videoButtons)
        let size = NSSize(width: barWidth, height: height)
        let area = screen.visibleFrame
        let created = BarPanel(
            contentRect: NSRect(x: (area.midX - size.width / 2).rounded(),
                                y: area.minY + bottomInset,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.isMovableByWindowBackground = true
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true

        let host = FirstMouseHost(rootView: MeetingControlBarView(model: model, coordinator: coordinator)
            .tint(Brand.green))
        host.frame = NSRect(origin: .zero, size: size)
        created.contentView = host

        // Moved once, stays moved. A saved spot on a display that is gone
        // would strand the bar, so only keep it if some screen still holds it.
        created.setFrameAutosaveName("MeetingControlBar")
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(created.frame) }) {
            created.setFrame(NSRect(x: (area.midX - size.width / 2).rounded(),
                                    y: area.minY + bottomInset,
                                    width: size.width, height: size.height), display: false)
        }

        // A remembered frame may carry the other width: keep where it was
        // centred, resize around that.
        if abs(created.frame.width - barWidth) > 0.5 {
            let f = created.frame
            created.setFrame(NSRect(x: (f.midX - barWidth / 2).rounded(), y: f.minY,
                                    width: barWidth, height: height), display: false)
        }
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
                    reconcile(immediately: false)
                }
            })
        }
        // A window opened a moment ago has not reported its occlusion yet, which
        // would flash the pill; let the debounce settle it. With none, show now.
        reconcile(immediately: !ParticipantGridWindowController.meetingWindowIsOpen)
    }

    /// Shows the pill when nothing else carries the controls, hides it when the
    /// meeting window does. Debounced by half a second except the first time.
    static func reconcile(immediately: Bool) {
        pending?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let panel else { return }
                if ParticipantGridWindowController.meetingWindowIsShowing {
                    panel.orderOut(nil)
                } else if !panel.isVisible {
                    // Without activating the app: Zoom or the slides stay in front.
                    panel.orderFrontRegardless()
                }
            }
        }
        pending = work
        if immediately {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    static func close() {
        pending?.cancel()
        pending = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        panel?.close()
        panel = nil
    }
}
