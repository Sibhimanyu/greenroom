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

extension ScreenroomAnalysis {

    /// The feedback with any claim the counts disprove taken out.
    ///
    /// A report in the mega test praised "No filler words at all" beside a
    /// counted row reading 2 fillers, with both "um"s highlighted in the
    /// transcript. The brief now tells every writer the counts win; this is
    /// the check for when one does not listen. Only claims a count can settle
    /// are touched, and only when the count is verbatim (whisper): a tidied
    /// transcript cannot prove there were fillers.
    /// `strict` also holds every point to the report's grade for pace,
    /// pauses and facing. Only for the on-device model: an agent that writes
    /// "a strong close, facing the room" while facing was low overall is
    /// right about the moment, and the blunt rule would throw that away.
    func agreeing(with metrics: ScreenroomSpeechMetrics?, presence: ScreenroomPresence? = nil,
                  strict: Bool = false) -> ScreenroomAnalysis {
        var fixed = self
        // Nothing here measures the eyes; the facing figure is head direction.
        // Every writer is told so, and the small one still says "eye contact".
        func honest(_ text: String) -> String {
            text.replacingOccurrences(of: #"(?i)\b(your |more |better |good |make |making )?eye contact"#,
                                      with: "facing the room", options: .regularExpression)
        }
        fixed.summary = honest(summary)
        fixed.strengths = strengths.map(honest)
        fixed.workOn = workOn.map(honest)
        fixed.patterns = patterns.map(honest)
        fixed.worked = worked?.map { var p = $0; p.headline = honest(p.headline); p.detail = honest(p.detail); return p }
        fixed.change = change?.map { var p = $0; p.headline = honest(p.headline); p.detail = honest(p.detail); return p }

        guard let metrics, metrics.verbatim, metrics.wordCount > 0 else { return fixed }
        let claimsNone = #"(?i)\b(no|zero|without (a |any )?(single )?)\s*(filler|crutch)|not (a single|one) filler|filler[- ]free"#
        let aboutFillers = #"(?i)\bfiller"#
        func says(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if metrics.fillerCount > 0 {
            fixed.strengths = fixed.strengths.filter { !says(claimsNone, $0) }
            fixed.patterns = fixed.patterns.filter { !says(claimsNone, $0) }
            fixed.worked = fixed.worked?.filter { !says(claimsNone, $0.headline) && !says(claimsNone, $0.detail) }
        }
        // Few enough to count as a strength on the report: advice to cut
        // them contradicts the row beside it.
        if Double(metrics.fillerCount) / Double(metrics.wordCount) <= ScreenroomInsights.fillerShare {
            fixed.workOn = fixed.workOn.filter { !says(aboutFillers, $0) }
            fixed.change = fixed.change?.filter { !says(aboutFillers, $0.headline) && !says(aboutFillers, $0.detail) }
        }
        return strict ? fixed.agreeing(pace: metrics, presence: presence) : fixed
    }

    /// The same rule for the other graded readings: advice to improve what
    /// the report marks as going well, or praise for what it marks as worth
    /// working on, is dropped. The on-device model, told the pace was
    /// comfortable, still wrote "Improve your pacing".
    private func agreeing(pace metrics: ScreenroomSpeechMetrics, presence: ScreenroomPresence?) -> ScreenroomAnalysis {
        var graded: [(pattern: String, good: Bool)] = [
            (#"(?i)\b(pace|pacing|speed|too fast|too slow|slow down|speed up)\b"#,
             ScreenroomSpeechMetrics.comfortablePace.contains(metrics.wordsPerMinute)),
            (#"(?i)\b(pause|pauses|pausing|breath)"#, metrics.talkRatio <= ScreenroomInsights.talkCeiling)
        ]
        if let presence, presence.sampleCount > 0 {
            graded.append((#"(?i)\b(facing|face the (room|camera|audience)|looking away|turned away|head)\b"#,
                           presence.facingRatio >= ScreenroomInsights.facingFloor))
        }
        func mentions(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        var fixed = self
        for (pattern, good) in graded {
            if good {
                fixed.workOn = fixed.workOn.filter { !mentions(pattern, $0) }
                fixed.change = fixed.change?.filter { !mentions(pattern, $0.headline) }
            } else {
                fixed.strengths = fixed.strengths.filter { !mentions(pattern, $0) }
                fixed.worked = fixed.worked?.filter { !mentions(pattern, $0.headline) }
            }
        }
        return fixed
    }
}
