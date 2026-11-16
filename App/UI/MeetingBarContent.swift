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
    static let help = "What the class sees, your look and the layout"

    var body: some View {
        BarIconButton(symbol: "rectangle.on.rectangle", width: width,
                      help: Self.help, spoken: "Share. What the class sees, your look and the layout",
                      action: {})
            .overlay { MenuPopUpOverlay(label: "Share. What the class sees, your look and the layout", entries: entries) }
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
        // Asked where you press: a callout right above the button, never the
        // island (owner, 2026-11-16).
        .popover(isPresented: Binding(get: { armed && !armedTitle.isEmpty }, set: { _ in }),
                 arrowEdge: .top) {
            ConfirmCallout(title: armedTitle, detail: armedDetail)
        }
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
    var meeting: () -> Void = {}
    /// The chevron beside Meeting: the Meeting window or the Mini, by name.
    var meetingMenu: () -> [MenuEntry] = { [] }
    var toggleChat: () -> Void = {}
    /// The people count: opens the Participants list in a small window beside the bar.
    var people: () -> Void = {}
    var toggleDraw: () -> Void = {}
    var togglePause: () -> Void = {}
    /// Record, one click, while nothing is recording.
    var startRecording: () -> Void = {}
    var end: () -> Void = {}
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
        HStack(spacing: L.spacing) {
            grip
            if s.videoButtons { meetingButton }
            BarDivider()
            micButton
            cameraButton
            BarDivider()
            recordCell
            BarDivider()
            BarPresentButton(entries: a.presentMenu)
            drawButton
            BarDivider()
            chatButton
            peopleCount
            notesButton
            if s.videoButtons { viewsButton }
            collapseButton
            BarDivider()
            BarRedButton(title: "End", width: L.end,
                         help: MeetingBarModel.help(s.endName, .endSession, bindings),
                         spoken: s.endName, armed: s.endArmed, armedHelp: s.endName,
                         armedTitle: s.endAskTitle, armedDetail: s.endAskDetail, action: a.end)
        }
        .padding(.leading, L.leadingPad)
        .padding(.trailing, L.trailingPad)
        .frame(width: L.width(videoButtons: s.videoButtons), height: L.height)
    }

    private func help(_ name: String, _ action: ShortcutAction?) -> String {
        MeetingBarModel.help(name, action, bindings)
    }

    // MARK: Cells

    /// Brings the Meeting window straight back, as Zoom's "exit minimised" does;
    /// Option-click, the Mini. The chevron beside it names both sizes.
    private var meetingButton: some View {
        HStack(spacing: 0) {
            BarLabelledButton(symbol: "arrow.up.left.and.arrow.down.right", title: "Meeting", width: L.meetingButton,
                              filled: true,
                              help: help("Open the Meeting window. Option-click opens the Mini window", .shrinkMeeting),
                              spoken: "Open the Meeting window. Option-click opens the Mini window", action: a.meeting)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: L.meetingMenu, height: 28)
                .contentShape(Rectangle())
                .overlay { MenuPopUpOverlay(label: "Meeting size", entries: a.meetingMenu) }
                .help("Choose the Meeting window or the Mini window")
                .accessibilityLabel("Meeting size")
        }
    }

    private var micButton: some View {
        let name = s.muted ? "Unmute" : "Mute"
        return BarIconButton(symbol: s.muted ? "mic.slash.fill" : "mic.fill",
                             tint: s.muted ? .red : .primary,
                             help: help(name, .toggleMic), spoken: name, action: a.toggleMute)
            .disabled(!s.inMeeting)
    }

    private var cameraButton: some View {
        let name = s.cameraOn ? "Stop Video" : "Start Video"
        return BarIconButton(symbol: s.cameraOn ? "video.fill" : "video.slash.fill",
                             tint: s.cameraOn ? .primary : .red,
                             help: help(name, .toggleCamera), spoken: name, action: a.toggleCamera)
            .disabled(!s.inMeeting)
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
                                 : "Draw on the screen you share (marks show to the class and in the recording)",
                       .toggleDrawing),
            spoken: name, action: a.toggleDraw)
            .disabled(!s.canDraw && !s.drawing)
            .opacity(!s.canDraw && !s.drawing ? 0.45 : 1)
    }

    private var chatButton: some View {
        BarIconButton(symbol: "bubble.left.fill",
                      help: help(s.chatOpen ? "Close Chat" : "Open Chat", .toggleChat),
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
