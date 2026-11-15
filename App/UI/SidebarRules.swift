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
