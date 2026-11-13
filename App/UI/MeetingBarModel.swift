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
    /// "End Meeting for All" when hosting, "Leave Meeting" otherwise: what End does.
    var endName = "End Meeting for All"
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
        /// "REC", "Paused", "Not recording", "Starting\u{2026}", "Saving\u{2026}".
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
            return RecordPill(label: "Not recording", time: nil,
                              help: "Not recording \u{00B7} class \(cls). Open the menu to start.",
                              spoken: "Not recording. Menu",
                              showsDot: false, dotIsLive: false, hasMenu: true)
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

    struct MoreState: Equatable {
        var notesOpen = false
        /// Greenroom's own meeting UI is on and the views menu has entries.
        var hasViews = false
        var hasLayouts = false
    }

    struct MoreActions {
        var toggleNotes: () -> Void = {}
        var collapse: () -> Void = {}
    }

    /// The \u{22EF} menu: what the bar used to carry as icons of its own (notes, the
    /// Views menu, collapsing to the small round button) and the layout switch.
    /// `views` and `layouts` are the live submenus, built when it is opened.
    static func moreMenu(_ s: MoreState, views: [MenuEntry], layouts: [MenuEntry],
                         _ bindings: ShortcutBindings, _ a: MoreActions) -> [MenuEntry] {
        func key(_ action: ShortcutAction) -> KeyCombo? { bindings.combo(for: .action(action)) }
        var out: [MenuEntry] = [
            .item(s.notesOpen ? "Hide Notes" : "Show Notes", shortcut: key(.toggleNotes), a.toggleNotes),
        ]
        if s.hasViews { out.append(.submenu("Meeting Views", views)) }
        if s.hasLayouts { out.append(.submenu("Layout", layouts)) }
        out.append(.separator)
        out.append(.item("Collapse to Small Button", shortcut: key(.toggleMeetingBar), a.collapse))
        return out
    }
}

// MARK: - Width

/// The bar's size, from its cells, so the panel and the content cannot disagree.
/// Left to right: grip, Meeting, | mic, camera, | REC pill and pause, | Draw,
/// | chat, people, More, | End.
enum MeetingBarLayout {
    static let height: CGFloat = 44
    static let spacing: CGFloat = 2
    static let leadingPad: CGFloat = 4
    static let trailingPad: CGFloat = 8
    static let grip: CGFloat = 18
    static let meeting: CGFloat = 92
    static let icon: CGFloat = 32
    /// The REC pill, the same width in every state so the bar never jumps.
    static let recPill: CGFloat = 132
    static let pause: CGFloat = 28
    /// The pill and the pause slot beside it: one cell. Not recording, the pill
    /// takes the whole cell, so there is no hole where pause will be.
    static let recCell: CGFloat = recPill + pause
    static let draw: CGFloat = 70
    static let people: CGFloat = 46
    static let end: CGFloat = 52
    /// A hairline and 4pt each side.
    static let divider: CGFloat = 9

    static func cells(videoButtons: Bool) -> [CGFloat] {
        var out: [CGFloat] = [grip]
        if videoButtons { out.append(meeting) }
        out += [divider, icon, icon, divider, recCell, divider, draw, divider,
                icon, people, icon, divider, end]
        return out
    }

    static func width(videoButtons: Bool) -> CGFloat {
        let cells = cells(videoButtons: videoButtons)
        return leadingPad + trailingPad + cells.reduce(0, +) + spacing * CGFloat(cells.count - 1)
    }

    // MARK: The record-only bar (RecordingChrome.swift)

    /// Grip-less: [dot REC 1:29] [pause] | [Draw] | [Stop].
    static let recordOnlyPill: CGFloat = 116
    static let recordOnlyStop: CGFloat = 56
    static var recordOnlyWidth: CGFloat {
        let cells: [CGFloat] = [recordOnlyPill, pause, divider, draw, divider, recordOnlyStop]
        return 8 + 8 + cells.reduce(0, +) + spacing * CGFloat(cells.count - 1)
    }
}
