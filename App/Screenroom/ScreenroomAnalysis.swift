//
//  ScreenroomAnalysis.swift
//  Greenroom
//
//  What the second pass produced, and the file it lives in.
//
//  Kept apart from the thing that produces it (ScreenroomAnalyst) because the two
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

struct ScreenroomAnalysis: Codable, Hashable {
    var v: Int = ScreenroomAnalysis.schemaVersion
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

    /// The verdict in one line, said before anything else.
    ///
    /// Optional, like the two lists below it, because every analysis written
    /// before them has none, and one of those must still open. When they are
    /// missing the report falls back to the summary and the sentences above.
    var headline: String?

    /// The same feedback as `strengths` and `workOn`, as points the report
    /// can draw: a few words to read at a glance, one sentence under them,
    /// and the moment it happened so the report can show that still and play
    /// from there. A paragraph that says "at about seventeen seconds" makes
    /// the student find the moment themselves; a point that knows 17000 does
    /// not.
    var worked: [Point]?
    var change: [Point]?

    /// Whether this came as points the report can draw.
    var hasPoints: Bool { !((worked ?? []) + (change ?? [])).isEmpty }

    struct Point: Codable, Hashable {
        var headline: String
        var detail: String
        /// Where in the recording this showed, when it showed at one place.
        var atMs: Int?

        /// The point as one sentence, for everything that prints text: the
        /// exported report, the side pane, an analysis read back by an older
        /// build.
        var sentence: String {
            let head = headline.trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty { return head }
            if head.isEmpty { return rest }
            let stop = head.last.map { ".!?".contains($0) } ?? false
            return head + (stop ? " " : ". ") + rest
        }
    }

    /// The rubric, as marked by whatever wrote this. Title, score and the
    /// one line saying why.
    ///
    /// Carried on the analysis rather than only in rubric.json because the
    /// two are one act now: the pass that reads the notes is the pass that
    /// marks, and an analysis that arrived without its marks would be half a
    /// judgement.
    var marks: [Mark] = []

    struct Mark: Codable, Hashable {
        var title: String
        var score: Int
        var reason: String
    }

    /// ScreenroomCohort's findings, flattened to text at the moment they were
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

    static func load(in folder: URL) -> ScreenroomAnalysis? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        return try? decoder.decode(ScreenroomAnalysis.self, from: data)
    }

    @discardableResult
    func save(in folder: URL) -> Bool {
        guard let data = try? Self.encoder.encode(self) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: Self.url(in: folder), options: .atomic)) != nil
    }
}
