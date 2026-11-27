//
//  SidebarRules.swift
//
//  Which columns the main window shows and how wide, as plain values with no
//  view in them, so Tests/SidebarRulesTests.swift can hold them
//  (SessionsSidebar.swift draws the column).
//
import SwiftUI

/// Which columns the window shows.
enum SidebarRules {
    /// Persisted: a teacher who hid the sidebar finds it hidden next time, as in Finder.
    static let hiddenKey = "sessionsSidebarHidden"

    /// Home and Record never show it. The Sessions grid shows it unless the
    /// person hid it. A single session (its page, its report) never shows it:
    /// the watch page wants the width, and the saved choice is untouched, so
    /// the grid comes back the way the person left it.
    static func visibility(onSessionsPage: Bool, hidden: Bool,
                           onSingleSession: Bool = false) -> NavigationSplitViewVisibility {
        shown(onSessionsPage: onSessionsPage, hidden: hidden, onSingleSession: onSingleSession) ? .all : .detailOnly
    }

    static func shown(onSessionsPage: Bool, hidden: Bool, onSingleSession: Bool = false) -> Bool {
        onSessionsPage && !hidden && !onSingleSession
    }

    /// What a change of column visibility means for the saved choice. Nothing
    /// off the Sessions grid: Home and a single session force the column away,
    /// which is not a choice.
    static func hidden(afterVisibility new: NavigationSplitViewVisibility,
                       onSessionsPage: Bool, was: Bool,
                       onSingleSession: Bool = false) -> Bool {
        onSessionsPage && !onSingleSession ? new == .detailOnly : was
    }

    /// The width the sidebar column opens at; the window's page minimum is
    /// sized to hold it.
    static let idealWidth: CGFloat = 220
    static let widthRange: ClosedRange<CGFloat> = 180...280

    /// The detail column's minimum width, given the window's. With the
    /// sidebar showing, the window minimum holds the sidebar too.
    static func detailMinWidth(windowMin: CGFloat, sidebarShown: Bool, sidebarWidth: CGFloat) -> CGFloat {
        sidebarShown ? max(windowMin - sidebarWidth, 0) : windowMin
    }
}

/// What Home's toolbar needs across, so no item ever folds into the system "»"
/// chevron (owner rule: Settings never hides). Home has no sidebar, so only the
/// toolbar's own items count. Measured by arithmetic, not on screen: each figure
/// is the macOS 26 size rounded UP, and `safety` covers what the sum misses.
enum HomeToolbarRules {
    /// Traffic lights and the leading margin; the leading side holds nothing else.
    static let leading: CGFloat = 78
    /// "My Meetings" at 13pt semibold is about 81pt; plus 14pt padding each side,
    /// three equal segments, plus the track's inset.
    static let switcher: CGFloat = 3 * (81 + 28) + 8
    /// Sessions (glass button with its margins), the fixed spacer, the Setup guide
    /// and Settings group, the share eye's title-bar accessory (24 + 12), margins.
    static let sessions: CGFloat = 48
    static let spacer: CGFloat = 12
    static let group: CGFloat = 100
    static let shareAccessory: CGFloat = 36
    static let trailingMargin: CGFloat = 20
    /// The gap the system keeps between the principal item and the sides.
    static let gap: CGFloat = 16
    /// Room for a font size or a system release that differs from the above.
    static let safety: CGFloat = 48

    static var need: CGFloat {
        leading + gap + switcher + gap + sessions + spacer + group + shareAccessory + trailingMargin
    }
    static var minWindowWidth: CGFloat { need + safety }
}
