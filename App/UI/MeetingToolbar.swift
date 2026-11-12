//
//  MeetingToolbar.swift
//  Greenroom
//
//  The meeting window's toolbar, drawn from plain values: what to show
//  (`MeetingToolbarState`), what each menu holds (`MeetingToolbarMenus`) and
//  what a press does (`MeetingToolbarActions`). The coordinator-bound wrapper in
//  MeetingControls.swift fills those in; the off-screen render fills them with
//  sample values.
//
//  Drawn in Zoom's style (MeetingTheme records why): #1A1A1A with a hairline on
//  top, Mute and Start Video with their carets on the left, the meeting tools
//  in the middle (Share's glyph in green), a red End on the right, and a
//  lighter rounded wash behind whatever the pointer is over. One style for
//  every control: a glyph over a short caption, the same size. Menus are popped NSMenus behind a transparent overlay (see
//  MeetingMenuAppKit.swift), because SwiftUI's Menu turns a custom label into a
//  small inline button.
//
//  How much fits is MeetingToolbarLayout's call: whatever does not goes into
//  More, so a narrow window loses a control at a time instead of squeezing.
//
import SwiftUI

struct MeetingToolbarState {
    var inMeeting = true
    var muted = false
    /// False when this Mac is not on the meeting's audio at all.
    var hasAudio = true
    var cameraOn = true
    /// Host or co-host: Security appears.
    var isHost = false
    var participants = 0
    var waiting = 0
    var peopleOpen = false
    var chatOpen = false
    var unread = 0
    var handRaised = false
    var sharing = false
    var recording = false
    var saving = false
    var recordCaption = "Record"
    var notesOn = false
    var clock = "0:00"
}

struct MeetingToolbarMenus {
    var audio: () -> [MenuEntry] = { [] }
    var video: () -> [MenuEntry] = { [] }
    var security: () -> [MenuEntry] = { [] }
    var react: () -> [MenuEntry] = { [] }
    var share: () -> [MenuEntry] = { [] }
    /// Given the controls that overflowed (as entries), the whole More menu.
    var more: ([MenuEntry]) -> [MenuEntry] = { $0 }
}

struct MeetingToolbarActions {
    var toggleMute: () -> Void = {}
    var joinAudio: () -> Void = {}
    var toggleVideo: () -> Void = {}
    var togglePeople: () -> Void = {}
    var toggleChat: () -> Void = {}
    var toggleRecording: () -> Void = {}
    var toggleNotes: () -> Void = {}
    var stopSharing: () -> Void = {}
    var end: () -> Void = {}
}

struct MeetingToolbarBar: View {
    let state: MeetingToolbarState
    let menus: MeetingToolbarMenus
    let actions: MeetingToolbarActions
    /// End asks again in place. A modal alert would activate the app, which
    /// brings the main window forward over whatever is being taught from.
    @State private var confirmingEnd = false

    static let height: CGFloat = 64
    private static let cellHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geo in
            let fit = MeetingToolbarLayout.fit(
                specs: MeetingToolbarLayout.specs(showsSecurity: state.isHost),
                // "End for everyone" is wider than End; make room while it shows.
                width: geo.size.width - (confirmingEnd ? 112 : 0))
            let groups = MeetingToolbarLayout.specs(showsSecurity: true).reduce(into: [ToolbarItemID: Int]()) { $0[$1.id] = $1.group }
            let left = fit.visible.filter { groups[$0] == 0 }
            let centre = fit.visible.filter { groups[$0] != 0 }
            // Zoom centres the middle group on the window: the shorter of the
            // two outer groups is padded to the width of the longer.
            let leftWidth = CGFloat(left.count) * (MeetingToolbarLayout.cell + MeetingToolbarLayout.caret + MeetingToolbarLayout.gap)
            let rightWidth = (fit.showsClock ? MeetingToolbarLayout.clock + MeetingToolbarLayout.gap : 0)
                + (confirmingEnd ? 190 : MeetingToolbarLayout.end)
            HStack(spacing: MeetingToolbarLayout.gap) {
                ForEach(Array(left.enumerated()), id: \.offset) { _, id in control(id) }
                Color.clear.frame(width: max(0, rightWidth - leftWidth), height: 1)
                Spacer(minLength: MeetingToolbarLayout.spacer)
                ForEach(Array(pieces(centre).enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .divider: Color.clear.frame(width: MeetingToolbarLayout.divider, height: 1)
                    case .control(let id): control(id)
                    }
                }
                if !centre.isEmpty { Color.clear.frame(width: MeetingToolbarLayout.divider, height: 1) }
                moreCell(overflow: fit.overflow)
                Spacer(minLength: MeetingToolbarLayout.spacer)
                Color.clear.frame(width: max(0, leftWidth - rightWidth), height: 1)
                if fit.showsClock {
                    Text(state.clock)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(MeetingTheme.secondaryText)
                        .frame(width: MeetingToolbarLayout.clock)
                        .help("How long the meeting has run")
                }
                endControl
            }
            .padding(.horizontal, MeetingToolbarLayout.side)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.height)
        .background(MeetingTheme.window)
        .overlay(alignment: .top) { Rectangle().fill(MeetingTheme.hairline).frame(height: 1) }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Order

    private enum Piece { case control(ToolbarItemID), divider }

    /// The visible controls with a divider wherever the group changes.
    private func pieces(_ visible: [ToolbarItemID]) -> [Piece] {
        let specs = Dictionary(uniqueKeysWithValues:
            MeetingToolbarLayout.specs(showsSecurity: true).map { ($0.id, $0.group) })
        var out: [Piece] = []
        var last: Int?
        for id in visible {
            let group = specs[id] ?? 0
            if let last, last != group { out.append(.divider) }
            out.append(.control(id))
            last = group
        }
        return out
    }

    // MARK: Controls

    @ViewBuilder private func control(_ id: ToolbarItemID) -> some View {
        switch id {
        case .mute:
            withCaret(menus.audio, label: "Choose microphone and speaker") {
                if state.inMeeting && !state.hasAudio {
                    cell(symbol: "headphones", caption: "Join audio", tint: MeetingTheme.red, action: actions.joinAudio)
                } else {
                    cell(symbol: state.muted ? "mic.slash" : "mic",
                         caption: state.muted ? "Unmute" : "Mute",
                         tint: state.muted ? MeetingTheme.red : .white, action: actions.toggleMute)
                        .disabled(!state.inMeeting)
                }
            }
        case .video:
            withCaret(menus.video, label: "Choose camera") {
                cell(symbol: state.cameraOn ? "video" : "video.slash",
                     caption: state.cameraOn ? "Stop Video" : "Start Video",
                     tint: state.cameraOn ? .white : MeetingTheme.red, action: actions.toggleVideo)
                    .disabled(!state.inMeeting)
            }
        case .security:
            menuCell(symbol: "checkmark.shield", caption: "Security", enabled: state.inMeeting,
                     entries: menus.security)
        case .people:
            cell(symbol: "person.2", caption: state.waiting > 0 ? "\(state.waiting) waiting" : "Participants",
                 on: state.peopleOpen, badge: state.participants > 0 ? "\(state.participants)" : nil,
                 captionPill: state.waiting > 0, help: peopleHelp, action: actions.togglePeople)
        case .chat:
            cell(symbol: "bubble.left", caption: "Chat", on: state.chatOpen,
                 badge: state.unread > 0 ? (state.unread > 9 ? "9+" : "\(state.unread)") : nil,
                 badgeFilled: true, action: actions.toggleChat)
        case .react:
            menuCell(symbol: "face.smiling", caption: "React", on: state.handRaised,
                     enabled: state.inMeeting, entries: menus.react)
        case .share:
            withCaret(menus.share, label: "Sharing options") {
                if state.sharing {
                    cell(symbol: "rectangle.on.rectangle.slash", caption: "Stop Share", tint: MeetingTheme.red,
                         action: actions.stopSharing)
                } else {
                    menuCell(symbol: "arrow.up.square.fill", caption: "Share", tint: MeetingTheme.zoomGreen,
                             enabled: state.inMeeting, entries: menus.share)
                }
            }
        case .record:
            cell(symbol: state.recording ? "stop.circle.fill" : "record.circle",
                 caption: state.saving ? "Saving\u{2026}" : state.recordCaption,
                 tint: state.recording ? MeetingTheme.red : .white,
                 help: state.recording ? "Stop recording" : "Record this class",
                 action: actions.toggleRecording)
                .disabled(state.saving)
        case .notes:
            cell(symbol: "note.text", caption: "Notes", on: state.notesOn, action: actions.toggleNotes)
        }
    }

    private var peopleHelp: String {
        var parts = ["Participants"]
        if state.waiting > 0 { parts.append("\(state.waiting) waiting to be admitted") }
        return parts.joined(separator: ", ")
    }

    /// A control with the little chevron that opens its menu. Share only offers a
    /// caret while it is not itself the menu.
    @ViewBuilder private func withCaret<Content: View>(_ entries: @escaping () -> [MenuEntry],
                                                       label: String,
                                                       @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(MeetingTheme.secondaryText)
                .frame(width: MeetingToolbarLayout.caret, height: Self.cellHeight)
                .contentShape(Rectangle())
                .overlay { MenuPopUpOverlay(label: label, entries: entries) }
                .help(label)
        }
    }

    private func moreCell(overflow: [ToolbarItemID]) -> some View {
        menuCell(symbol: "ellipsis", caption: "More", badge: overflow.isEmpty ? nil : "\(overflow.count)") {
            menus.more(overflow.compactMap(overflowEntry))
        }
    }

    /// A control that did not fit, as a line in More. The ones with their own
    /// menus come as submenus.
    private func overflowEntry(_ id: ToolbarItemID) -> MenuEntry? {
        switch id {
        case .mute: return nil
        case .video:
            return .item(state.cameraOn ? "Stop Video" : "Start Video", enabled: state.inMeeting, actions.toggleVideo)
        case .security: return .submenu("Security", enabled: state.inMeeting, menus.security())
        case .people:
            return .item(state.waiting > 0 ? "Participants (\(state.waiting) waiting)" : "Participants",
                         checked: state.peopleOpen, actions.togglePeople)
        case .chat:
            return .item(state.unread > 0 ? "Chat (\(state.unread) unread)" : "Chat",
                         checked: state.chatOpen, actions.toggleChat)
        case .react: return .submenu("React", enabled: state.inMeeting, menus.react())
        case .share:
            return state.sharing ? .item("Stop sharing", actions.stopSharing)
                                 : .submenu("Share", enabled: state.inMeeting, menus.share())
        case .record:
            return .item(state.recording ? "Stop recording" : "Record", enabled: !state.saving,
                         actions.toggleRecording)
        case .notes: return .item("Notes", checked: state.notesOn, actions.toggleNotes)
        }
    }

    // MARK: Cells

    /// The one control shape. Every cell on the bar is this: the glyph above its
    /// caption, with Zoom's hover wash behind it.
    private func glyph(symbol: String, caption: String, tint: Color = .white, on: Bool = false,
                       badge: String? = nil, badgeFilled: Bool = false, captionPill: Bool = false) -> some View {
        ToolbarGlyph(symbol: symbol, caption: caption, tint: tint, on: on, badge: badge,
                     badgeFilled: badgeFilled, captionPill: captionPill, height: Self.cellHeight)
    }

    private func cell(symbol: String, caption: String, tint: Color = .white, on: Bool = false,
                      badge: String? = nil, badgeFilled: Bool = false, captionPill: Bool = false,
                      help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph(symbol: symbol, caption: caption, tint: tint, on: on, badge: badge,
                  badgeFilled: badgeFilled, captionPill: captionPill)
        }
        .buttonStyle(.plain)
        .help(help ?? caption)
        .accessibilityLabel(caption)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func menuCell(symbol: String, caption: String, tint: Color = .white, on: Bool = false,
                          badge: String? = nil, enabled: Bool = true, entries: @escaping () -> [MenuEntry]) -> some View {
        glyph(symbol: symbol, caption: caption, tint: tint, on: on, badge: badge)
            .opacity(enabled ? 1 : 0.4)
            // An AppKit overlay ignores SwiftUI's .disabled, so it is switched off here.
            .overlay { if enabled { MenuPopUpOverlay(label: caption, entries: entries) } }
            .help(caption)
    }

    // MARK: End

    @ViewBuilder private var endControl: some View {
        if confirmingEnd {
            HStack(spacing: 6) {
                Button("Cancel") { confirmingEnd = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(MeetingTheme.secondaryText)
                Button {
                    confirmingEnd = false
                    actions.end()
                } label: {
                    Text("End for everyone")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(MeetingTheme.end, in: RoundedRectangle(cornerRadius: MeetingTheme.controlRadius + 2))
                }
                .buttonStyle(.plain)
                .help("Ends the meeting for everyone, saves any recording and turns the camera off")
            }
        } else {
            Button { confirmingEnd = true } label: {
                Text("End")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 32)
                    .background(MeetingTheme.end, in: RoundedRectangle(cornerRadius: MeetingTheme.controlRadius + 2))
            }
            .buttonStyle(.plain)
            .help("End the session")
            .accessibilityLabel("End session")
        }
    }
}


/// One cell's drawing: glyph 22pt over an 11pt caption, a lighter rounded wash
/// while the pointer is over it or its panel is open.
private struct ToolbarGlyph: View {
    let symbol: String
    let caption: String
    let tint: Color
    let on: Bool
    let badge: String?
    let badgeFilled: Bool
    let captionPill: Bool
    let height: CGFloat
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(tint)
                .frame(height: 24)
                .overlay(alignment: .topTrailing) { badgeView.offset(x: 14, y: -5) }
            Text(caption)
                .font(.system(size: 11, weight: captionPill ? .semibold : .regular))
                .foregroundStyle(captionPill ? Color.black : MeetingTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .padding(.horizontal, captionPill ? 4 : 0)
                .background(captionPill ? Brand.fill : Color.clear, in: Capsule())
        }
        .frame(width: MeetingToolbarLayout.cell, height: height)
        .background(on || hovering ? MeetingTheme.hover : Color.clear,
                    in: RoundedRectangle(cornerRadius: MeetingTheme.controlRadius))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Chat's unread is Zoom's red badge; a participant count is information, so
    /// it stays a neutral grey pill.
    @ViewBuilder private var badgeView: some View {
        if let badge {
            Text(badge)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(badgeFilled ? MeetingTheme.red : Color.white.opacity(0.22), in: Capsule())
                .accessibilityLabel(badge)
        }
    }
}
