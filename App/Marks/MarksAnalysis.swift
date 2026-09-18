//
//  MarksAnalysis.swift
//  Greenroom
//
//  What the second pass produced, and the file it lives in.
//
//  Kept apart from the thing that produces it (MarksAnalyst) because the two
//  have different lifetimes: an analysis written in September must still open
//  in June, after the model behind it has changed or become unavailable. So
//  the file records which engine wrote it, and every field is plain text that
//  needs nothing to read it back.
//
//  `engine` is not decoration. An analysis written by the on-device model and
//  one counted from the notes are different kinds of claim, and a report that
//  showed them identically would be lying by omission about where its
//  sentences came from.
//
import Foundation

struct MarksAnalysis: Codable, Hashable {
    var v: Int = MarksAnalysis.schemaVersion
    var generatedAt: Date = Date()

    /// Which pass wrote this, in the words the report will print.
    var engine: String

    /// Two or three sentences to the speaker, in the second person.
    var summary: String

    /// Drawn from the notes, never invented. Empty is a legitimate answer.
    var strengths: [String] = []
    var workOn: [String] = []

    /// Things true of the notes as a set rather than of any one note - a
    /// recurring theme, a stretch with nothing in it, a run of the same
    /// observation.
    var patterns: [String] = []

    /// MarksCohort's findings, flattened to text at the moment they were
    /// computed. Not recomputed on read: the cohort changes as the term goes
    /// on, and a report handed to a student in week 3 should still say what it
    /// said in week 3.
    var consistency: [String] = []

    static let schemaVersion = 1
    static let fileName = "analysis.json"

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load(in folder: URL) -> MarksAnalysis? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        return try? decoder.decode(MarksAnalysis.self, from: data)
    }

    @discardableResult
    func save(in folder: URL) -> Bool {
        guard let data = try? Self.encoder.encode(self) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: Self.url(in: folder), options: .atomic)) != nil
    }
}
