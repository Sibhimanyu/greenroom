//
//  ParticipantClickRules.swift
//  Greenroom
//
//  What a click in the Meeting window does to the person drawer
//  (ParticipantInspectorView): a gallery tile or Speaker view's big stage picks
//  that person, the same one again or anywhere else closes it. The window hears
//  every click through one local monitor, because a click that lands on Zoom's
//  video element never reaches our views. Foundation only (tested).
//
import Foundation

enum ParticipantClick {

    /// What the click landed on.
    enum Target: Equatable {
        /// The drawer itself: its own buttons handle it.
        case drawer
        /// A tile or the stage showing this person.
        case person(UInt32, isMyself: Bool)
        /// Any control (a button on the stage's chrome, the toolbar), empty grid, the rail.
        case elsewhere
    }

    struct Outcome: Equatable {
        var selected: UInt32?
        /// True: the click is used up here (the view under it must not toggle again).
        var consumed: Bool
    }

    static func leftClick(on target: Target, selected: UInt32?) -> Outcome {
        switch target {
        case .drawer:
            return Outcome(selected: selected, consumed: false)
        case let .person(id, isMyself) where !isMyself:
            // The same person again closes it: a way back without a Done button.
            return Outcome(selected: selected == id ? nil : id, consumed: true)
        case .person, .elsewhere:
            // You are never selected: the drawer's controls are for someone else.
            return Outcome(selected: nil, consumed: false)
        }
    }

    /// Right-click: whose menu to show, if anyone's. Never your own.
    static func menuFor(_ target: Target) -> UInt32? {
        if case let .person(id, isMyself) = target, !isMyself { return id }
        return nil
    }
}
