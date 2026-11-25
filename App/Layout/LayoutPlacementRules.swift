//
//  LayoutPlacementRules.swift
//  Greenroom
//
//  When a layout may move a window (R45). A layout places windows once: at
//  Start, when the owner switches layouts, and when the owner asks (the Snap
//  shortcut or the menu bar's Snap Windows Back). After that a window the owner
//  moved or resized stays where it is, and nothing a layout does activates an
//  app or takes keyboard focus. Owner, 2026-11-26: "it should only snap back
//  into place when I tell it to ... It should not play tug of war and suddenly
//  change window focus."
//
//  Every path that moves a window during a meeting asks here first:
//  `LayoutEngine` (apps, Chat, views, Room screen, the neighbour that grows into
//  the Meeting's gap), the coordinator (Snap Back, Apply now, a display change,
//  an edit to the running layout, the Meeting coming back) and the Meeting
//  window's one-second loop. Pure: Foundation and CoreGraphics only.
//
import Foundation
import CoreGraphics

/// What asked for windows to be placed.
enum PlacementTrigger: Equatable, CaseIterable {
    /// The Start sequence's own pass.
    case start
    /// Apply now, a Use-layout shortcut, a layout picked from the Present menu.
    case switchedLayout
    /// The Snap shortcut or the menu bar's Snap Windows Back.
    case snapBack
    /// A display plugged in or pulled out. Kept as it was before R45: everything
    /// is placed again against the displays that are there now.
    case displaysConnectedOrDisconnected
    /// The same displays with a new resolution or arrangement, or the Dock or
    /// menu bar changing the usable area. Stranded windows are rescued; nothing
    /// else moves.
    case displaySettingsChanged
    /// The running layout edited in Settings mid-meeting. It is kept for the next
    /// Snap Back; the windows stay put.
    case layoutEdited
    /// A piece's window shows for the first time: an app that launched late, a
    /// view or the Chat opened later.
    case windowAppeared
    /// The Meeting window comes back: from the bar, the speaker-tile shortcut, a
    /// Dock click or a menu choice.
    case meetingShown
    /// The Meeting hides or returns and the piece that joins it grows into the
    /// gap or gives the room back.
    case neighbourMakesRoom
    /// The owner moved or resized a window.
    case movedByHand
    /// The Meeting window's one-second follow loop.
    case tick
}

/// Where one window stands against the layout.
enum PlacedWindowState: Equatable, CaseIterable {
    /// There is no window yet (the app has not shown one, the view never opened).
    case neverPlaced
    /// It is where Greenroom last put it, or there is no record saying otherwise.
    case placed
    /// It is somewhere else: the owner dragged or resized it.
    case movedByHand
}

enum LayoutPlacementRules {

    /// The passes the owner asked for, which put every window back.
    static func isExplicit(_ trigger: PlacementTrigger) -> Bool {
        switch trigger {
        case .start, .switchedLayout, .snapBack, .displaysConnectedOrDisconnected: return true
        case .displaySettingsChanged, .layoutEdited, .windowAppeared, .meetingShown,
             .neighbourMakesRoom, .movedByHand, .tick: return false
        }
    }

    /// Does this event move this window to the layout's frame?
    static func shouldPlace(_ trigger: PlacementTrigger, _ state: PlacedWindowState) -> Bool {
        if isExplicit(trigger) { return true }
        switch trigger {
        case .windowAppeared, .meetingShown:
            return state == .neverPlaced
        case .neighbourMakesRoom:
            return state != .movedByHand
        case .displaySettingsChanged, .layoutEdited, .movedByHand, .tick:
            return false
        case .start, .switchedLayout, .snapBack, .displaysConnectedOrDisconnected:
            return true
        }
    }

    /// Does the pass order windows that are already placed to the front (without
    /// activating Greenroom or taking key)? Only a pass the owner asked for.
    static func raisesPlacedWindows(_ trigger: PlacementTrigger) -> Bool { isExplicit(trigger) }

    /// Placing a window never activates its app or takes keyboard focus: a late
    /// app comes up where the layout puts it, behind what the owner is using.
    static func activatesWhenPlacing(_ trigger: PlacementTrigger) -> Bool { false }

    /// The one focus hand-off a layout makes: at the end of Start, the largest app
    /// on the main display becomes the active app.
    static func handsFocusToMainApp(_ trigger: PlacementTrigger) -> Bool { trigger == .start }

    /// How far (points) a window may sit from where it was placed and still count
    /// as placed: apps round frames, and title bars snap to whole points.
    static let handMoveTolerance: CGFloat = 6

    /// Reads a window against the frame Greenroom last placed it at (both in the
    /// same coordinate space). No window is never placed; an open window with no
    /// record either way counts as placed.
    static func state(windowExists: Bool, current: CGRect?, placed: CGRect?) -> PlacedWindowState {
        guard windowExists else { return .neverPlaced }
        guard let current, let placed else { return .placed }
        let t = handMoveTolerance
        let moved = abs(current.minX - placed.minX) > t || abs(current.minY - placed.minY) > t
            || abs(current.width - placed.width) > t || abs(current.height - placed.height) > t
        return moved ? .movedByHand : .placed
    }
}
