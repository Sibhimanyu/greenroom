//
//  ShortcutModel.swift
//  Greenroom
//
//  The pure half of Settings -> Shortcuts: which actions exist, what keys they
//  default to, how a binding is saved, which combinations are refused and how a
//  combination is written. No AppKit and no coordinator, so the test target
//  compiles this file as it is.
//
//  Everything stateful (the store, the Carbon registration, the recorder view)
//  is in ShortcutStore.swift, ShortcutRuntime.swift and ShortcutsSettingsTab.swift
//  and reads from here, so the menu bar, Settings and the registration can
//  never disagree about what a key does.
//
import Foundation
import Carbon.HIToolbox

// MARK: - A key combination

/// A key plus modifiers. Modifiers are Carbon's mask (cmdKey | optionKey |
/// controlKey | shiftKey), which is what RegisterEventHotKey takes.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let command = UInt32(cmdKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)
    static let shift = UInt32(shiftKey)
    private static let mask = command | option | control | shift

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.mask
    }

    /// Option + Command + a key: the family every default uses.
    static func optionCommand(_ keyCode: Int) -> KeyCombo {
        KeyCombo(keyCode: UInt32(keyCode), modifiers: command | option)
    }

    /// NSEvent.ModifierFlags.rawValue to Carbon's mask, without importing AppKit
    /// (shift 1<<17, control 1<<18, option 1<<19, command 1<<20).
    static func carbonModifiers(cocoaFlags raw: UInt) -> UInt32 {
        var m: UInt32 = 0
        if raw & (1 << 17) != 0 { m |= shift }
        if raw & (1 << 18) != 0 { m |= control }
        if raw & (1 << 19) != 0 { m |= option }
        if raw & (1 << 20) != 0 { m |= command }
        return m
    }

    /// At least one of Command, Control or Option. Shift alone, or nothing, is a
    /// key anyone types by accident, and a global hotkey would swallow it.
    var hasChordModifier: Bool { modifiers & (Self.command | Self.control | Self.option) != 0 }

    // MARK: Writing it

    /// The modifiers in the order macOS menus write them: \u{2303}\u{2325}\u{21E7}\u{2318}.
    var modifierGlyphs: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "\u{2303}" }
        if modifiers & Self.option != 0 { s += "\u{2325}" }
        if modifiers & Self.shift != 0 { s += "\u{21E7}" }
        if modifiers & Self.command != 0 { s += "\u{2318}" }
        return s
    }

    /// "\u{2325}\u{2318}G".
    var glyphs: String { modifierGlyphs + Self.keyName(keyCode) }

    /// For VoiceOver: "Option Command G". Control, Option, Shift, Command.
    var spokenName: String {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("Control") }
        if modifiers & Self.option != 0 { parts.append("Option") }
        if modifiers & Self.shift != 0 { parts.append("Shift") }
        if modifiers & Self.command != 0 { parts.append("Command") }
        parts.append(Self.spokenKeyName(keyCode))
        return parts.joined(separator: " ")
    }

    // MARK: Key names (US ANSI layout; key codes are positions, not letters)

    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "\u{21A9}", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "\u{21E5}", 49: "Space", 50: "`",
        51: "\u{232B}", 53: "\u{238B}", 114: "Help", 115: "\u{2196}", 116: "\u{21DE}",
        117: "\u{2326}", 119: "\u{2198}", 121: "\u{21DF}",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5",
        88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9",
    ]

    private static let spoken: [UInt32: String] = [
        24: "Equals", 27: "Minus", 30: "Right Bracket", 33: "Left Bracket", 39: "Quote",
        41: "Semicolon", 42: "Backslash", 43: "Comma", 44: "Slash", 47: "Period", 50: "Grave",
        36: "Return", 48: "Tab", 51: "Delete", 53: "Escape", 117: "Forward Delete",
        115: "Home", 116: "Page Up", 119: "End", 121: "Page Down",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
    ]

    static func keyName(_ keyCode: UInt32) -> String { names[keyCode] ?? "Key \(keyCode)" }
    static func spokenKeyName(_ keyCode: UInt32) -> String { spoken[keyCode] ?? keyName(keyCode) }

    /// What a menu item needs to show this key: one character, or a named key
    /// ("space", "return", "tab", "escape", "left", "right", "up", "down").
    /// nil when a menu cannot draw it (function keys, keypad, Home...).
    var menuKey: String? {
        switch keyCode {
        case 49: return "space"
        case 36: return "return"
        case 48: return "tab"
        case 53: return "escape"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            guard let name = Self.names[keyCode], name.count == 1, name.unicodeScalars.first!.isASCII else { return nil }
            return name.lowercased()
        }
    }
}

// MARK: - Refused combinations

/// Combinations that cannot be bound, because the system or every app owns them.
/// A global hotkey is swallowed before the focused app sees it, so binding
/// Command-C would break copy everywhere.
enum ReservedShortcuts {

    private struct Entry { let keyCode: Int; let modifiers: UInt32; let reason: String }

    private static let cmd = KeyCombo.command, opt = KeyCombo.option, shift = KeyCombo.shift

    private static let entries: [Entry] = [
        Entry(keyCode: kVK_ANSI_Q, modifiers: cmd, reason: "\u{2318}Q quits the frontmost app."),
        Entry(keyCode: kVK_ANSI_W, modifiers: cmd, reason: "\u{2318}W closes the frontmost window."),
        Entry(keyCode: kVK_Tab, modifiers: cmd, reason: "\u{2318}Tab switches apps."),
        Entry(keyCode: kVK_Tab, modifiers: cmd | shift, reason: "\u{21E7}\u{2318}Tab switches apps."),
        Entry(keyCode: kVK_Space, modifiers: cmd, reason: "\u{2318}Space opens Spotlight."),
        Entry(keyCode: kVK_Escape, modifiers: cmd | opt, reason: "\u{2325}\u{2318}Esc opens Force Quit."),
        Entry(keyCode: kVK_ANSI_D, modifiers: cmd | opt, reason: "\u{2325}\u{2318}D shows or hides the Dock."),
        Entry(keyCode: kVK_ANSI_H, modifiers: cmd | opt, reason: "\u{2325}\u{2318}H hides every other app."),
        Entry(keyCode: kVK_ANSI_H, modifiers: cmd, reason: "\u{2318}H hides the frontmost app."),
        Entry(keyCode: kVK_ANSI_M, modifiers: cmd, reason: "\u{2318}M minimises the frontmost window."),
        Entry(keyCode: kVK_ANSI_M, modifiers: cmd | opt, reason: "\u{2325}\u{2318}M minimises every window of the app."),
        Entry(keyCode: kVK_ANSI_Grave, modifiers: cmd, reason: "\u{2318}` switches windows within an app."),
        Entry(keyCode: kVK_ANSI_Comma, modifiers: cmd, reason: "\u{2318}, opens an app's settings."),
        // The editing commands every app answers to.
        Entry(keyCode: kVK_ANSI_C, modifiers: cmd, reason: "\u{2318}C is Copy in every app."),
        Entry(keyCode: kVK_ANSI_V, modifiers: cmd, reason: "\u{2318}V is Paste in every app."),
        Entry(keyCode: kVK_ANSI_X, modifiers: cmd, reason: "\u{2318}X is Cut in every app."),
        Entry(keyCode: kVK_ANSI_A, modifiers: cmd, reason: "\u{2318}A is Select All in every app."),
        Entry(keyCode: kVK_ANSI_Z, modifiers: cmd, reason: "\u{2318}Z is Undo in every app."),
        Entry(keyCode: kVK_ANSI_Z, modifiers: cmd | shift, reason: "\u{21E7}\u{2318}Z is Redo in every app."),
        Entry(keyCode: kVK_ANSI_S, modifiers: cmd, reason: "\u{2318}S is Save in every app."),
        // Greenroom's own View menu command, which a global hotkey would swallow.
        Entry(keyCode: kVK_ANSI_B, modifiers: cmd, reason: "\u{2318}B shows and hides Greenroom's Sessions sidebar."),
    ]

    /// Why this combination cannot be used, or nil when it is free to bind.
    static func reason(for combo: KeyCombo) -> String? {
        entries.first { UInt32($0.keyCode) == combo.keyCode && $0.modifiers == combo.modifiers }?.reason
    }
}

// MARK: - The recorder's decision

/// What one key press means to a shortcut recorder. Pure, so the rules are
/// tested without a window.
enum ShortcutCapture {
    enum Outcome: Equatable {
        /// Esc: stop recording, change nothing.
        case cancel
        /// Delete: the shortcut becomes None.
        case clear
        /// Refused, with the sentence that says why. Recording carries on.
        case reject(String)
        case accept(KeyCombo)
    }

    static func interpret(keyCode: UInt32, carbonModifiers: UInt32) -> Outcome {
        let combo = KeyCombo(keyCode: keyCode, modifiers: carbonModifiers)
        if combo.modifiers == 0 {
            if keyCode == UInt32(kVK_Escape) { return .cancel }
            if keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete) { return .clear }
        }
        guard combo.hasChordModifier else {
            return .reject("Hold \u{2318}, \u{2303} or \u{2325} with the key, so it is never typed by accident.")
        }
        if let reason = ReservedShortcuts.reason(for: combo) {
            return .reject("\(reason) Greenroom can't take it. Try another.")
        }
        return .accept(combo)
    }
}

// MARK: - Actions

enum ShortcutScope: String {
    /// Registered with the system: works while another app is in front.
    case global
    /// Only while Greenroom is the active app.
    case appOnly
    /// Only while Greenroom's meeting window is the key window. Never registered
    /// with the system, so it cannot take the key from any other app (or from the
    /// system's own use of it, as Command-M is for minimise).
    case meetingWindow
}

enum ShortcutGroup: String, CaseIterable {
    case classGroup, meeting, layout, greenroom

    var title: String {
        switch self {
        case .classGroup: return "Class"
        case .meeting: return "Meeting"
        case .layout: return "Layout"
        case .greenroom: return "Greenroom"
        }
    }
}

/// The fixed actions. Raw values are the ids saved in `shortcuts.bindings`, so
/// they never change.
enum ShortcutAction: String, CaseIterable {
    case startClass = "start"
    case endSession = "end"
    case toggleRecording = "record"
    case togglePause = "pause"
    case toggleDrawing = "draw"
    case clip1 = "clip1"
    case clip2 = "clip2"
    case clip5 = "clip5"
    case toggleMic = "mic"
    case toggleCamera = "camera"
    case toggleChat = "chat"
    case toggleNotes = "notes"
    case showMeetingWindow = "meetingWindow"
    case toggleMeetingBar = "meetingBar"
    case shrinkMeeting = "meetingShrink"
    case shrinkToBar = "meetingShrinkToBar"
    case cycleMeetingView = "galleryOrSpeaker"   // raw value kept: saved bindings
    case toggleMeeting = "hideMeeting"
    case snapBack = "snap"
    case openGreenroom = "openGreenroom"
    case openSessions = "openSessions"
    // One per meeting view window: open it, or close it if it is open. Unbound.
    case viewActiveSpeaker = "view.activeSpeaker"
    case viewGallery = "view.gallery"
    case viewMultiSpeaker = "view.multiSpeaker"
    case viewSpeakerStrip = "view.speakerStrip"
    case viewSelfView = "view.selfView"
    case viewPeople = "view.people"
    case viewSharedScreen = "view.sharedScreen"
    case viewSpotlight = "view.spotlight"
    case viewHandsUp = "view.handsUp"

    /// The view this action opens or closes, for the nine view actions.
    var meetingView: MeetingView? {
        guard rawValue.hasPrefix("view.") else { return nil }
        return MeetingView(rawValue: String(rawValue.dropFirst("view.".count)))
    }

    var group: ShortcutGroup {
        if meetingView != nil { return .meeting }
        switch self {
        case .startClass, .endSession, .toggleRecording, .togglePause, .toggleDrawing, .clip1, .clip2, .clip5: return .classGroup
        case .toggleMic, .toggleCamera, .toggleChat, .toggleNotes, .showMeetingWindow,
             .toggleMeetingBar, .shrinkMeeting, .shrinkToBar, .cycleMeetingView, .toggleMeeting: return .meeting
        case .snapBack: return .layout
        case .openGreenroom, .openSessions: return .greenroom
        default: return .meeting
        }
    }

    var title: String {
        if let view = meetingView { return "Open or close \(view.title)" }
        switch self {
        case .startClass: return "Start class"
        case .endSession: return "End session"
        case .toggleRecording: return "Start or stop recording"
        case .togglePause: return "Pause or resume recording"
        case .toggleDrawing: return "Draw on the screen"
        case .clip1: return "Clip the last minute"
        case .clip2: return "Clip the last 2 minutes"
        case .clip5: return "Clip the last 5 minutes"
        case .toggleMic: return "Mute or unmute microphone"
        case .toggleCamera: return "Camera on or off"
        case .toggleChat: return "Show or hide chat"
        case .toggleNotes: return "Show or hide notes"
        case .showMeetingWindow: return "Show the meeting window"
        case .toggleMeetingBar: return "Collapse or expand the meeting bar"
        case .shrinkMeeting: return "Shrink or expand the meeting"
        case .shrinkToBar: return "Shrink meeting to control bar"
        case .cycleMeetingView: return "Cycle meeting view"
        case .toggleMeeting: return "Hide or show the meeting"
        case .snapBack: return "Snap windows back to the layout"
        case .openGreenroom: return "Open Greenroom"
        case .openSessions: return "Open Sessions"
        default: return ""
        }
    }

    var detail: String {
        if let view = meetingView { return "\(view.blurb): a window of its own. Needs Greenroom\u{2019}s meeting UI." }
        switch self {
        case .startClass: return "Same as the Start button."
        case .endSession: return "Asks before it ends the class."
        case .toggleRecording: return "While a class is live or Record is ready."
        case .togglePause: return "Pauses the recording file only. The meeting carries on, and the file picks up with no gap."
        case .toggleDrawing: return "Opens the drawing tools over the screen you share, or closes them. Marks show in the meeting and the recording."
        case .clip1: return "Marks the moment that just happened, one minute back."
        case .clip2: return "Marks the moment that just happened, two minutes back."
        case .clip5: return "Marks the moment that just happened, five minutes back."
        case .toggleMic: return "Your microphone in the meeting."
        case .toggleCamera: return "Your camera in the meeting."
        case .toggleChat: return "Opens or closes the class chat."
        case .toggleNotes: return "The notes bar, for this session only."
        case .showMeetingWindow: return "Brings the meeting back without moving your slides."
        case .toggleMeetingBar: return "The floating controls: the full bar, or a small round button."
        case .shrinkMeeting: return "Morphs the meeting window into the floating control bar, and back."
        case .shrinkToBar: return "In the meeting window: shrinks it into the floating control bar, the same as its minimise button."
        case .cycleMeetingView: return "In the meeting window: Speaker, Gallery, Multi-speaker, and round again."
        case .toggleMeeting: return "The layout's meeting piece; its neighbour takes the room."
        case .snapBack: return "After you have dragged windows around."
        case .openGreenroom: return "Brings the main window forward."
        case .openSessions: return "Past classes and recordings."
        default: return ""
        }
    }

    var symbol: String {
        if let view = meetingView { return view.symbol }
        switch self {
        case .startClass: return "play.fill"
        case .endSession: return "stop.fill"
        case .toggleRecording: return "record.circle"
        case .togglePause: return "pause.circle"
        case .toggleDrawing: return "pencil.tip.crop.circle"
        case .clip1, .clip2, .clip5: return "scissors"
        case .toggleMic: return "mic.fill"
        case .toggleCamera: return "video.fill"
        case .toggleChat: return "bubble.left.fill"
        case .toggleNotes: return "note.text"
        case .showMeetingWindow: return "macwindow"
        case .toggleMeetingBar: return "arrow.down.right.and.arrow.up.left"
        case .shrinkMeeting, .shrinkToBar: return "rectangle.bottomhalf.inset.filled"
        case .cycleMeetingView: return "square.grid.2x2"
        case .toggleMeeting: return "eye.slash"
        case .snapBack: return "arrow.uturn.backward"
        case .openGreenroom: return "house.fill"
        case .openSessions: return "rectangle.stack.fill"
        default: return "macwindow"
        }
    }

    /// Every action here is system-wide: the point of each is that it works
    /// while the class, not Greenroom, is in front. (`.appOnly` is kept for an
    /// action that should only answer inside Greenroom; there is none today.)
    var scope: ShortcutScope { self == .shrinkToBar ? .meetingWindow : .global }

    /// Option + Command, not Control + Option + Command.
    ///
    /// Three modifiers was chosen for collision safety and is genuinely hard to
    /// hit one-handed. Option and Command are adjacent at the bottom left, so one
    /// thumb covers both. Control is the one dropped, deliberately: Control +
    /// Option is VoiceOver's own modifier, so those combinations are swallowed
    /// whenever VoiceOver is running. Option + Command has no such owner, and
    /// none of the letters used here collide with the system's Option + Command
    /// shortcuts (H Hide Others, D Dock, M Minimise All, Space Spotlight in
    /// Finder, Escape Force Quit - all refused by `ReservedShortcuts`).
    ///
    /// The clip digits ARE the minutes. Digits rather than letters because the
    /// mapping is the mnemonic, and Option + Command digits are unclaimed.
    ///
    /// The new actions ship unbound: a default is only worth taking when it is
    /// clearly safe, and none of them is clearly safe to guess.
    var defaultCombo: KeyCombo? {
        if meetingView != nil { return nil }
        switch self {
        case .startClass: return .optionCommand(kVK_ANSI_G)
        case .endSession: return .optionCommand(kVK_ANSI_X)
        case .toggleRecording: return .optionCommand(kVK_ANSI_R)
        // Recorditor's own Pause key. Free here: no other default uses Shift.
        case .togglePause: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: KeyCombo.option | KeyCombo.shift)
        // Draw: Option-Shift-D. Free (Pause is the only other Shift default),
        // and not a system shortcut.
        case .toggleDrawing: return KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: KeyCombo.option | KeyCombo.shift)
        case .snapBack: return .optionCommand(kVK_ANSI_S)
        // The yellow traffic light's key, in the meeting window only (scope
        // .meetingWindow): no global hotkey, so no other app loses Command-M.
        case .shrinkToBar: return KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: KeyCombo.command)
        case .toggleMeeting: return .optionCommand(kVK_ANSI_Z)
        case .clip1: return .optionCommand(kVK_ANSI_1)
        case .clip2: return .optionCommand(kVK_ANSI_2)
        case .clip5: return .optionCommand(kVK_ANSI_5)
        case .toggleMic, .toggleCamera, .toggleChat, .toggleNotes, .showMeetingWindow,
             .toggleMeetingBar, .shrinkMeeting, .cycleMeetingView, .openGreenroom, .openSessions: return nil
        default: return nil
        }
    }
}

/// A layout in the library, as far as shortcuts care.
struct ShortcutLayoutRef: Equatable {
    var id: UUID
    var name: String
}

/// One row of the Shortcuts page: a fixed action, or "Use layout: <name>".
/// `layout(nil)` is None. Layout bindings key off the template id, so renaming
/// a layout keeps its shortcut and deleting one drops it.
enum ShortcutSlot: Hashable {
    case action(ShortcutAction)
    case layout(UUID?)

    var id: String {
        switch self {
        case .action(let a): return a.rawValue
        case .layout(nil): return "layout:none"
        case .layout(let u?): return "layout:\(u.uuidString)"
        }
    }

    init?(id: String) {
        if id == "layout:none" { self = .layout(nil); return }
        if id.hasPrefix("layout:") {
            guard let u = UUID(uuidString: String(id.dropFirst("layout:".count))) else { return nil }
            self = .layout(u)
            return
        }
        guard let a = ShortcutAction(rawValue: id) else { return nil }
        self = .action(a)
    }

    var defaultCombo: KeyCombo? {
        if case .action(let a) = self { return a.defaultCombo }
        return nil
    }

    var scope: ShortcutScope {
        if case .action(let a) = self { return a.scope }
        return .global
    }

    var group: ShortcutGroup {
        if case .action(let a) = self { return a.group }
        return .layout
    }

    var symbol: String {
        if case .action(let a) = self { return a.symbol }
        return "rectangle.split.2x1"
    }

    func title(layouts: [ShortcutLayoutRef]) -> String {
        switch self {
        case .action(let a): return a.title
        case .layout(nil): return "Use layout: None"
        case .layout(let u?):
            return "Use layout: " + (layouts.first { $0.id == u }?.name ?? "Unknown")
        }
    }

    var detail: String {
        switch self {
        case .action(let a): return a.detail
        case .layout(nil): return "Arranges nothing at the next Start."
        case .layout: return "Sets the Start layout, or re-arranges a live class."
        }
    }
}

enum ShortcutCatalog {
    /// Every row, in page order: the fixed actions, then "Use layout" for None
    /// and for each template that exists now.
    static func slots(layouts: [ShortcutLayoutRef]) -> [ShortcutSlot] {
        var all = ShortcutAction.allCases.map(ShortcutSlot.action)
        all.append(.layout(nil))
        all.append(contentsOf: layouts.map { ShortcutSlot.layout($0.id) })
        return all
    }

    /// The page's sections, in order, empty ones left out. Within the Layout
    /// group Snap comes first, then the layout rows.
    static func grouped(layouts: [ShortcutLayoutRef]) -> [(group: ShortcutGroup, slots: [ShortcutSlot])] {
        let all = slots(layouts: layouts)
        return ShortcutGroup.allCases.compactMap { group in
            let rows = all.filter { $0.group == group }
            return rows.isEmpty ? nil : (group, rows)
        }
    }
}

// MARK: - Bindings

/// What the user has changed from the defaults, saved as JSON. A slot with no
/// entry uses its default; an entry is either a combination or an explicit
/// "cleared" (None), which is how a default is switched off.
struct ShortcutBindings: Equatable, Codable {

    enum Entry: Equatable, Codable {
        case combo(KeyCombo)
        case cleared

        private enum Keys: String, CodingKey { case keyCode, modifiers, cleared }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if (try c.decodeIfPresent(Bool.self, forKey: .cleared)) == true {
                self = .cleared
            } else {
                self = .combo(KeyCombo(keyCode: try c.decode(UInt32.self, forKey: .keyCode),
                                       modifiers: try c.decode(UInt32.self, forKey: .modifiers)))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .cleared: try c.encode(true, forKey: .cleared)
            case .combo(let k):
                try c.encode(k.keyCode, forKey: .keyCode)
                try c.encode(k.modifiers, forKey: .modifiers)
            }
        }
    }

    private(set) var entries: [String: Entry] = [:]
    var version = 1

    init() {}

    private enum CodingKeys: String, CodingKey { case version, entries }
    private struct Lossy: Decodable {
        let value: Entry?
        init(from decoder: Decoder) throws { value = try? Entry(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        let raw = (try? c.decodeIfPresent([String: Lossy].self, forKey: .entries)) ?? [:]
        // A damaged entry means that one row falls back to its default.
        entries = raw.compactMapValues(\.value)
    }

    // MARK: Reading

    func combo(for slot: ShortcutSlot) -> KeyCombo? {
        switch entries[slot.id] {
        case .combo(let k)?: return k
        case .cleared?: return nil
        case nil: return slot.defaultCombo
        }
    }

    /// Differs from what the slot ships with.
    func isCustomised(_ slot: ShortcutSlot) -> Bool { entries[slot.id] != nil }

    /// The first slot (in `slots` order) other than `slot` that already uses
    /// `combo`. This is the duplicate check, inside Greenroom.
    func conflict(for combo: KeyCombo, besides slot: ShortcutSlot, among slots: [ShortcutSlot]) -> ShortcutSlot? {
        slots.first { $0 != slot && self.combo(for: $0) == combo }
    }

    /// What to register: every slot that has a combination, in order. When two
    /// slots share one (an import, say) the first keeps it and the later one is
    /// left out, so registration never double-claims a key.
    func resolved(among slots: [ShortcutSlot]) -> [(slot: ShortcutSlot, combo: KeyCombo)] {
        var seen = Set<KeyCombo>()
        var out: [(ShortcutSlot, KeyCombo)] = []
        for slot in slots {
            guard let combo = combo(for: slot), seen.insert(combo).inserted else { continue }
            out.append((slot, combo))
        }
        return out
    }

    // MARK: Editing

    mutating func set(_ combo: KeyCombo, for slot: ShortcutSlot) {
        // Setting the default is no change at all, so it is not stored.
        entries[slot.id] = combo == slot.defaultCombo ? nil : .combo(combo)
    }

    /// None. A slot that ships unbound has nothing to switch off.
    mutating func clear(_ slot: ShortcutSlot) {
        entries[slot.id] = slot.defaultCombo == nil ? nil : .cleared
    }

    mutating func reset(_ slot: ShortcutSlot) { entries[slot.id] = nil }

    mutating func resetAll() { entries = [:] }

    /// Drops "Use layout" bindings whose template is gone.
    func pruned(keepingTemplates ids: Set<UUID>) -> ShortcutBindings {
        var copy = self
        for key in entries.keys {
            if case .layout(let u?)? = ShortcutSlot(id: key), !ids.contains(u) { copy.entries[key] = nil }
        }
        return copy
    }

    // MARK: Saving

    func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    static func from(jsonData data: Data) -> ShortcutBindings? {
        try? JSONDecoder().decode(ShortcutBindings.self, from: data)
    }
}
