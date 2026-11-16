//
//  SessionSelection.swift
//  Greenroom
//
//  The rules for picking several cards in the Sessions grid, Finder-style.
//  Pure values, no SwiftUI, so the rules can be tested without a window.
//
import Foundation

struct SessionSelection: Equatable {
    /// The cards that are picked.
    private(set) var ids: Set<String> = []
    /// The card a Shift-click measures from: the last one picked on its own.
    private(set) var anchor: String?

    init(ids: Set<String> = [], anchor: String? = nil) {
        self.ids = ids
        self.anchor = anchor
    }

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// A click. `order` is every card on screen, in the order they are drawn.
    mutating func click(_ id: String, order: [String], command: Bool, shift: Bool) {
        if shift, let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            let range = Set(order[min(a, b)...max(a, b)])
            // Command + Shift adds the range to what is already picked.
            ids = command ? ids.union(range) : range
            return   // the anchor stays put, as in Finder
        }
        if command {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        } else {
            ids = [id]
        }
        anchor = id
    }

    mutating func selectAll(_ order: [String]) {
        ids = Set(order)
        anchor = order.first
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    /// Forget cards that are no longer on screen (a filter or search changed).
    mutating func keep(only order: [String]) {
        ids.formIntersection(order)
        if let anchor, !ids.contains(anchor) { self.anchor = nil }
    }

    /// The picked cards in display order, not set order.
    func ordered(_ order: [String]) -> [String] { order.filter(ids.contains) }
}

enum SessionTrashPlan {
    /// Splits what was picked into what can go to the Trash and what must stay:
    /// a session that is live right now is still being written to.
    static func split(_ picked: [String], live: Set<String>) -> (trash: [String], skipped: [String]) {
        (picked.filter { !live.contains($0) }, picked.filter { live.contains($0) })
    }

    /// "3 sessions", "1 session".
    static func noun(_ n: Int) -> String { n == 1 ? "1 session" : "\(n) sessions" }

    static func message(trash: Int, skipped: Int) -> String {
        var text = trash == 1
            ? "1 session goes to the Trash. You can put it back from there."
            : "\(trash) sessions go to the Trash. You can put them back from there."
        text += " Videos already on YouTube stay up."
        if skipped > 0 {
            text += " \(noun(skipped)) \(skipped == 1 ? "is" : "are") live right now, so \(skipped == 1 ? "it stays" : "they stay")."
        }
        return text
    }
}
