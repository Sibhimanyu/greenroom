//
//  SessionNoteEditRules.swift
//  Greenroom
//
//  The pure half of the Notes tab: which note is current, and
//  editing, retiming, deleting and restoring a note BY ID.
//
//  Why there is no pre-roll. A click on a note used to seek 4 seconds before
//  it (SessionDetailRules.noteSeekTime). With notes 4 seconds apart that lands
//  exactly on the PREVIOUS note, and the list highlights the wrong row. The
//  note's `atMs` is already the moment the evaluator began typing, so a click
//  seeks to exactly `atMs`.
//
import Foundation

enum SessionNoteEditRules {

    /// The prefix RecordingsView gives a note's SessionMoment id.
    static let momentPrefix = "n-"

    static func noteID(fromMomentID id: String) -> UUID? {
        guard id.hasPrefix(momentPrefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(momentPrefix.count)))
    }

    /// Seconds a click on a note seeks to: the note's own time, no pre-roll.
    static func seekTime(forAtMs atMs: Int) -> Double { Double(max(0, atMs)) / 1000 }

    /// The note the picture is at: the last one that started at or before
    /// `playhead`. Nil before the first. `slack` absorbs the player reporting
    /// a hair under the time it was just sent to.
    static func currentNoteID(_ notes: [(id: String, at: Double)], playhead: Double,
                              slack: Double = 0.05) -> String? {
        var best: (id: String, at: Double)?
        for note in notes where note.at <= playhead + slack {
            if best == nil || note.at >= best!.at { best = note }
        }
        return best?.id
    }

    /// Replaces one note's words. Nil when the id is unknown or the new text
    /// is blank (the caller treats blank as "keep the old one"). Every other
    /// field, and every other note, is untouched.
    static func edited(_ notes: [ScreenroomNote], id: UUID, text: String) -> [ScreenroomNote]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = notes
        copy[index].text = trimmed
        return copy
    }

    /// Moves one note to `atMs`. Nil when the id is unknown.
    static func retimed(_ notes: [ScreenroomNote], id: UUID, atMs: Int) -> [ScreenroomNote]? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = notes
        copy[index].atMs = max(0, atMs)
        return copy
    }

    static func removed(_ notes: [ScreenroomNote], id: UUID) -> [ScreenroomNote] {
        notes.filter { $0.id != id }
    }

    /// Puts a deleted note back (same id, same fields). A no-op when a note
    /// with that id is already there, so a double Undo cannot duplicate it.
    static func restored(_ notes: [ScreenroomNote], note: ScreenroomNote) -> [ScreenroomNote] {
        notes.contains { $0.id == note.id } ? notes : notes + [note]
    }
}
