//
//  MeetingCollapseRules.swift
//  Greenroom
//
//  The pure decisions behind the two sizes of a live meeting: the Meeting
//  window and the Control bar. Which size a click, the yellow light or
//  Command-M goes to, and when a layout's neighbour takes the room. Also
//  the "Show on my share" rule: which of our own windows are let into a display
//  share. Foundation only, so the test target compiles this file as it is.
//
import Foundation

/// How much of the meeting is on screen.
enum MeetingSize: String, Equatable {
    case window, bar
}

/// What the layout already shows, which changes where a collapse goes.
struct MeetingCollapseContext: Equatable {
    /// The layout places the Meeting piece at full size (not a whole display, not compact).
    var placedFull = false
    /// The layout places the Meeting piece compact: it is already small.
    var meetingIsSlot = false
}

enum MeetingCollapse {
    enum Step: Equatable { case down, up }

    /// Where one step goes. Down: the Control bar. Up: the Meeting window.
    static func next(from size: MeetingSize, step: Step) -> MeetingSize {
        switch (size, step) {
        case (_, .down): return .bar
        case (_, .up): return .window
        }
    }

    /// Whether the placed Meeting's room goes to its neighbour: the window has
    /// left its slot (to the bar) and the layout placed it at full size.
    static func neighbourTakesRoom(going size: MeetingSize, context: MeetingCollapseContext) -> Bool {
        context.placedFull && !context.meetingIsSlot && size != .window
    }
}

// MARK: - What a meeting surface draws besides its content

/// A meeting surface either carries its own controls or shows its content and
/// nothing else.
enum MeetingSurfaceChrome: Equatable {
    case full
    case contentOnly
    var showsControls: Bool { self == .full }
}

/// Who carries the controls (owner, 2026-11-17). The main Meeting window is the
/// control surface: while it is shown it keeps its controls and the Control bar
/// stays hidden. In every other case the bar is up and holds all the controls,
/// and the content views a layout places (Active speaker, gallery, Chat...) show
/// content only. Without a layout the views keep theirs: today's window <-> bar.
struct MeetingSurfacePlan: Equatable {
    var barVisible: Bool
    var mainWindowChrome: MeetingSurfaceChrome
    var viewsChrome: MeetingSurfaceChrome

    /// `layoutHasMainWindow`: the layout has a Meeting window piece. A window
    /// that piece placed but that is collapsed or covered is not shown, so the
    /// bar is up for it: no way to reach a control may depend on a hidden window.
    static func decide(layoutActive: Bool, layoutHasMainWindow: Bool, mainWindowShown: Bool) -> MeetingSurfacePlan {
        MeetingSurfacePlan(barVisible: !mainWindowShown,
                           mainWindowChrome: .full,
                           viewsChrome: layoutActive ? .contentOnly : .full)
    }
}

// MARK: - One control surface at a time

/// While a meeting is live exactly one of the Meeting window and the Control
/// bar is on screen, and every way back lands on one that exists.
enum MeetingSurfaces {
    /// The small windows that follow the bar (the chat and People pop-outs):
    /// left on another desktop, they are taken off it first, so they come in
    /// on the desktop being looked at.
    static func comesHereFirst(visible: Bool, onActiveSpace: Bool) -> Bool {
        visible && !onActiveSpace
    }

    /// The Meeting window is up on another desktop: open there, not shrunk or
    /// minimised. Then Expand, Chat, People and the island's waiting notice bring
    /// it to the desktop the teacher is on, full-screen apps included, without
    /// switching desktops (owner, 2026-11-16: "They should open where I am").
    static func meetingWindowElsewhere(visible: Bool, miniaturized: Bool, onActiveSpace: Bool) -> Bool {
        visible && !miniaturized && !onActiveSpace
    }

    /// The chat lives in one place at a time. The pop-out is for while the bar
    /// carries the controls; once the Meeting window is in view again it folds
    /// into the window's Chat panel. A layout's chat is a placed piece of its
    /// own and is left alone.
    static func foldsPopOutChat(windowShowing: Bool, popOutOpen: Bool, arranged: Bool) -> Bool {
        windowShowing && popOutOpen && !arranged
    }

    /// The bar is the one that fills in: it shows only when the window is not up.
    static func barVisible(windowShowing: Bool) -> Bool {
        !windowShowing
    }

    /// How many control surfaces are on screen. `barExists` is whether the bar
    /// has been installed for this meeting.
    static func visibleCount(windowShowing: Bool, barExists: Bool) -> Int {
        (windowShowing ? 1 : 0) + (barExists && barVisible(windowShowing: windowShowing) ? 1 : 0)
    }

    /// The invariant: one, never none and never two.
    static func isSound(windowShowing: Bool, barExists: Bool) -> Bool {
        visibleCount(windowShowing: windowShowing, barExists: barExists) == 1
    }

    /// Where a Dock click, a menu choice or the status tracker lands: the first
    /// of window, bar that exists. Nil only with nothing built at all.
    static func wayBack(windowExists: Bool, barExists: Bool) -> MeetingSize? {
        if windowExists { return .window }
        if barExists { return .bar }
        return nil
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
    /// The small label on the amber edge: the same words as the switch.
    static let borderLabel = ShareVisibility.classSees.label

    /// The windows to let through, as window numbers; nil when the switch cannot
    /// work (an app or window share captures only that app or window).
    static func exceptionIDs(kind: ShareKind, registry: Set<Int>) -> Set<Int>? {
        kind == .display ? registry : nil
    }

    static func isAvailable(_ kind: ShareKind) -> Bool { kind == .display }

    /// The switch's tooltip and accessibility help.
    static func help(kind: ShareKind, on: Bool) -> String {
        guard isAvailable(kind) else { return unavailableTip }
        return on ? "\(ShareVisibility.classSees.label): this window is in the picture others see."
                  : "\(ShareVisibility.onlyYou.label): Greenroom\u{2019}s windows stay out of the picture."
    }

    /// The border and its label draw only while the window is really going out.
    static func marksWindow(on: Bool, kind: ShareKind) -> Bool { on && isAvailable(kind) }
}
