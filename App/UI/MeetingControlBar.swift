//
//  MeetingControlBar.swift
//  Greenroom
//
//  A class that arranges nothing still needs its few controls somewhere. This
//  is a small floating pill at the bottom centre of the screen: mute, camera,
//  record, chat, who is here, how long, End. Zoom's own window is the meeting
//  picture; this is all Greenroom puts on screen.
//
//  Same panel as the readiness card (ParticipantGridWindow.swift): it can never
//  become key or main, so a click on a button works the meeting without pulling
//  Greenroom in front of whatever the teacher is teaching from.
//
import SwiftUI
import AppKit
import Combine

// MARK: - State

/// What the bar shows. The SDK has no change callbacks for your own mic and
/// camera, so they are polled once a second, as the participant panel does.
@MainActor
final class MeetingControlBarModel: ObservableObject {
    @Published private(set) var muted = false
    @Published private(set) var cameraOn = true
    @Published private(set) var inMeeting = false
    @Published private(set) var participantCount = 0
    @Published private(set) var chatOpen = false
    @Published private(set) var unread = 0
    /// Speaker and People are offered only when the SDK really started in custom
    /// UI: Zoom then opens no windows, so these are how the video gets on screen.
    let videoButtons: Bool
    @Published private(set) var speakerOpen = false
    @Published private(set) var peopleOpen = false
    /// Drives the two clocks; the bar redraws on it.
    @Published private(set) var now = Date()

    let coordinator: CoordinatorController
    private var timer: Timer?
    private var chatSub: AnyCancellable?
    /// Incoming messages the teacher has had the chance to read.
    private var seenIncoming = 0

    init(coordinator: CoordinatorController) {
        self.coordinator = coordinator
        videoButtons = coordinator.onDemandVideoAvailable
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
        let client = coordinator.zoomChatClient
        inMeeting = client.myUserID != nil
        if inMeeting {
            muted = client.iAmMuted
            cameraOn = client.myVideoIsOn
            // Others, plus you: the number Zoom's own Participants button shows.
            participantCount = client.participantUserIDs(excludingSelf: false).count
        }
        chatOpen = ChatWindowController.isOpen
        if videoButtons {
            // A window closed by its own close button shows up here, and the
            // speaker follows the head count even when no callback fired.
            coordinator.syncOnDemandSpeaker()
            speakerOpen = coordinator.onDemandSpeakerOpen
            peopleOpen = coordinator.onDemandPeopleOpen
        }
        let incoming = coordinator.zoomChatBridge.messages.filter { !$0.isOutgoing }.count
        if chatOpen { seenIncoming = incoming }
        unread = max(0, incoming - seenIncoming)
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

    func toggleSpeaker() {
        coordinator.toggleOnDemandSpeaker()
        refresh()
    }

    func togglePeople() {
        coordinator.toggleOnDemandPeople()
        refresh()
    }

    /// The chat opens on demand and is then left alone: no layout, so no tiling
    /// pass ever claims it (the follow loops only run for an arranged session).
    func toggleChat() {
        if ChatWindowController.isOpen {
            ChatWindowController.close()
        } else {
            ChatWindowController.show(chat: coordinator.zoomChatBridge, layout: nil)
        }
        refresh()
    }
}

// MARK: - View

private struct MeetingControlBarView: View {
    @ObservedObject var model: MeetingControlBarModel
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
                toggleButton("person.crop.rectangle", on: model.speakerOpen,
                             label: model.speakerOpen ? "Close speaker window" : "Open speaker window",
                             help: model.speakerOpen
                                 ? "Close the speaker window"
                                 : "Open the speaker window. Zoom shows the speaker once 3 or more people are in the meeting.",
                             action: model.toggleSpeaker)
                toggleButton("square.grid.2x2", on: model.peopleOpen,
                             label: model.peopleOpen ? "Close participants panel" : "Open participants panel",
                             help: model.peopleOpen
                                 ? "Close the participants panel"
                                 : "Open the participants panel: everyone in the meeting, on your second display if you have one.",
                             action: model.togglePeople)
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
            Text(elapsed(since: coordinator.sessionStartedAt))
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
        return elapsed(since: coordinator.recordingStartedAt)
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

    private func elapsed(since start: Date?) -> String {
        _ = model.now // read, so the tick redraws it
        guard let start else { return "0:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Panel

@MainActor
enum MeetingControlBarController {
    static let width: CGFloat = 448
    /// Two more 32pt buttons (and their gaps) when the video windows are offered.
    static func width(videoButtons: Bool) -> CGFloat { videoButtons ? width + 72 : width }
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
    private static var model: MeetingControlBarModel?

    static var isVisible: Bool { panel?.isVisible ?? false }

    static func show(coordinator: CoordinatorController) {
        guard panel == nil else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let barModel = MeetingControlBarModel(coordinator: coordinator)
        let barWidth = width(videoButtons: barModel.videoButtons)
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

        let host = FirstMouseHost(rootView: MeetingControlBarView(model: barModel, coordinator: coordinator)
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
        model = barModel
        // Without activating the app: Zoom or the slides stay in front.
        created.orderFrontRegardless()
    }

    static func close() {
        model?.stop()
        model = nil
        panel?.close()
        panel = nil
    }
}
