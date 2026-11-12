//
//  MeetingRoomLedgers.swift
//  Greenroom
//
//  Small memories the SDK does not keep for us, as plain values:
//
//  - when each person reached the waiting room, so the list reads first come,
//    first admitted (the SDK hands back an unordered array of IDs);
//  - which emoji a person just sent, which a tile shows for three seconds;
//  - the persistent "yes / no / slow down" feedback badge.
//
import Foundation

// MARK: - Waiting room

struct WaitingPerson: Equatable {
    var id: UInt32
    var name: String
}

struct WaitingRoomLedger: Equatable {
    private var arrivals: [UInt32: Date] = [:]

    /// Stamps a newcomer. The first stamp wins: a repeated callback for the same
    /// person must not send them to the back of the line.
    mutating func arrived(_ id: UInt32, at date: Date) {
        if arrivals[id] == nil { arrivals[id] = date }
    }

    mutating func left(_ id: UInt32) { arrivals.removeValue(forKey: id) }

    /// Forgets anyone no longer waiting (admitted, expelled, gone).
    mutating func keep(only present: Set<UInt32>) {
        arrivals = arrivals.filter { present.contains($0.key) }
    }

    /// Longest waiting first. People already there before we began watching have
    /// no stamp and go first (they have waited at least that long), by name,
    /// then ID so the order never shuffles between refreshes.
    func ordered(_ people: [WaitingPerson]) -> [WaitingPerson] {
        people.sorted { a, b in
            switch (arrivals[a.id], arrivals[b.id]) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return true
            case (_?, nil): return false
            default:
                let order = a.name.localizedCaseInsensitiveCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
        }
    }
}

/// One line for the toast and the log when someone reaches the waiting room.
enum WaitingRoomWords {
    static func joined(_ name: String, total: Int) -> (title: String, detail: String) {
        let who = name.isEmpty ? "Someone" : name
        return ("\(who) is waiting to join",
                total > 1 ? "\(total) people are waiting. Open People to admit them."
                          : "Open People to admit them.")
    }
}

// MARK: - Reactions

/// Reactions fade after three seconds (the plan, Phase 3); the feedback badge
/// (yes, no, slow down, away) stays until its sender cancels it.
struct ReactionLedger {
    static let lifetime: TimeInterval = 3

    private var reactions: [UInt32: (glyph: String, at: Date)] = [:]
    private var feedback: [UInt32: String] = [:]

    mutating func reacted(_ id: UInt32, glyph: String, at date: Date) {
        reactions[id] = (glyph, date)
    }

    mutating func gaveFeedback(_ id: UInt32, label: String) { feedback[id] = label }
    mutating func canceledFeedback(_ id: UInt32) { feedback.removeValue(forKey: id) }

    func reaction(for id: UInt32, now: Date) -> String? {
        guard let entry = reactions[id], now.timeIntervalSince(entry.at) < Self.lifetime else { return nil }
        return entry.glyph
    }

    func feedbackLabel(for id: UInt32) -> String? { feedback[id] }

    /// Whether anything is still on a timer, so the window knows to redraw once
    /// more when it runs out.
    func hasLiveReaction(now: Date) -> Bool {
        reactions.values.contains { now.timeIntervalSince($0.at) < Self.lifetime }
    }

    /// Drops what has expired, and everyone who left.
    mutating func prune(now: Date, present: Set<UInt32>) {
        reactions = reactions.filter { now.timeIntervalSince($0.value.at) < Self.lifetime && present.contains($0.key) }
        feedback = feedback.filter { present.contains($0.key) }
    }
}

/// SDK values to what a tile draws. Raw values mirror ZoomSDKEmojiReactionType
/// (ZoomSDKErrors.h:1541-1556) and ZoomSDKEmojiFeedbackType (:2192-2205).
enum ReactionWords {
    static func glyph(reactionRaw: Int) -> String? {
        switch reactionRaw {
        case 1: return "\u{1F44F}"   // Clap
        case 2: return "\u{1F44D}"   // Thumbsup
        case 3: return "\u{2764}\u{FE0F}"   // Heart
        case 4: return "\u{1F602}"   // Joy
        case 5: return "\u{1F62E}"   // Openmouth
        case 6: return "\u{1F389}"   // Tada
        default: return nil
        }
    }

    static func label(feedbackRaw: Int) -> String? {
        switch feedbackRaw {
        case 1: return "Yes"
        case 2: return "No"
        case 3: return "Speed up"
        case 4: return "Slow down"
        case 5: return "Away"
        default: return nil
        }
    }
}
