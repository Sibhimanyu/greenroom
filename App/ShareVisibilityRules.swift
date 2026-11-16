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
