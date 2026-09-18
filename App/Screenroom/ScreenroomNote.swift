//
//  ScreenroomNote.swift
//  Greenroom
//
//  One evaluator's note, and the file they live in.
//
//  This file IS the product's API. docs/marks-evaluation-plan.md chose
//  approach A - "the session folder is the contract" - so the post-processing
//  pass that turns a presentation into a report does not link against
//  Greenroom, import a framework or call a method. It opens a folder and
//  reads two files: presentation.mov and notes.jsonl. A directory is a seam
//  that a refactor on this side cannot break.
//
//  Three consequences of being an API rather than an internal type:
//
//   - **Every line carries its own `v`.** The plan warns that the format
//     drifts unless something enforces it. A version in a header line would
//     mean the reader has to have seen the header, which breaks the moment
//     anyone tails the file or concatenates two of them. Per-line is a few
//     bytes and is true of any line read in isolation.
//   - **Dates are ISO 8601, not Foundation's default.** SessionMetadata
//     encodes Date as seconds-since-2001 because only Greenroom reads it.
//     This file is meant to be opened by a script somebody else wrote, and
//     978307200 is a trap in every language that is not Swift.
//   - **JSONL, appended per note, not one JSON array rewritten.** Same
//     reasoning as the class transcript: a note is written the instant it is
//     committed, so a crash mid-presentation keeps every note up to that
//     point. A rewritten array loses the lot and costs more the longer the
//     session runs.
//
import Foundation

/// A single timestamped note, as it appears on one line of `notes.jsonl`.
struct ScreenroomNote: Codable, Identifiable, Hashable {

    /// Schema version of THIS line. See the file note.
    ///
    var v: Int = ScreenroomNote.schemaVersion

    var id: UUID = UUID()

    /// Milliseconds into `presentation.mov`.
    ///
    /// Into the FILE, not wall-clock from the start of the window, and not an
    /// offset from when the evaluator sat down - the same choice SessionClip
    /// makes, for the same reason: this is the number a player seeks to and an
    /// exporter cuts at, and it survives the folder being copied elsewhere.
    var atMs: Int

    /// What the evaluator typed. Prose, no schema, no required category: the
    /// plan's premise 4 is that every keystroke spent on anything other than
    /// the words is attention stolen from the student in the room.
    var text: String

    /// The time of day the note was taken. Redundant with `atMs` while the
    /// recording exists, and the only timestamp left if it is ever deleted.
    var markedAt: Date

    /// Still 2, though v2's `author` field is gone again.
    ///
    /// v2 added an author so more than one evaluator could write into one
    /// presentation. That feature was cut before it shipped, and the field
    /// went with it. The number does not go back to 1 because v2 lines were
    /// written on the machines this was built on and a reader that saw one
    /// would be entitled to believe a claim that was briefly true. An unknown
    /// field decodes harmlessly, which is the property that made per-line
    /// versioning worth having in the first place.
    static let schemaVersion = 2

    /// `12:04` - where this note sits in the recording, for a human.
    ///
    /// Mono in the UI: this is a machine fact in DESIGN.md's sense, a number
    /// you could type into a player, not prose.
    var offsetLabel: String {
        let total = max(0, atMs / 1000)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Reads and writes a presentation's `notes.jsonl`.
enum ScreenroomNotesFile {

    static let fileName = "notes.jsonl"

    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    /// One encoder/decoder pair, so a note written here and a note read back
    /// cannot disagree about dates. Keys are sorted purely so a diff of two
    /// runs is readable.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Appends one note, creating the file and its folder if this is the
    /// first.
    ///
    /// Opens and closes the handle per note rather than holding one open for
    /// the session. A presentation produces tens of notes, not thousands, so
    /// the syscall is free at this rate, and the file is left closed and
    /// complete between notes - which is what makes "the recording crashed
    /// and I still have my notes" true rather than hoped for.
    @discardableResult
    static func append(_ note: ScreenroomNote, in folder: URL) -> Bool {
        guard let data = try? encoder.encode(note) else { return false }
        var line = data
        line.append(0x0A)

        let file = url(in: folder)
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)

        if !manager.fileExists(atPath: file.path) {
            return (try? line.write(to: file, options: .atomic)) != nil
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return false }
        return (try? handle.write(contentsOf: line)) != nil
    }

    /// Every note in the folder, in the order they were written.
    ///
    /// A line that will not decode is skipped rather than failing the read:
    /// one truncated last line from a hard kill must not cost the evaluator
    /// the forty notes above it.
    static func load(in folder: URL) -> [ScreenroomNote] {
        guard let text = try? String(contentsOf: url(in: folder), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ScreenroomNote.self, from: data)
        }
    }
}

extension ScreenroomNotesFile {

    /// Rewrites the file, in time order.
    ///
    /// The live path appends, so a crash mid-presentation cannot cost more
    /// than the note being typed. Editing afterwards is not live: nothing
    /// else holds the file open, and a note added while watching back belongs
    /// where it happened rather than at the end.
    static func replace(_ notes: [ScreenroomNote], in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ordered = notes.sorted {
            $0.atMs == $1.atMs ? $0.markedAt < $1.markedAt : $0.atMs < $1.atMs
        }
        let body = ordered.compactMap { note -> String? in
            guard let data = try? encoder.encode(note) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        try? (body + "\n").write(to: url(in: folder), atomically: true, encoding: .utf8)
    }

    /// Adds a note at a point in the recording and returns the new list.
    @discardableResult
    static func add(_ note: ScreenroomNote, in folder: URL) -> [ScreenroomNote] {
        let all = load(in: folder) + [note]
        replace(all, in: folder)
        return load(in: folder)
    }

    @discardableResult
    static func remove(_ id: UUID, in folder: URL) -> [ScreenroomNote] {
        replace(load(in: folder).filter { $0.id != id }, in: folder)
        return load(in: folder)
    }
}
