//
//  MeetingBarContent.swift
//  Greenroom
//
//  The floating meeting bar's cells, drawn from a `MeetingBarSnapshot` and a
//  set of closures, so the live bar (MeetingControls.swift, from the
//  coordinator) and the off-screen render (sample state, a dark stand-in for the
//  glass) draw the very same views. What each cell says and its menus are in
//  MeetingBarModel.swift.
//
//  Left to right:
//    grip | [Meeting] | mic camera | REC pill, pause | Share Draw | chat people Notes Views Collapse | [End]
//
//  Red appears in two places only: the muted mic and stopped camera (state the
//  bar has always shown), and the End button. The REC dot is the recording signal
//  and pulses; nothing else in the bar is red.
//
import SwiftUI
import AppKit

// MARK: - Shared cells (also the record-only bar's)

/// A hairline between groups.
struct BarDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 20).padding(.horizontal, 4)
    }
}

/// The recording signal: red and pulsing while the file grows, grey and still
/// while paused. Reduce Motion stops the pulse.
struct BarRecDot: View {
    var live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(live ? Color.red : Color.secondary)
            .frame(width: 8, height: 8)
            .opacity(live && dim && !reduceMotion ? 0.35 : 1)
            .animation(live && !reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// An icon with a word beside it: "Meeting", "Draw". Lit with the brand tint
/// while it is on.
struct BarLabelledButton: View {
    var symbol: String
    var title: String
    var width: CGFloat
    var on = false
    /// A faint fill even when off, for the button that leaves the bar.
    var filled = false
    var help: String
    var spoken: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.primary)
            .frame(width: width, height: 28)
            .background(on ? Brand.green.opacity(0.28) : (filled ? Color.primary.opacity(0.10) : Color.clear),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Share: the Present menu (what the class sees, your look, the layout). Looks
/// like Draw, a glyph and a word; a press pops the menu rather than toggling.
struct BarPresentButton: View {
    var width: CGFloat = MeetingBarLayout.present
    var entries: () -> [MenuEntry]
    static let help = "What everyone sees, your look and the layout"

    var body: some View {
        BarIconButton(symbol: "rectangle.on.rectangle", width: width,
                      help: Self.help, spoken: "Share. What everyone sees, your look and the layout",
                      action: {})
            .overlay { MenuPopUpOverlay(label: "Share. What everyone sees, your look and the layout", entries: entries) }
            .help(Self.help)
    }
}

/// The one red control: End, and the record-only bar's Stop.
struct BarRedButton: View {
    var title: String
    var width: CGFloat
    var help: String
    var spoken: String
    /// Pressed once and waiting for the second press: reads Confirm, in place.
    var armed = false
    var armedHelp = ""
    /// The callout above the armed button: the question, and how to answer.
    var armedTitle = ""
    var armedDetail = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(armed ? "Confirm" : title)
                .font(.system(size: armed ? 11 : 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
                .frame(width: width, height: 28)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if armed {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                    }
                }
                .animation(.snappy(duration: 0.2), value: armed)
        }
        .buttonStyle(.plain)
        // No popover: it is its own window and ate the first click on Confirm
        // (owner, 2026-11-20). The question is drawn inside the bar instead.
        .help(armed ? "\(armedHelp). Esc keeps going." : help)
        .accessibilityLabel(armed ? "Confirm: \(armedHelp)" : spoken)
    }
}

/// The question an armed End or Stop asks, in a popover right above it.
/// Words only: the answer is the Confirm button it points at.
struct ConfirmCallout: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// A square icon button, 32pt.
struct BarIconButton: View {
    var symbol: String
    var tint: Color = .primary
    var width: CGFloat = MeetingBarLayout.icon
    /// Lit with the brand tint while it is on (Draw).
    var on = false
    var help: String
    var spoken: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: width, height: 32)
                .background(on ? Brand.green.opacity(0.28) : Color.clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(spoken ?? help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - The bar

struct MeetingBarActions {
    var toggleMute: () -> Void = {}
    var toggleCamera: () -> Void = {}
    /// The four camera states, built when the menu opens (this meeting only).
    var cameraStateMenu: () -> [MenuEntry] = { [] }
    var meeting: () -> Void = {}
    var toggleChat: () -> Void = {}
    /// The people count: opens the Participants list in a small window beside the bar.
    var people: () -> Void = {}
    var toggleDraw: () -> Void = {}
    var togglePause: () -> Void = {}
    /// Record, one click, while nothing is recording.
    var startRecording: () -> Void = {}
    /// While recording: arms Stop, and the second press stops (Confirm in place).
    var stopRecording: () -> Void = {}
    var end: () -> Void = {}
    /// "Keep going" in the confirm state: End goes back to End.
    var keepGoing: () -> Void = {}
    /// Built when the menu opens, so each shows the state of that moment.
    var recordMenu: () -> [MenuEntry] = { [] }
    /// What the class sees, your look, the layout (PresentMenuSpec.swift).
    var presentMenu: () -> [MenuEntry] = { [] }
    var toggleNotes: () -> Void = {}
    /// The Meeting Views entries, built when the icon is opened.
    var viewsMenu: () -> [MenuEntry] = { [] }
    var collapse: () -> Void = {}
}

struct MeetingBarContent: View {
    var s: MeetingBarSnapshot
    var bindings: ShortcutBindings
    var a: MeetingBarActions
    /// Slot for the grip, which is an AppKit drag surface in the live bar.
    var grip: AnyView

    private typealias L = MeetingBarLayout

    var body: some View {
        Group {
            if s.endArmed { endConfirmStrip.transition(.opacity) } else { row.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: s.endArmed)
        .frame(width: L.width(videoButtons: s.videoButtons), height: L.height)
    }

    /// The confirm state: the whole bar becomes the question and its two
    /// answers, drawn in the bar's own view (no popover, no second window), so
    /// one click on "End for everyone" is the click.
    private var endConfirmStrip: some View {
        HStack(spacing: 8) {
            Text(s.endAskTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.leading, 12)
            Spacer(minLength: 8)
            Button(action: a.keepGoing) {
                Text("Keep going")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("Keep the meeting going. Esc does the same.")
            Button(action: a.end) {
                Text(s.endName == LiveExitChoice.leaveMeeting.title ? "Leave" : "End for everyone")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background {
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.45))
                            EndCountdownFill(startedAt: s.endAskStartedAt, timeout: s.endAskTimeout)
                        }
                    }
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5) }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help(s.endAskDetail)
            .accessibilityLabel("Confirm: \(s.endName)")
        }
        .padding(.trailing, L.trailingPad)
    }

    private var row: some View {
        HStack(spacing: L.spacing) {
            // Grouped by what each control is about (owner, 2026-11-17):
            // the meeting's windows (smaller, bigger, which views) | you
            // (mic, camera) | the recording | teaching (share, draw, your
            // notes) | the class (chat, people) | End.
            grip
            collapseButton
            if s.videoButtons { meetingButton }
            if s.videoButtons { viewsButton }
            BarDivider()
            micButton
            cameraButton
            bubbleButton
            BarDivider()
            recordCell
            BarDivider()
            BarPresentButton(entries: a.presentMenu)
            drawButton
            notesButton
            BarDivider()
            chatButton
            peopleCount
            BarDivider()
            BarRedButton(title: "End", width: L.end,
                         help: MeetingBarModel.help(s.endName, .endSession, bindings),
                         spoken: s.endName, action: a.end)
        }
        .padding(.leading, L.leadingPad)
        .padding(.trailing, L.trailingPad)
    }

    private func help(_ name: String, _ action: ShortcutAction?) -> String {
        MeetingBarModel.help(name, action, bindings)
    }

    // MARK: Cells

    /// Brings the Meeting window straight back, as Zoom's "exit minimised" does.
    private var meetingButton: some View {
        BarLabelledButton(symbol: "arrow.up.left.and.arrow.down.right", title: "Meeting", width: L.meeting,
                          filled: true,
                          help: help("Open the Meeting window", .shrinkMeeting),
                          spoken: "Open the Meeting window", action: a.meeting)
    }

    private var micButton: some View {
        let name = s.muted ? "Unmute" : "Mute"
        return BarIconButton(symbol: s.muted ? "mic.slash.fill" : "mic.fill",
                             tint: s.muted ? .red : .primary,
                             help: help(s.muted ? "Unmute: everyone hears you again" : "Mute your microphone", .toggleMic),
                             spoken: name, action: a.toggleMute)
            .disabled(!s.inMeeting)
    }

    private var cameraButton: some View {
        let name = s.cameraOn ? "Stop Video" : "Start Video"
        return BarIconButton(symbol: s.cameraOn ? "video.fill" : "video.slash.fill",
                             tint: s.cameraOn ? .primary : .red,
                             help: help(s.cameraOn ? "Turn your camera off" : "Turn your camera on", .toggleCamera),
                             spoken: name, action: a.toggleCamera)
            .disabled(!s.inMeeting)
    }

    /// Hides the camera bubble on your own screen. It can only exist with the
    /// camera on, so with the camera off its cell stays (the bar never changes
    /// width) but is empty and out of the accessibility tree.
    private var bubbleButton: some View {
        let cell = MeetingBarModel.cameraStateCell(s.cameraState)
        return BarIconButton(symbol: cell.symbol, on: cell.on, help: cell.help, spoken: cell.spoken, action: {})
            .overlay { if s.cameraOn { MenuPopUpOverlay(label: cell.spoken, entries: a.cameraStateMenu) } }
            .opacity(s.cameraOn ? 1 : 0)
            .allowsHitTesting(s.cameraOn)
            .accessibilityHidden(!s.cameraOn)
    }

    /// The REC pill, and beside it Pause while a recording runs. Not recording,
    /// the pill takes the whole cell.
    private var recordCell: some View {
        let pill = MeetingBarModel.recordPill(s.phase, classSeconds: s.classSeconds,
                                              recordingSeconds: s.recordingSeconds)
        let running = s.phase.isRecording
        return HStack(spacing: 0) {
            recordPill(pill)
                .frame(width: running ? L.recPill : L.recCell, height: 32)
            if running {
                let paused = s.phase == .paused
                BarIconButton(symbol: paused ? "play.fill" : "pause.fill", width: L.pause,
                              help: help(paused ? "Resume Recording" : "Pause Recording", .togglePause),
                              spoken: paused ? "Resume recording" : "Pause recording",
                              action: a.togglePause)
            }
        }
        .frame(width: L.recCell, height: 32)
    }

    private func recordPill(_ pill: MeetingBarModel.RecordPill) -> some View {
        if pill.isButton { return AnyView(recordButton(pill)) }
        return AnyView(recordStatus(pill))
    }

    /// Nothing is recording: a red dot and "Record", one click to start.
    private func recordButton(_ pill: MeetingBarModel.RecordPill) -> some View {
        Button(action: a.startRecording) {
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(pill.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help("Start recording", .toggleRecording))
        .accessibilityLabel(pill.spoken)
    }

    private func recordStatus(_ pill: MeetingBarModel.RecordPill) -> some View {
        // Recording or paused: the pill is Stop itself, no menu (Pause sits
        // beside it). Pressed once it reads Confirm, as End does.
        if s.phase.isRecording { return AnyView(recordStopButton(pill)) }
        return AnyView(recordStatusLabel(pill))
    }

    private func recordStopButton(_ pill: MeetingBarModel.RecordPill) -> some View {
        Button(action: a.stopRecording) {
            HStack(spacing: 5) {
                if s.recStopArmed {
                    Text("Confirm")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    BarRecDot(live: pill.dotIsLive)
                    Text(pill.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    if let time = pill.time {
                        Text(time)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(s.phase == .paused ? Color.secondary : Color.primary)
                    }
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(s.recStopArmed ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.primary.opacity(0.08)),
                        in: Capsule())
            .overlay { if s.recStopArmed { Capsule().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5) } }
            .contentShape(Capsule())
            .animation(.snappy(duration: 0.2), value: s.recStopArmed)
        }
        .buttonStyle(.plain)
        .help(s.recStopArmed ? "Stop and save the recording. Esc keeps recording."
                             : help("\(pill.help). Click to stop", .toggleRecording))
        .accessibilityLabel(s.recStopArmed ? "Confirm: stop and save the recording" : "Stop recording. \(pill.spoken.replacingOccurrences(of: ". Menu", with: ""))")
    }

    private func recordStatusLabel(_ pill: MeetingBarModel.RecordPill) -> some View {
        HStack(spacing: 5) {
            if pill.showsDot { BarRecDot(live: pill.dotIsLive) }
            Text(pill.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(pill.showsDot ? Color.primary : Color.secondary)
            if let time = pill.time {
                Text(time)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(s.phase == .paused ? Color.secondary : Color.primary)
            }
            if pill.hasMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(pill.showsDot ? 0.08 : 0), in: Capsule())
        .contentShape(Capsule())
        .overlay { if pill.hasMenu { MenuPopUpOverlay(label: pill.spoken, entries: a.recordMenu) } }
        .help(pill.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pill.spoken)
    }

    private var drawButton: some View {
        let name = s.drawing ? "Close Drawing Tools" : "Draw on the Screen"
        return BarIconButton(
            symbol: "pencil.and.scribble", width: L.draw, on: s.drawing,
            help: help(s.drawing ? "Close the drawing tools"
                                 : "Draw on the screen you share (marks show to the meeting and in the recording)",
                       .toggleDrawing),
            spoken: name, action: a.toggleDraw)
            .disabled(!s.canDraw && !s.drawing)
            .opacity(!s.canDraw && !s.drawing ? 0.45 : 1)
    }

    private var chatButton: some View {
        BarIconButton(symbol: "bubble.left.fill",
                      help: help(s.chatOpen ? "Close the meeting chat" : "Open the meeting chat", .toggleChat),
                      spoken: s.chatOpen ? "Close chat" : "Open chat", action: a.toggleChat)
            .overlay(alignment: .topTrailing) { unreadBadge }
    }

    /// The lime is a fill, never text (DESIGN.md), so the count is dark on it.
    @ViewBuilder private var unreadBadge: some View {
        if s.unread > 0 {
            Text(s.unread > 9 ? "9+" : "\(s.unread)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Brand.fill, in: Capsule())
                .offset(x: 2, y: -1)
                .accessibilityLabel("\(s.unread) unread messages")
        }
    }

    private var peopleCount: some View {
        Button(action: a.people) {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.system(size: 14))
                Text("\(s.participants)").font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Color.primary)
            .frame(width: L.people, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Participants in the meeting: \(s.participants). Click to see who is here.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(s.participants) \(s.participants == 1 ? "participant" : "participants") in the meeting")
        .accessibilityHint("Opens the Participants list in a small window beside the bar, or takes you to the meeting window if it is open on another desktop")
        .accessibilityAddTraits(.isButton)
    }

    private var notesButton: some View {
        let c = MeetingBarModel.notesCell(open: s.notesOpen, bindings)
        return BarIconButton(symbol: c.symbol, on: c.on, help: c.help, spoken: c.spoken, action: a.toggleNotes)
    }

    private var viewsButton: some View {
        let c = MeetingBarModel.viewsCell(bindings)
        return BarIconButton(symbol: c.symbol, help: c.help, spoken: c.spoken, action: {})
            .overlay { if s.hasViews { MenuPopUpOverlay(label: c.spoken, entries: a.viewsMenu) } }
            .opacity(s.hasViews ? 1 : 0.45)
    }

    private var collapseButton: some View {
        let c = MeetingBarModel.collapseCell(bindings)
        return BarIconButton(symbol: c.symbol, help: c.help, spoken: c.spoken, action: a.collapse)
    }
}


/// The red fill that drains over the confirm wait, so the bar never silently
/// goes back to End. Starts from what is left, not from full, on a redraw.
struct EndCountdownFill: View {
    var startedAt: Date?
    var timeout: TimeInterval
    @State private var drained = false

    var body: some View {
        GeometryReader { geo in
            let left = max(0, timeout - Date().timeIntervalSince(startedAt ?? Date()))
            let full = left / max(timeout, 0.1)
            Rectangle().fill(Color.red)
                .frame(width: geo.size.width * (drained ? 0 : full))
                .onAppear { withAnimation(.linear(duration: left)) { drained = true } }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
