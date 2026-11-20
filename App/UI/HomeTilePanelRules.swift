//
//  HomeTilePanelRules.swift
//
//  Pure rules for the Home tile panels (Look, Camera, ...): which sections a
//  panel shows, how a tap changes the camera list, and how arrow keys move.
//  Foundation only, so Tests/ compiles it without any view code.
//
import Foundation

/// Arrow-key movement through a row of choices.
enum HomeTileKeyRules {
    /// The next index after `delta` steps, clamped to the ends (no wrap: the
    /// edge is where the eye expects the row to stop).
    static func moved(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }

    /// Where the keyboard starts: the chosen one, else the first.
    static func startIndex(selected: Int?, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(selected ?? 0, 0), count - 1)
    }
}

/// What the Camera panel shows and what a tap does.
enum CameraPanelRules {
    enum Section: Equatable { case cameras, switching }

    /// The switch is only worth offering with somewhere to cut to.
    static func showsSwitchToggle(availableCount: Int) -> Bool { availableCount >= 2 }

    /// Auto-switch tuning (delay, cut or fade) needs the switch on AND two or
    /// more cameras chosen: with one there is nothing to switch between.
    static func showsSwitching(switchOn: Bool, chosenCount: Int) -> Bool {
        switchOn && chosenCount >= 2
    }

    /// Switch on with fewer than two chosen: say what is missing.
    static func showsPickAnotherHint(switchOn: Bool, chosenCount: Int) -> Bool {
        switchOn && chosenCount < 2
    }

    static func sections(switchOn: Bool, chosenCount: Int) -> [Section] {
        showsSwitching(switchOn: switchOn, chosenCount: chosenCount) ? [.cameras, .switching] : [.cameras]
    }

    /// Chosen cameras that are plugged in right now, in cut order.
    static func chosen(order: [String], available: [String]) -> [String] {
        let present = Set(available)
        return order.filter { present.contains($0) }
    }

    /// Whether a camera's row carries the check.
    static func isSelected(uid: String, switchOn: Bool, order: [String], single: String?, noCamera: Bool) -> Bool {
        if switchOn { return order.contains(uid) }
        return !noCamera && single == uid
    }

    /// The 1-based cut position shown on a row; only while switching is on.
    static func position(of uid: String, switchOn: Bool, order: [String]) -> Int? {
        guard switchOn, let index = order.firstIndex(of: uid) else { return nil }
        return index + 1
    }

    /// The list after tapping a camera. Switching on: toggles membership, so
    /// the order is the order they were chosen in. Off: that camera becomes
    /// the one, moved to the front of the same list.
    static func tapped(uid: String, switchOn: Bool, order: [String]) -> [String] {
        if switchOn {
            return order.contains(uid) ? order.filter { $0 != uid } : order + [uid]
        }
        return [uid] + order.filter { $0 != uid }
    }

    /// The list when the switch turns on: the camera already in use stays in
    /// it, so turning switching on starts from what the picture shows.
    static func orderWhenSwitchingOn(order: [String], single: String?) -> [String] {
        guard let single, !order.contains(single) else { return order }
        return [single] + order
    }

    /// "No camera" is refused while nothing is shared (the picture would be
    /// an empty backdrop).
    static func noCameraEnabled(shareIsNothing: Bool) -> Bool { !shareIsNothing }

    /// SF Symbol for a camera row.
    static func symbol(name: String, isBuiltIn: Bool) -> String {
        if isBuiltIn { return "laptopcomputer" }
        if name.localizedCaseInsensitiveContains("iphone") { return "iphone" }
        return "web.camera"
    }

    /// The panel header's value: the camera in use, "2 cameras, switching",
    /// or Off.
    static func headerValue(noCamera: Bool, switchOn: Bool, chosenCount: Int, singleName: String?) -> String {
        if noCamera { return "Off" }
        if switchOn, chosenCount >= 2 { return "\(chosenCount) cameras, switching" }
        return singleName ?? "No camera found"
    }
}
