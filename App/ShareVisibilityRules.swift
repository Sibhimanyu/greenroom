//
//  ShareVisibilityRules.swift
//  Greenroom
//
//  The plain words and the one-time explanation behind "Show on my share".
//  Most of Greenroom's windows are hidden from the picture the class sees; the
//  few that are let in carry an amber edge. Which window is marked is
//  ShowOnShare.marksWindow; this file says what to call each state and decides
//  when the island explains it (once ever per Mac, the first time a window goes
//  from hidden to seen or back). Foundation only, so the test target compiles
//  this file as it is.
//
import Foundation

/// The look of a window's background. The rule: a window only you see is
/// frosted (its background is see-through, its content stays opaque); a window
/// the class sees is solid and carries the amber edge.
enum WindowBackdrop: Equatable {
    case frosted, solid

    /// Whether the amber edge is drawn with this backdrop.
    var hasEdge: Bool { self == .solid }

    /// How long the change between the two takes; none with Reduce Motion.
    static func transitionDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0 : 0.2 }
}

/// What the class gets of one of our windows.
enum ShareVisibility: Equatable {
    case classSees, onlyYou

    init(marked: Bool) { self = marked ? .classSees : .onlyYou }

    /// The switch's words and the edge's label.
    var label: String { self == .classSees ? "Class sees this" : "Only you" }

    /// An eye open or struck through.
    var symbol: String { self == .classSees ? "eye" : "eye.slash" }

    /// Frosted while hidden from the class, solid while it is in the picture.
    var backdrop: WindowBackdrop { self == .classSees ? .solid : .frosted }

    /// The one-time island toast: a short sentence for each way round.
    var explanation: String {
        self == .classSees ? "The class sees this window." : "Hidden from the class. Only you see this window."
    }
}

enum ShareVisibilityExplainer {
    static let defaultsKey = "shareVisibility.explained"

    /// What to tell now, or nil. `was` is what the window was a moment ago;
    /// nothing is said when nothing changed or the Mac has been told already.
    static func toast(was: ShareVisibility, now: ShareVisibility, alreadyExplained: Bool) -> String? {
        guard was != now, !alreadyExplained else { return nil }
        return now.explanation
    }

    static func hasExplained(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func markExplained(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: defaultsKey)
    }
}

// MARK: - Which windows offer "Show to class", and what the switch says

/// Every kind of window Greenroom opens, and whether it carries the switch.
/// Hidden from the class by default; the switch lets the person show one, say
/// to show how they present. Tools and anything private never carry it.
enum ShareableWindow: CaseIterable {
    case main, settings, meetingChat, participants, meetingWindow, meetingView, mini
    // Never offered:
    /// Credentials are typed here (`sharingType = .none`).
    case setupGuide
    /// Tools for the person running the class, not content.
    case controlBar, island, recordingChrome, annotation, drawingToolbar
    /// The whiteboard is its own share target (`sharingType = .none`).
    case whiteboard
    /// A web page with its tab strip in the title bar; no room, and never asked for.
    case browser

    var offersSwitch: Bool {
        switch self {
        case .main, .settings, .meetingChat, .participants, .meetingWindow, .meetingView, .mini: return true
        case .setupGuide, .controlBar, .island, .recordingChrome, .annotation, .drawingToolbar,
             .whiteboard, .browser: return false
        }
    }

    /// Why a window is left out, for the record.
    var exclusionReason: String? {
        switch self {
        case .setupGuide: return "Credentials are typed there"
        case .controlBar, .island, .recordingChrome, .annotation, .drawingToolbar: return "A tool, never content"
        case .whiteboard: return "The whiteboard is its own share"
        case .browser: return "Tab strip fills the title bar"
        default: return nil
        }
    }
}

/// What one window's switch looks and says, from the person's choice and what
/// is being shared. One place, so every window reads alike.
struct ShareSwitchState: Equatable {
    let visibility: ShareVisibility
    let isEnabled: Bool
    let help: String
    let accessibilityLabel: String
    let accessibilityValue: String

    static let shownHelp = "The class sees this window. Click to hide it."
    static let hiddenHelp = "Only you: the class can't see this window. Click to show it to the class."

    init(on: Bool, kind: ShowOnShare.ShareKind) {
        let marked = ShowOnShare.marksWindow(on: on, kind: kind)
        visibility = ShareVisibility(marked: marked)
        isEnabled = ShowOnShare.isAvailable(kind)
        help = isEnabled ? (on ? Self.shownHelp : Self.hiddenHelp) : ShowOnShare.unavailableTip
        accessibilityLabel = "Show to class"
        accessibilityValue = visibility.label
    }
}
