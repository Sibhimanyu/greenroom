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

    /// Home never show it. A Sessions page shows it unless
    /// the person hid it.
    static func visibility(onSessionsPage: Bool, hidden: Bool) -> NavigationSplitViewVisibility {
        onSessionsPage && !hidden ? .all : .detailOnly
    }

    /// What a change of column visibility means for the saved choice. Nothing
    /// off the Sessions pages: Home forces the column away, which is not a choice.
    static func hidden(afterVisibility new: NavigationSplitViewVisibility,
                       onSessionsPage: Bool, was: Bool) -> Bool {
        onSessionsPage ? new == .detailOnly : was
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
