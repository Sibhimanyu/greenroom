//
//  RecentSpeakers.swift
//  Greenroom
//
//  The Multi-speaker view: the last few people who spoke, kept steady. Pure
//  (no SDK, no AppKit); fed with who is audible each time the SDK says so, read
//  once a second.
//
//  Rules (.context/meeting-views-plan.md, section 2):
//    - someone joins the view after 1.5 s of being heard, and stays at least 8 s;
//    - a newcomer replaces the least recently heard speaker who has been there
//      long enough, in that slot, so a tile never moves to another place;
//    - at most one change every 2 s, because Zoom refuses faster subscription
//      changes (code 7);
//    - you are never in it; a person who leaves frees their slot.
//
import Foundation

struct RecentSpeakers {
    static let joinAfter: TimeInterval = 1.5
    static let minimumStay: TimeInterval = 8
    static let changeEvery: TimeInterval = 2

    struct Slot: Equatable {
        var userID: UInt32
        var since: Date
        var lastHeard: Date
    }

    /// Per instance, so the in-window Multi-speaker view can keep people for
    /// less time (3 s, four places) than the Multi-speaker window (8 s).
    let joinAfter: TimeInterval
    let minimumStay: TimeInterval
    let changeEvery: TimeInterval

    /// Slot i keeps its place for as long as it holds anyone.
    private(set) var slots: [Slot?]
    private var heardSince: [UInt32: Date] = [:]
    private var lastHeardAt: [UInt32: Date] = [:]
    private var lastChange = Date.distantPast
    let limit: Int

    init(limit: Int = 3,
         joinAfter: TimeInterval = RecentSpeakers.joinAfter,
         minimumStay: TimeInterval = RecentSpeakers.minimumStay,
         changeEvery: TimeInterval = RecentSpeakers.changeEvery) {
        self.limit = limit
        self.joinAfter = joinAfter
        self.minimumStay = minimumStay
        self.changeEvery = changeEvery
        slots = Array(repeating: nil, count: limit)
    }

    /// Who is audible right now. `selfID` is skipped.
    mutating func heard(_ ids: [UInt32], selfID: UInt32?, now: Date) {
        let audible = Set(ids.filter { $0 != selfID })
        for id in audible {
            if heardSince[id] == nil { heardSince[id] = now }
            lastHeardAt[id] = now
        }
        // Someone who went quiet starts their 1.5 s again next time.
        for id in Array(heardSince.keys) where !audible.contains(id) { heardSince[id] = nil }
        for index in slots.indices {
            if let slot = slots[index], audible.contains(slot.userID) { slots[index]?.lastHeard = now }
        }
    }

    /// Settles the slots for this moment. `present` is who is in the meeting.
    /// Returns the user in each slot, in slot order, nils left out.
    @discardableResult
    mutating func update(present: Set<UInt32>, now: Date) -> [UInt32] {
        // Leavers free their slot at once (not a "change": nothing is subscribed).
        for index in slots.indices {
            if let slot = slots[index], !present.contains(slot.userID) { slots[index] = nil }
        }
        let inView = Set(slots.compactMap { $0?.userID })
        // Candidates: heard for long enough, not already shown, most recent first.
        let candidates = heardSince
            .filter { present.contains($0.key) && !inView.contains($0.key)
                      && now.timeIntervalSince($0.value) >= joinAfter }
            .map(\.key)
            .sorted { a, b in
                let la = lastHeardAt[a] ?? .distantPast, lb = lastHeardAt[b] ?? .distantPast
                return la != lb ? la > lb : a < b
            }
        if let newcomer = candidates.first, now.timeIntervalSince(lastChange) >= changeEvery {
            if let empty = slots.firstIndex(where: { $0 == nil }) {
                slots[empty] = Slot(userID: newcomer, since: now, lastHeard: lastHeardAt[newcomer] ?? now)
                lastChange = now
            } else {
                // Replace the least recently heard, if they have stayed long enough.
                let replaceable = slots.indices.filter {
                    guard let slot = slots[$0] else { return false }
                    return now.timeIntervalSince(slot.since) >= minimumStay
                }
                if let victim = replaceable.min(by: { (slots[$0]?.lastHeard ?? .distantPast) < (slots[$1]?.lastHeard ?? .distantPast) }) {
                    slots[victim] = Slot(userID: newcomer, since: now, lastHeard: lastHeardAt[newcomer] ?? now)
                    lastChange = now
                }
            }
        }
        return slots.compactMap { $0?.userID }
    }

    /// The slots as shown: left to right, a nil is an empty place. A meeting of
    /// two (you and one other) shows one tile, so empty places collapse out of
    /// the layout but the slot index of the others never changes.
    var occupied: [(slot: Int, userID: UInt32)] {
        slots.enumerated().compactMap { index, slot in slot.map { (index, $0.userID) } }
    }

    mutating func reset() {
        self = RecentSpeakers(limit: limit, joinAfter: joinAfter, minimumStay: minimumStay, changeEvery: changeEvery)
    }
}
