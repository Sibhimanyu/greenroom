//
//  ScreenroomAgreement.swift
//  Greenroom
//
//  When more than one person watched, what did they agree about?
//
//  The plan calls this the 10x extension: "the evaluator need not be one
//  person. A TA, a second teacher or the student's own peers could type notes
//  from their own machines into one session, with the AI as a consistency
//  check ACROSS evaluators."
//
//  It arrives here without a network, and that is on purpose. Notes are files
//  (approach A), so a second evaluator's contribution is a second notes.jsonl
//  handed over however people already hand things over, and merging is a
//  union by id. A transport would add a server, a pairing flow, a failure
//  mode mid-presentation, and an answer to "what happens when the TA's
//  laptop sleeps" - all to save an email. When there is a live meeting to
//  carry it, the transport can be added under this same merge and nothing
//  above it changes.
//
//  What the merge buys is the interesting part: two people watching the same
//  four minutes and writing about different things is a fact about the
//  rubric, not about the student. That is worth surfacing to a teacher, and
//  like ScreenroomCohort it is arithmetic over timestamps rather than a question
//  put to a model.
//
import Foundation

enum ScreenroomAgreement {

    /// How close two notes have to be to count as being about the same moment.
    ///
    /// Twenty seconds. Two people watching the same thing do not press a key
    /// at the same instant: one starts typing as it happens, the other waits
    /// to see how it resolves. Twenty seconds is wide enough to catch that
    /// and narrow enough that it is still one moment rather than one topic.
    static let sameMomentMs = 20_000

    /// A moment more than one evaluator wrote about.
    struct Moment: Identifiable, Hashable {
        let atMs: Int
        let notes: [ScreenroomNote]
        var id: Int { atMs }
        var authors: [String] { ScreenroomNotesFile.authors(in: notes) }
    }

    /// Everything worth saying about a presentation two or more people noted.
    /// Empty when only one person did, which is the normal case and not a
    /// deficiency to report.
    static func findings(in notes: [ScreenroomNote], soleAuthor: String = ScreenroomNote.soleAuthor) -> [ScreenroomCohort.Finding] {
        let authors = ScreenroomNotesFile.authors(in: notes, soleAuthor: soleAuthor)
        guard authors.count >= 2 else { return [] }

        var findings: [ScreenroomCohort.Finding] = []
        let shared = sharedMoments(in: notes, soleAuthor: soleAuthor)

        findings.append(ScreenroomCohort.Finding(
            weight: .note,
            headline: "\(authors.count) people took notes on this presentation",
            detail: "\(authors.joined(separator: ", ")). \(notes.count) notes between them, \(shared.count) \(shared.count == 1 ? "moment" : "moments") that more than one of them wrote about."))

        // The finding that is actually about the rubric. Two people watching
        // the same presentation and almost never writing at the same time
        // means they were watching for different things, which is a rubric
        // that has not been agreed rather than a student who was ambiguous.
        let perAuthor = authors.map { author in
            notes.filter { $0.authorLabel(soleAuthor: soleAuthor) == author }.count
        }
        if let smallest = perAuthor.min(), smallest >= 3 {
            let overlap = Double(shared.count) / Double(smallest)
            if overlap <= 0.25 {
                findings.append(ScreenroomCohort.Finding(
                    weight: .check,
                    headline: "The evaluators rarely wrote about the same moment",
                    detail: "Only \(shared.count) of \(smallest) notes from the person who wrote least overlap with anyone else's. Two people watching one presentation and noticing different things usually means the rubric has not been agreed, rather than that the presentation was ambiguous."))
            } else if overlap >= 0.6 {
                findings.append(ScreenroomCohort.Finding(
                    weight: .note,
                    headline: "The evaluators largely noticed the same moments",
                    detail: "\(shared.count) of \(smallest) notes from the person who wrote least line up with someone else's, within \(sameMomentMs / 1000) seconds."))
            }
        }

        // Stretches only one person was watching closely enough to write
        // about are worth knowing before the marks are compared.
        for author in authors {
            let mine = notes.filter { $0.authorLabel(soleAuthor: soleAuthor) == author }
            guard mine.count >= 3 else { continue }
            let sharedIDs = Set(shared.flatMap { $0.notes.map(\.id) })
            let alone = mine.filter { !sharedIDs.contains($0.id) }
            guard alone.count == mine.count, mine.count >= 4 else { continue }
            findings.append(ScreenroomCohort.Finding(
                weight: .check,
                headline: "Nothing \(author) wrote lines up with anyone else",
                detail: "All \(mine.count) of their notes sit more than \(sameMomentMs / 1000) seconds from every other note. Either they were watching for something nobody else was, or their clock and the recording's do not agree."))
        }

        return findings
    }

    /// Moments two or more evaluators both wrote about.
    ///
    /// A single pass over the notes in time order, growing a cluster while
    /// the next note is within the window of the one before it. Not of the
    /// cluster's start: three people writing ten seconds apart in a chain are
    /// describing one moment, and a fixed-window-from-the-start rule would
    /// cut that chain in the middle for no reason a human would recognise.
    static func sharedMoments(in notes: [ScreenroomNote],
                              soleAuthor: String = ScreenroomNote.soleAuthor) -> [Moment] {
        let ordered = notes.sorted { $0.atMs < $1.atMs }
        guard ordered.count >= 2 else { return [] }

        var moments: [Moment] = []
        var cluster: [ScreenroomNote] = []

        func close() {
            let authors = Set(cluster.map { $0.authorLabel(soleAuthor: soleAuthor) })
            if authors.count >= 2, let first = cluster.first {
                moments.append(Moment(atMs: first.atMs, notes: cluster))
            }
            cluster = []
        }

        for note in ordered {
            if let last = cluster.last, note.atMs - last.atMs > sameMomentMs { close() }
            cluster.append(note)
        }
        close()
        return moments
    }
}

/// Who is typing, on this Mac.
///
/// One name, kept in preferences. Asked for only when it matters - a single
/// evaluator never needs one, and Screenroom does not open with a form. It is
/// filled in the moment a second person's notes are imported, because that is
/// the first time "who wrote this" has an answer worth recording.
enum ScreenroomIdentity {
    private static let key = "screenroomEvaluatorName"

    static func current(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func set(_ name: String, in defaults: UserDefaults = .standard) {
        defaults.set(name.trimmingCharacters(in: .whitespaces), forKey: key)
    }

    /// What this Mac's notes should be signed with: the name given, or
    /// nothing at all. Deliberately not the macOS full name as a fallback -
    /// signing notes with a name the teacher never chose, and then printing
    /// it in a document handed to a student, is not a default anyone asked
    /// for.
    static var signature: String? {
        let name = current()
        return name.isEmpty ? nil : name
    }
}
