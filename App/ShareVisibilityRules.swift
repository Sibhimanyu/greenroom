//
//  ShareVisibilityRules.swift
//  Greenroom
//
//  The plain words behind "Show on my share". Windows a layout places are in the
//  picture the meeting sees by default; the rest of Greenroom's windows are hidden
//  from it. Which window is marked is ShowOnShare.marksWindow; this file says
//  what to call each state. (The amber edge and the one-time island explanation
//  were removed on 2026-11-25, owner's decision.) Foundation only, so the test
//  target compiles this file as it is.
//
import Foundation

/// The look of a window's background. The rule: a window only you see is
/// frosted (its background is see-through, its content stays opaque); a window
/// the meeting sees is solid.
enum WindowBackdrop: Equatable {
    case frosted, solid

    /// How long the change between the two takes; none with Reduce Motion.
    static func transitionDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0 : 0.2 }
}

/// What the meeting gets of one of our windows.
enum ShareVisibility: Equatable {
    case classSees, onlyYou

    init(marked: Bool) { self = marked ? .classSees : .onlyYou }

    /// The switch's words.
    var label: String { VisibilitySymbol.everyoneSees(self == .classSees).words }

    /// An eye open or struck through (VisibilitySymbols.swift).
    var symbol: String { VisibilitySymbol.everyoneSees(self == .classSees).name }

    /// Frosted while hidden from the meeting, solid while it is in the picture.
    var backdrop: WindowBackdrop { self == .classSees ? .solid : .frosted }
}

// MARK: - Which windows offer "Show to everyone", and what the switch says

/// Every kind of window Greenroom opens, and whether it carries the switch.
/// Windows a layout places (Meeting window, Chat, views) are shown by default;
/// the rest are hidden, and the switch flips either. (This is Greenroom's OWN capture; what other
/// apps' recorders see is `sharingType`: always visible, except the Only-me camera bubble, PresenceRecorderRules.) Tools never carry it.
enum ShareableWindow: CaseIterable {
    case main, settings, meetingChat, participants, meetingWindow, meetingView
    /// The whiteboard Annotations opens (a plain window for the owner). The one Greenroom
    /// window that starts visible to everyone (`startsShown`); its eye still turns it off.
    case localWhiteboard
    // Never offered:
    /// Setup, not content: no eye. Other apps' captures may see it like any Greenroom window (every
    /// secret typed here is a SecureField, dotted); our own capture excludes it by filter.
    case setupGuide
    /// Tools for the person running the meeting, not content.
    case controlBar, island, recordingChrome, annotation, drawingToolbar
    /// The whiteboard is its own share target (our own capture excludes it by
    /// filter; other apps may record it, per PresenceRecorderRules).
    case whiteboard
    /// A web page with its tab strip in the title bar; no room, and never asked for.
    case browser

    var offersSwitch: Bool {
        switch self {
        case .main, .settings, .meetingChat, .participants, .meetingWindow, .meetingView, .localWhiteboard: return true
        case .setupGuide, .controlBar, .island, .recordingChrome, .annotation, .drawingToolbar,
             .whiteboard, .browser: return false
        }
    }

    /// Does the window's eye start on each time it opens? Greenroom's own windows start hidden,
    /// except the Annotations whiteboard (owner's decision 2026-11-25). The one place that says so.
    var startsShown: Bool { self == .localWhiteboard }

    /// Why a window is left out, for the record.
    var exclusionReason: String? {
        switch self {
        case .setupGuide: return "Setup, not content"
        case .controlBar, .island, .recordingChrome, .annotation, .drawingToolbar: return "A tool, never content"
        case .whiteboard: return "The whiteboard is its own share"
        case .browser: return "No eye switch (its tab strip fills the title bar); always in a whole-display share via alwaysShared"
        default: return nil
        }
    }
}

/// Windows that are in everyone's picture with no switch, whatever a layout placed.
enum ShareVisibilityRules {
    /// The Greenroom Browser is what the owner teaches from; the meeting must always
    /// see it. The setup guide and tools stay out.
    static func alwaysShared(windowKind: ShareableWindow) -> Bool { windowKind == .browser }
}

/// What one window's switch looks and says, from the person's choice and what
/// is being shared. One place, so every window reads alike.
struct ShareSwitchState: Equatable {
    let visibility: ShareVisibility
    let isEnabled: Bool
    let help: String
    let accessibilityLabel: String
    let accessibilityValue: String

    static let shownHelp = "Everyone in the meeting sees this window. Click to hide it."
    static let hiddenHelp = "Only you: the meeting can't see this window. Click to show it to everyone."

    init(on: Bool, kind: ShowOnShare.ShareKind) {
        let marked = ShowOnShare.marksWindow(on: on, kind: kind)
        visibility = ShareVisibility(marked: marked)
        isEnabled = ShowOnShare.isAvailable(kind)
        help = isEnabled ? (on ? Self.shownHelp : Self.hiddenHelp) : ShowOnShare.unavailableTip
        accessibilityLabel = "Show to everyone"
        accessibilityValue = visibility.label
    }
}

/// Whether one of Greenroom's own windows starts in the picture the meeting sees.
/// Only a window the running layout places follows its piece (which defaults to
/// shown, LayoutPiece.defaultShowsToEveryone); with no layout, or a layout that
/// does not place the window, it is "Only you".
enum LayoutShareRule {
    static func startsShown(placedBy piece: LayoutPiece?) -> Bool { piece.map { Visibility.everyoneSees(piece: $0, target: .wholeScreen).isOn } ?? false }
}

/// Whether the capture's app exclusion has caught up with the apps that should be hidden.
/// An app that is running but not yet in ScreenCaptureKit's list is not excluded yet, so the
/// watcher retries on its next tick instead of recording the change as applied.
enum ExclusionResolution {
    static func unresolved(hidden: Set<String>, running: Set<String>, listed: Set<String>) -> Set<String> {
        hidden.intersection(running).subtracting(listed)
    }

    static func isSettled(hidden: Set<String>, running: Set<String>, listed: Set<String>) -> Bool {
        unresolved(hidden: hidden, running: running, listed: listed).isEmpty
    }
}
