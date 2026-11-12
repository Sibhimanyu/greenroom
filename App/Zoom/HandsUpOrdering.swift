//
//  HandsUpOrdering.swift
//  Greenroom
//
//  The Hands up window's list, as pure values: raised hands in the order they
//  went up, and the waiting room in front. No SDK, no AppKit.
//
import Foundation

struct HandRow: Equatable, Identifiable {
    var id: UInt32
    var name: String
    var raisedAt: Date
    /// Joined audio and muted: "Ask to unmute" is useful only then.
    var muted: Bool
}

/// When each hand went up. Dropping the entry on lower is what makes a hand that
/// goes up again go to the back of the queue, which is the fair reading.
struct HandStamps: Equatable {
    private(set) var raisedAt: [UInt32: Date] = [:]

    /// Stamps new hands, forgets lowered ones and people who left.
    mutating func update(raised: Set<UInt32>, now: Date) {
        for id in raised where raisedAt[id] == nil { raisedAt[id] = now }
        raisedAt = raisedAt.filter { raised.contains($0.key) }
    }

    /// First hand up first. Ties (two seen in one poll) go by name, then id, so
    /// the list never shuffles between refreshes.
    func ordered(_ people: [(id: UInt32, name: String, muted: Bool)]) -> [HandRow] {
        people.compactMap { person -> HandRow? in
            guard let at = raisedAt[person.id] else { return nil }
            return HandRow(id: person.id, name: person.name, raisedAt: at, muted: person.muted)
        }
        .sorted { a, b in
            if a.raisedAt != b.raisedAt { return a.raisedAt < b.raisedAt }
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
}
