//
//  MarksNote.swift
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
struct MarksNote: Codable, Identifiable, Hashable {

    /// Schema version of THIS line. See the file note.
    var v: Int = MarksNote.schemaVersion

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

    static let schemaVersion = 1

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
enum MarksNotesFile {

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
    static func append(_ note: MarksNote, in folder: URL) -> Bool {
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
    static func load(in folder: URL) -> [MarksNote] {
        guard let text = try? String(contentsOf: url(in: folder), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(MarksNote.self, from: data)
        }
    }
}
