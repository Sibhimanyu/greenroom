//
//  DisplayChangeRules.swift
//  Greenroom
//
//  What follows a display being plugged in or pulled out: the words in the log,
//  whether to wait for a start to finish, re-tile or leave windows alone, and
//  whether the Meeting is still hidden after a re-tile. Spec:
//  docs/specs/display-changes.md. Pure: Foundation only. The coordinator
//  (`displaysChanged`) carries out what this says.
//
import Foundation

enum DisplayChange {

    /// The log line for one settled change. `now` is the names of the displays there are.
    static func logLine(removed: Int, added: Int, setChanged: Bool, now: String) -> String {
        guard setChanged else {
            return "Display settings changed (resolution or arrangement). Now: \(now)."
        }
        var parts: [String] = []
        if removed > 0 { parts.append("\(removed) unplugged") }
        if added > 0 { parts.append("\(added) connected") }
        return "Displays changed (\(parts.joined(separator: ", "))). Now: \(now)."
    }

    enum FollowUp: Equatable {
        /// A start or stop is running: note it, the start re-tiles at its end.
        case deferToStart
        case nothing
        case snapBack(PlacementTrigger)
        /// Windows stay; the log says how to place the layout again.
        case leaveWindows
    }

    /// What to do once the stage, capture display, rescue and readiness card are
    /// looked after (R2).
    static func followUp(isRunning: Bool, stageLive: Bool, joined: Bool, arranges: Bool,
                         setChanged: Bool) -> FollowUp {
        if isRunning { return .deferToStart }
        guard stageLive, joined, arranges else { return .nothing }
        let trigger: PlacementTrigger = setChanged ? .displaysConnectedOrDisconnected : .displaySettingsChanged
        return LayoutPlacementRules.isExplicit(trigger) ? .snapBack(trigger) : .leaveWindows
    }

    /// At the end of a start (R3). Whatever the change was, it re-tiles as for a plug or unplug.
    static func snapAfterStart(changedDuringStart: Bool, arranges: Bool) -> Bool {
        changedDuringStart && arranges
    }

    /// Whether the Meeting counts as hidden after a re-tile (R4).
    static func hiddenAfterRetile(userInitiated: Bool, layoutStartsHidden: Bool,
                                  hasPlacedSurface: Bool, wasHidden: Bool) -> Bool {
        if userInitiated { return layoutStartsHidden }
        return hasPlacedSurface ? wasHidden : false
    }
}
