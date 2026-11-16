//
//  ChatGrouping.swift
//  Greenroom
//
//  The chat's reading rules, with no UI and no SDK in them so they can be
//  tested: which messages share one avatar-and-name header, what a sender is
//  called, and how a private message is labelled.
//
import Foundation

/// What the grouping needs to know about one message.
struct ChatLine: Equatable {
    let id: String
    /// Who sent it. The Zoom user ID when there is one, else the name, so two
    /// people who share a display name still split into two groups.
    let senderKey: String
    let senderName: String
    let isOutgoing: Bool
    let timestamp: Date
    /// The other side's name for a private message; nil when it went to everyone.
    let privateTo: String?
    /// A file always opens its own group: its card is not a line of speech.
    let isFile: Bool
}

enum ChatGrouping {
    /// Messages from one sender this close together share a header.
    static let window: TimeInterval = 180

    struct Row: Equatable {
        let line: ChatLine
        /// True when this row draws the avatar, name and time.
        let startsGroup: Bool
        let displayName: String
        let privateLabel: String?
    }

    static func rows(_ lines: [ChatLine], calendar: Calendar = .current) -> [Row] {
        lines.enumerated().map { index, line in
            let previous = index > 0 ? lines[index - 1] : nil
            return Row(line: line,
                       startsGroup: startsGroup(line, after: previous, calendar: calendar),
                       displayName: displayName(for: line),
                       privateLabel: privateLabel(for: line))
        }
    }

    static func startsGroup(_ line: ChatLine, after previous: ChatLine?, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        if previous.senderKey != line.senderKey { return true }
        if line.isFile || previous.isFile { return true }
        // A private run and a public one say different things in the header.
        if previous.privateTo != line.privateTo { return true }
        // The day divider sits between two days, so a header follows it.
        if !calendar.isDate(line.timestamp, inSameDayAs: previous.timestamp) { return true }
        return line.timestamp.timeIntervalSince(previous.timestamp) > window
    }

    /// Your own messages read "You"; everyone else is their display name.
    static func displayName(for line: ChatLine) -> String {
        line.isOutgoing ? "You" : line.senderName
    }

    /// "Privately to Maya" on yours; on theirs just "Privately to you", since their name is already beside it.
    static func privateLabel(for line: ChatLine) -> String? {
        guard let other = line.privateTo else { return nil }
        return line.isOutgoing ? "Privately to \(other)" : "Privately to you"
    }

    /// The quiet line above the composer: who will see what is typed.
    static func audienceNote(privateTo name: String?) -> String {
        name.map { "Only \($0) can see this message" } ?? "Everyone in the meeting can see your messages"
    }

    static func placeholder(privateTo name: String?, replying: Bool) -> String {
        if replying { return "Write your reply" }
        return name.map { "Message \($0)" } ?? "Message everyone"
    }
}
