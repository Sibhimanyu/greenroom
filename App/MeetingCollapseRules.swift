//
//  MeetingCollapseRules.swift
//  Greenroom
//
//  The pure decisions behind the three sizes of a live meeting: the Meeting
//  window, the Mini window (a small floating picture of whoever is talking) and
//  the Control bar. Which size a click, the yellow light or Command-M goes to,
//  which size is remembered, and when a layout's neighbour takes the room. Also
//  the "Show on my share" rule: which of our own windows are let into a display
//  share. Foundation only, so the test target compiles this file as it is.
//
import Foundation

/// How much of the meeting is on screen.
enum MeetingSize: String, Equatable {
    case window, mini, bar
}

/// What the layout already shows, which changes where a collapse goes.
struct MeetingCollapseContext: Equatable {
    /// The layout places the Meeting piece at full size (not a whole display, not compact).
    var placedFull = false
    /// The layout places the Meeting piece compact: it is already Mini-sized.
    var meetingIsSlot = false
    /// A speaker view window (Active speaker, Multi-speaker, Speaker + strip,
    /// Spotlight student) is on screen: the faces are already there.
    var speakerViewOnScreen = false

    /// The Mini would only repeat what is on screen, so it is skipped.
    var skipsMini: Bool { meetingIsSlot || speakerViewOnScreen }
}

enum MeetingCollapse {
    enum Step: Equatable { case down, up }

    static let defaultsKey = "meetingCollapse.last"

    /// Where one step goes. Down: Meeting window, Mini, Control bar. Up is the
    /// way back: from the Mini always the window; from the bar the Mini first,
    /// unless Option is held or the Mini would be pointless here.
    /// `lastCollapsed` is the size a collapse from the window lands on (Mini or bar).
    static func next(from size: MeetingSize, step: Step, option: Bool = false,
                     lastCollapsed: MeetingSize, context: MeetingCollapseContext = MeetingCollapseContext()) -> MeetingSize {
        switch (size, step) {
        case (.window, .down):
            if context.skipsMini { return .bar }
            return lastCollapsed == .bar ? .bar : .mini
        case (.mini, .down), (.bar, .down):
            return .bar
        case (.window, .up), (.mini, .up):
            return .window
        case (.bar, .up):
            return option || context.skipsMini ? .window : .mini
        }
    }

    /// The size to remember after a move. Only a step down is a choice: a layout
    /// that forced the bar (no Mini there) or a step back up must not change what
    /// the teacher last picked.
    static func remembered(after step: Step, from: MeetingSize, to: MeetingSize,
                           context: MeetingCollapseContext, current: MeetingSize) -> MeetingSize {
        guard step == .down, to != .window else { return current }
        if from == .window, context.skipsMini { return current }
        return to
    }

    /// Whether the placed Meeting's room goes to its neighbour: the window has
    /// left its slot (to the Mini or the bar) and the layout placed it at full size.
    static func neighbourTakesRoom(going size: MeetingSize, context: MeetingCollapseContext) -> Bool {
        context.placedFull && !context.meetingIsSlot && size != .window
    }

    // MARK: Remembered across launches

    static func lastCollapsed(_ defaults: UserDefaults = .standard) -> MeetingSize {
        let size = MeetingSize(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .mini
        return size == .bar ? .bar : .mini
    }

    static func setLastCollapsed(_ size: MeetingSize, _ defaults: UserDefaults = .standard) {
        guard size != .window else { return }
        defaults.set(size.rawValue, forKey: defaultsKey)
    }
}

// MARK: - Show on my share

/// "Show on my share": a window of ours that is let into the picture of a
/// shared display. Greenroom leaves all its own windows out of a display
/// share; this is the one way to put one back.
enum ShowOnShare {
    /// What is being shared, as far as this rule cares.
    enum ShareKind: Equatable {
        case display, app, window
        /// A whiteboard, nothing, or no share: there is no display to be on.
        case other
    }

    static let label = "Show on my share"
    static let unavailableTip = "Works when you share a whole display"
    /// The small label on the amber border.
    static let borderLabel = "On your share"

    /// The windows to let through, as window numbers; nil when the switch cannot
    /// work (an app or window share captures only that app or window).
    static func exceptionIDs(kind: ShareKind, registry: Set<Int>) -> Set<Int>? {
        kind == .display ? registry : nil
    }

    static func isAvailable(_ kind: ShareKind) -> Bool { kind == .display }

    /// The switch's tooltip and accessibility help.
    static func help(kind: ShareKind, on: Bool) -> String {
        guard isAvailable(kind) else { return unavailableTip }
        return on ? "\(label): on. This window is in the picture others see."
                  : "\(label): off. Greenroom\u{2019}s windows stay out of the picture."
    }

    /// The border and its label draw only while the window is really going out.
    static func marksWindow(on: Bool, kind: ShareKind) -> Bool { on && isAvailable(kind) }
}
