//
//  MeetingBarModel.swift
//  Greenroom
//
//  The pure half of the floating meeting bar: what each cell says, what its
//  menu holds in each state, what its hover help reads, and how wide the bar
//  is. Foundation and the shortcut model only, so the test target compiles
//  this file as it is and the off-screen render draws the same values.
//
//  The bar (MeetingControls.swift draws it from the coordinator,
//  MeetingBarContent.swift draws it from a snapshot) follows these rules, set
//  by the owner on 2026-11-13 after "some of the buttons don't even make sense":
//
//   - every icon that is not universal carries a word (Meeting, Draw);
//   - one timer, the class time, inside the REC pill, whose hover help gives
//     the recording's own length;
//   - End is the only red control (the REC dot is a signal, not a control);
//   - what is used rarely folds into the REC menu and the More menu, and
//     nothing is lost.
//
import Foundation

// MARK: - What the bar is told

/// Where the recording is. One value, so a cell never has to combine four flags.
enum MeetingBarRecordPhase: Equatable {
    case idle
    /// The 3-2-1 before a recording: the pill offers to cancel it.
    case countdown
    /// The file is closing: nothing applies.
    case saving
    case recording
    case paused

    var isRecording: Bool { self == .recording || self == .paused }

    init(recording: Bool, paused: Bool, saving: Bool, countdown: Bool) {
        if saving { self = .saving }
        else if recording { self = paused ? .paused : .recording }
        else if countdown { self = .countdown }
        else { self = .idle }
    }
}

/// Everything the bar's cells show, as plain values.
struct MeetingBarSnapshot: Equatable {
    var inMeeting = true
    var muted = false
    var cameraOn = true
    /// Greenroom's own meeting window exists, so there is a "Meeting" button.
    var videoButtons = true
    var unread = 0
    var participants = 1
    var phase: MeetingBarRecordPhase = .idle
    var classSeconds: TimeInterval = 0
    var recordingSeconds: TimeInterval = 0
    var drawing = false
    var canDraw = true
    var chatOpen = false
    /// The notes bar is open (the Notes icon is lit).
    var notesOpen = false
    /// The Meeting Views icon is live; with the setting off it is dimmed.
    var hasViews = true
    /// "End Meeting for All" when hosting, "Leave Meeting" otherwise: what End does.
    var endName = "End Meeting for All"
    /// End was pressed once and waits for the second press.
    var endArmed = false
    var endAskTitle = ""
    var endAskDetail = ""
}

// MARK: - Text

enum MeetingBarModel {

    /// m:ss, or h:mm:ss past the hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "Mute (⌥⌘M)": the control's name, and the key the person has bound to it
    /// (never a hardcoded one). With no key bound, just the name.
    static func help(_ name: String, _ action: ShortcutAction?, _ bindings: ShortcutBindings) -> String {
        guard let action, let combo = bindings.combo(for: .action(action)) else { return name }
        return "\(name) (\(combo.glyphs))"
    }

    /// The REC pill.
    struct RecordPill: Equatable {
        /// "REC", "Paused", "Record", "Starting\u{2026}", "Saving\u{2026}".
        var label: String
        /// The class time, while a recording runs. Nil otherwise.
        var time: String?
        /// Hover help: the recording's own length beside the class time.
        var help: String
        /// What VoiceOver says.
        var spoken: String
        var showsDot: Bool
        var dotIsLive: Bool
        /// A recording can be started or stopped from this pill.
        var hasMenu: Bool
        /// Nothing is recording: the pill is a plain one-click Record button.
        var isButton = false
    }

    /// The pill carries ONE timer, the class time. The recording's length is in
    /// the hover help ("Recording 1:29 \u{00B7} class 1:38"), so two clocks are
    /// never on screen unexplained.
    static func recordPill(_ phase: MeetingBarRecordPhase, classSeconds: TimeInterval,
                           recordingSeconds: TimeInterval) -> RecordPill {
        let cls = clock(classSeconds), rec = clock(recordingSeconds)
        switch phase {
        case .recording:
            return RecordPill(label: "REC", time: cls,
                              help: "Recording \(rec) \u{00B7} class \(cls)",
                              spoken: "Recording. Class time \(cls). Recording length \(rec). Menu",
                              showsDot: true, dotIsLive: true, hasMenu: true)
        case .paused:
            return RecordPill(label: "Paused", time: cls,
                              help: "Recording paused at \(rec) \u{00B7} class \(cls)",
                              spoken: "Recording paused at \(rec). Class time \(cls). Menu",
                              showsDot: true, dotIsLive: false, hasMenu: true)
        case .countdown:
            return RecordPill(label: "Starting\u{2026}", time: nil,
                              help: "Recording is about to start. Open the menu to cancel it.",
                              spoken: "Recording is about to start. Menu",
                              showsDot: false, dotIsLive: false, hasMenu: true)
        case .saving:
            return RecordPill(label: "Saving\u{2026}", time: nil,
                              help: "Saving the recording",
                              spoken: "Saving the recording",
                              showsDot: false, dotIsLive: false, hasMenu: false)
        case .idle:
            return RecordPill(label: "Record", time: nil,
                              help: "Start recording \u{00B7} class \(cls)",
                              spoken: "Start recording",
                              showsDot: true, dotIsLive: false, hasMenu: false, isButton: true)
        }
    }

    // MARK: Menus

    struct RecordActions {
        var start: () -> Void = {}
        /// Stops and saves the file. It ends nothing for anybody else, so it is
        /// not asked about (CoordinatorController.confirmAndStop says the same).
        var stop: () -> Void = {}
        var togglePause: () -> Void = {}
        var cancelCountdown: () -> Void = {}
    }

    /// The REC pill's menu, per state. An item that does not apply is absent,
    /// not greyed, as in the menu bar's menu.
    static func recordMenu(_ phase: MeetingBarRecordPhase, _ bindings: ShortcutBindings,
                           _ a: RecordActions) -> [MenuEntry] {
        func key(_ action: ShortcutAction) -> KeyCombo? { bindings.combo(for: .action(action)) }
        switch phase {
        case .idle:
            return [.item("Start Recording", shortcut: key(.toggleRecording), a.start)]
        case .countdown:
            return [.item("Cancel Countdown", shortcut: key(.toggleRecording), a.cancelCountdown)]
        case .saving:
            return [.item("Saving\u{2026}", enabled: false, {})]
        case .recording, .paused:
            return [
                .item(phase == .paused ? "Resume Recording" : "Pause Recording",
                      shortcut: key(.togglePause), a.togglePause),
                .separator,
                .item("Stop Recording", shortcut: key(.toggleRecording), a.stop),
            ]
        }
    }

    /// One icon cell: its glyph, hover help (with the key the person bound) and
    /// what VoiceOver says. `on` lights it with the brand tint.
    struct IconCell: Equatable {
        var symbol: String
        var help: String
        var spoken: String
        var on = false
    }

    /// Notes: lit while the notes bar is open.
    static func notesCell(open: Bool, _ bindings: ShortcutBindings) -> IconCell {
        IconCell(symbol: "note.text",
                 help: help(open ? "Hide Notes" : "Show Notes", .toggleNotes, bindings),
                 spoken: open ? "Hide notes" : "Show notes", on: open)
    }

    /// Meeting Views: opens the views submenu's entries as a menu of its own.
    static func viewsCell(_ bindings: ShortcutBindings) -> IconCell {
        IconCell(symbol: "square.grid.2x2", help: "Meeting Views", spoken: "Meeting views. Menu")
    }

    /// Collapse to the small round button. Not the arrows the Meeting button
    /// uses (they open the Meeting window): a ring in a ring, the puck itself.
    static func collapseCell(_ bindings: ShortcutBindings) -> IconCell {
        IconCell(symbol: "circle.circle",
                 help: help("Collapse to Small Button", .toggleMeetingBar, bindings),
                 spoken: "Collapse to the small button")
    }
}

// MARK: - Width

/// The bar's size, from its cells, so the panel and the content cannot disagree.
/// Left to right: grip, Meeting, | mic, camera, | REC pill and pause, | Share,
/// Draw, | chat, people, Notes, Views, Collapse, | End. Share opens the Present menu: what the
/// class sees, your look, the layout.
enum MeetingBarLayout {
    static let height: CGFloat = 44
    static let spacing: CGFloat = 2
    static let leadingPad: CGFloat = 4
    static let trailingPad: CGFloat = 8
    static let grip: CGFloat = 18
    /// The Meeting button and the chevron beside it, one cell, as wide as the
    /// button alone was: the bar stays under its 720pt cap.
    static let meeting: CGFloat = meetingButton + meetingMenu
    static let meetingButton: CGFloat = 78
    static let meetingMenu: CGFloat = 14
    static let icon: CGFloat = 32
    /// The REC pill, the same width in every state so the bar never jumps.
    static let recPill: CGFloat = 132
    static let pause: CGFloat = 28
    /// The pill and the pause slot beside it: one cell. Not recording, the pill
    /// takes the whole cell, so there is no hole where pause will be.
    static let recCell: CGFloat = recPill + pause
    /// Draw and Share are icon-only, the width of the mic and camera.
    static let draw: CGFloat = icon
    static let present: CGFloat = icon
    static let people: CGFloat = 46
    static let end: CGFloat = 52
    /// A hairline and 4pt each side.
    static let divider: CGFloat = 9

    /// Notes, Views (only beside the Meeting button, which is what makes views
    /// exist), Collapse: three icons where the \u{22EF} menu was. The Views slot
    /// follows `videoButtons`, so the panel's width has one switch, not two.
    static func cells(videoButtons: Bool) -> [CGFloat] {
        var out: [CGFloat] = [grip]
        if videoButtons { out.append(meeting) }
        out += [divider, icon, icon, divider, recCell, divider, present, draw, divider,
                icon, people, icon]
        if videoButtons { out.append(icon) }
        out += [icon, divider, end]
        return out
    }

    static func width(videoButtons: Bool) -> CGFloat {
        let cells = cells(videoButtons: videoButtons)
        return leadingPad + trailingPad + cells.reduce(0, +) + spacing * CGFloat(cells.count - 1)
    }

    // MARK: The record-only bar (RecordingChrome.swift)

    /// Grip-less: [dot REC 1:29] [pause] | [Share] [Draw] [Notes] | [Stop].
    static let recordOnlyPill: CGFloat = 116
    static let notes: CGFloat = 74
    static let recordOnlyStop: CGFloat = 56
    static var recordOnlyWidth: CGFloat {
        let cells: [CGFloat] = [recordOnlyPill, pause, divider, present, draw, notes, divider, recordOnlyStop]
        return 8 + 8 + cells.reduce(0, +) + spacing * CGFloat(cells.count - 1)
    }
}
