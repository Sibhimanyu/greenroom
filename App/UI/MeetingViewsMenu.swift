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

    /// The window toolbar's controls, as the bar's Views menu offers them while the
    /// Meeting window is away (MeetingControlsModel.viewsMenu).
    struct BarControls {
        var audio: [MenuEntry] = []
        var video: [MenuEntry] = []
        var react: [MenuEntry] = []
        /// Nil for a guest: Security is for a host or co-host.
        var security: [MenuEntry]?
        var sharing: [MenuEntry] = []
        /// A content-only view's pickers (Spotlight person, Shared screen); often none.
        var pickers: [MenuEntry] = []
    }

    /// The bar's Views menu while the Meeting window is away: the views, then what the
    /// window's toolbar had that the bar's cells do not, then Meeting info and the Zoom app.
    static func barViews(_ views: [MenuEntry], controls c: BarControls, facts: MeetingFacts,
                         _ a: MoreMenuActions) -> [MenuEntry] {
        var extras: [MenuEntry] = []
        extras.append(.submenu("Microphone and speaker", c.audio))
        extras.append(.submenu("Camera", c.video))
        extras.append(.submenu("Raise hand and react", c.react))
        if let security = c.security { extras.append(.submenu("Security", security)) }
        extras.append(.submenu("Sharing", c.sharing))
        if !c.pickers.isEmpty { extras += [.separator] + c.pickers }
        // No closing divider here: More puts one after a non-empty overflow, and a
        // second one drew an empty section above Meeting info (1.10.0).
        return views + [.separator] + more(overflow: extras, facts: facts, views: [], a)
    }
}
