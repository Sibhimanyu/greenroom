//
//  WindowStackRules.swift
//  Greenroom
//
//  Keeping Greenroom's windows stacked as the owner left them across a desktop
//  (Space) switch (R45.6). Pure: Foundation only. Window numbers are listed
//  front to back, as CGWindowList gives them for the desktop in view.
//
//  Owner, 2026-11-26: the Self view window floated over the Greenroom Browser;
//  after switching to another desktop and back it was behind the browser.
//  Nothing in Greenroom orders a window on a desktop change; coming back to the
//  desktop makes Greenroom the active app again, and AppKit brings the app's
//  main window (the browser; view windows are panels that never become main)
//  in front of the rest. `WindowStackKeeper` remembers the order and puts it
//  back with these rules, without activating or taking key.
//
import Foundation

enum WindowStackRules {

    /// Put `window` directly in front of `above`.
    struct Move: Equatable {
        var window: Int
        var above: Int
    }

    /// Where a window we hid goes when it comes back.
    enum Slot: Equatable {
        /// Directly in front of this window, the one that was under it.
        case above(Int)
        /// Nothing it was over is still up (or no record): the front.
        case front
    }

    /// After a desktop switch: look once AppKit's activation has reordered
    /// things, and once more in case it was late.
    static let restoreDelays: [TimeInterval] = [0.25, 0.8]
    /// No order is remembered for this long after a switch, so the reorder being
    /// undone is never saved as the owner's.
    static let freezeSeconds: TimeInterval = 1.0

    /// The fewest moves that put the windows both lists share back in the saved
    /// order. Windows only in one list are left alone. Each window is checked
    /// from the back: it stays if it is already in front of the one that should
    /// be under it, with only windows between that will end up in front of it.
    static func restoreMoves(saved: [Int], current: [Int]) -> [Move] {
        let desired = saved.filter(current.contains)
        var stack = current.filter(desired.contains)
        guard desired.count >= 2, stack != desired else { return [] }
        let rank = Dictionary(uniqueKeysWithValues: desired.enumerated().map { ($1, $0) })
        var moves: [Move] = []
        for i in stride(from: desired.count - 2, through: 0, by: -1) {
            let window = desired[i], under = desired[i + 1]
            guard let at = stack.firstIndex(of: window), let ref = stack.firstIndex(of: under) else { continue }
            let between = at < ref ? stack[(at + 1)..<ref] : []
            if at < ref, between.allSatisfy({ (rank[$0] ?? 0) < i }) { continue }
            stack.remove(at: at)
            stack.insert(window, at: stack.firstIndex(of: under) ?? 0)
            moves.append(Move(window: window, above: under))
        }
        return moves
    }

    /// A click or key press after coming back is the owner's new order: no restore.
    static func shouldRestore(ownerActedSinceSwitch: Bool) -> Bool { !ownerActedSinceSwitch }

    /// A window we hid and now show again goes back above the first window that
    /// was under it and is still up, not to the front or the back.
    static func slot(for window: Int, saved: [Int], visibleNow: [Int]) -> Slot {
        guard let index = saved.firstIndex(of: window) else { return .front }
        if let under = saved[(index + 1)...].first(where: visibleNow.contains) { return .above(under) }
        return .front
    }
}

/// The last stacking order seen on each desktop. There is no public id for a
/// desktop, so an order is known by its windows: a newer order sharing any
/// window replaces the older one.
struct WindowStackMemory: Equatable {
    static let limit = 8
    private(set) var orders: [[Int]] = []

    mutating func remember(_ order: [Int]) {
        guard order.count >= 2 else { return }
        let windows = Set(order)
        orders.removeAll { !windows.isDisjoint(with: $0) }
        orders.append(order)
        if orders.count > Self.limit { orders.removeFirst(orders.count - Self.limit) }
    }

    /// The remembered order with the most windows in common with `current`
    /// (at least two), or nil.
    func saved(for current: [Int]) -> [Int]? {
        let now = Set(current)
        let best = orders.max { now.intersection($0).count < now.intersection($1).count }
        guard let best, now.intersection(best).count >= 2 else { return nil }
        return best
    }
}
