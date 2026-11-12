//
//  MeetingViewsMenu.swift
//  Greenroom
//
//  The Views menu as data: the Meeting window, then every view, a checkmark on
//  each that is open. It lives in the toolbar's More menu and in the floating
//  bar's puck menu, so the two cannot disagree. Choosing an item opens that
//  window (at its layout rectangle if the layout has one, else where it was
//  last left) or closes it.
//
import Foundation

extension MeetingMenus {

    struct ViewsMenuState: Equatable {
        /// Greenroom's meeting window is open.
        var meetingWindowOpen = false
        /// The views that have a window open now.
        var openViews: Set<MeetingView> = []
        /// Views need Greenroom's own meeting UI and the kill switch on.
        var viewsAvailable = true
    }

    /// Meeting window first, a divider, then the views in their fixed order. With
    /// views unavailable only the Meeting window is offered.
    static func views(_ state: ViewsMenuState,
                      toggleMeetingWindow: @escaping () -> Void,
                      toggleView: @escaping (MeetingView) -> Void) -> [MenuEntry] {
        var out: [MenuEntry] = [
            .item("Meeting window", checked: state.meetingWindowOpen, toggleMeetingWindow),
        ]
        guard state.viewsAvailable else { return out }
        out.append(.separator)
        out += MeetingView.allCases.map { view in
            .item(view.title, checked: state.openViews.contains(view)) { toggleView(view) }
        }
        return out
    }
}
