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

    // MARK: Sizes as decisions (docs/specs/meeting-surface.md R15 to R21)

    /// Which size the meeting is at now, from what is on screen. First match wins:
    /// a morph's heading; no open window (the Bar); live, the model's reopen target
    /// (a window that is only covered is still the Window); else hidden or not.
    static func sizeOnScreen(morphHeading: CGFloat?, windowOpen: Bool, live: Bool,
                             reopenIsWindow: Bool, windowHidden: Bool) -> MeetingSize {
        if let heading = morphHeading { return heading == 1 ? .window : .bar }
        guard windowOpen else { return .bar }
        if live { return reopenIsWindow ? .window : .bar }
        return windowHidden ? .bar : .window
    }

    /// What a move does; the coordinator carries it out.
    enum Move: Equatable { case stay, collapse, expand }

    /// Where the Bar cannot be built, the meeting stays as it is.
    static func plan(from: MeetingSize, wanted: MeetingSize, barInstalled: Bool) -> Move {
        let target = (wanted == .bar && !barInstalled) ? from : wanted
        guard target != from else { return .stay }
        switch (from, target) {
        case (.window, .bar): return .collapse
        case (.bar, .window): return .expand
        default: return .stay
        }
    }

    /// Going to the Bar is a step down; going to the Window, up.
    static func step(toward size: MeetingSize) -> Step { size == .bar ? .down : .up }

    enum ExpandPlan: Equatable { case turnRound, openWindow, step }

    /// The Bar's Meeting button. A morph under way is turned round; a Bar that shows
    /// only because the window is covered brings the window up; else one step up.
    static func expandPlan(morphing: Bool, size: MeetingSize) -> ExpandPlan {
        if morphing { return .turnRound }
        return size == .bar ? .step : .openWindow
    }

    enum ToggleAction: Equatable { case expandFromBar, shrinkToBar, collapse }

    /// The shortcut and the one click. During a morph, the other way round (any
    /// heading but 0 shrinks); else the window goes down and the Bar comes up.
    static func togglePlan(morphHeading: CGFloat?, size: MeetingSize) -> ToggleAction {
        if let heading = morphHeading { return heading == 0 ? .expandFromBar : .shrinkToBar }
        return size == .window ? .collapse : .expandFromBar
    }

    /// `neighbourTakesRoom`, and the session arranges windows.
    static func neighbourMoves(going size: MeetingSize, context: MeetingCollapseContext, arranged: Bool) -> Bool {
        neighbourTakesRoom(going: size, context: context) && arranged
    }

    /// The close button by the person: a placed Meeting counts as hidden, so the
    /// neighbour grows into the room, unless a view window still shows the meeting.
    static func closeHandsRoomToNeighbour(arranged: Bool, inMeeting: Bool, placesMeeting: Bool,
                                          viewWindowsOpen: Bool) -> Bool {
        arranged && inMeeting && placesMeeting && !viewWindowsOpen
    }

    /// Whether a Dock click, Show Greenroom or the menu bar's live header finds the
    /// meeting shrunk. Ignores morphs and whether a window is open.
    static func shrunkForReopen(live: Bool, reopenIsBar: Bool, windowHidden: Bool) -> Bool {
        live ? reopenIsBar : windowHidden
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

/// What the content views a layout places draw (owner, 2026-11-17). The main
/// Meeting window always carries its own controls; which surface is up is
/// `MeetingSurface`'s call (App/Meeting/MeetingSurface.swift). With a layout the
/// content views (Active speaker, gallery, Chat...) show content only, the
/// controls being on the window or the bar; without one the views keep theirs.
struct MeetingSurfacePlan: Equatable {
    var viewsChrome: MeetingSurfaceChrome

    static func decide(layoutActive: Bool) -> MeetingSurfacePlan {
        MeetingSurfacePlan(viewsChrome: layoutActive ? .contentOnly : .full)
    }
}

// MARK: - One control surface at a time

/// Small rules around the two surfaces. Which one shows, and the "exactly one,
/// never none" rule, are `MeetingSurface` (App/Meeting/MeetingSurface.swift).
enum MeetingSurfaces {
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

    /// The windows to let through, as window numbers; nil when the switch cannot
    /// work (an app or window share captures only that app or window).
    /// `alwaysShared`: windows that are in the picture with no switch (the
    /// Greenroom Browser, ShareVisibilityRules.alwaysShared).
    /// Derived from `Visibility.windowBadge`, the one rule the canvas badges read too.
    static func exceptionIDs(kind: ShareKind, registry: Set<Int>, alwaysShared: Set<Int> = []) -> Set<Int>? {
        guard kind == .display else { return nil }
        // `registry` is the windows already marked on (the owner's per-window choice, which the
        // rule answers with `marked`); the always-shared ones come from the rule.
        let always = Visibility.windowBadge(.browser, marked: false, target: .wholeScreen).isOn ? alwaysShared : []
        return registry.union(always)
    }

    static func isAvailable(_ kind: ShareKind) -> Bool { kind == .display }

    /// The switch's tooltip and accessibility help.
    static func help(kind: ShareKind, on: Bool) -> String {
        guard isAvailable(kind) else { return unavailableTip }
        return on ? "\(ShareVisibility.classSees.label): this window is in the picture others see."
                  : "\(ShareVisibility.onlyYou.label): Greenroom\u{2019}s windows stay out of the picture."
    }

    /// Whether the window is really going out on the share.
    static func marksWindow(on: Bool, kind: ShareKind) -> Bool { on && isAvailable(kind) }
}
