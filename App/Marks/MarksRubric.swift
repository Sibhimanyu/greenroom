//
//  MarksRubric.swift
//  Greenroom
//
//  What the presentation is being marked against, and what it scored.
//
//  The plan left "what the rubric actually is: fixed, per-assignment, or
//  per-teacher" as an open question. The answer here is per-teacher with a
//  per-presentation SNAPSHOT, which is not a compromise so much as the only
//  version that survives contact with a term:
//
//   - A teacher marks a cohort against one rubric, so the rubric has to carry
//     from student to student without being retyped. That is the default,
//     kept in UserDefaults.
//   - A rubric edited in November must not silently re-interpret marks given
//     in September. A score is only meaningful next to the words it was given
//     against, so every presentation stores its own copy of the criteria it
//     was marked on, and nothing later can rewrite them.
//
//  That snapshot is also what makes the cohort pass honest: MarksCohort only
//  compares presentations whose criteria actually match, rather than assuming
//  that two things both called "Structure" meant the same thing.
//
import Foundation

/// One line of a rubric: a thing being judged, and the range it is judged on.
struct MarksCriterion: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    /// One line telling the evaluator what this criterion is actually asking,
    /// shown under the title. The plan's premise 4 again: a criterion whose
    /// meaning has to be remembered costs attention every time it is used.
    var hint: String = ""
    var maxScore: Int = 5
}

/// The criteria, as a set. Named so a teacher can keep more than one.
struct MarksRubric: Codable, Hashable {
    var name: String
    var criteria: [MarksCriterion]

    /// A starting point, not a recommendation.
    ///
    /// Five lines because a rubric long enough to be thorough is a rubric that
    /// does not get filled in while a student is still standing up. These are
    /// the ones that recur in every speaking rubric the author could find;
    /// they are meant to be edited.
    static let starter = MarksRubric(name: "Presentation", criteria: [
        MarksCriterion(title: "Structure",
                       hint: "Did it open, go somewhere, and land?"),
        MarksCriterion(title: "Clarity",
                       hint: "Could you follow it without already knowing the subject?"),
        MarksCriterion(title: "Delivery",
                       hint: "Pace, volume, eye contact, filler."),
        MarksCriterion(title: "Evidence",
                       hint: "Were the claims backed by something?"),
        MarksCriterion(title: "Response",
                       hint: "How they handled questions and the unexpected."),
    ])

    /// True when two rubrics are asking the same questions, which is the only
    /// case where comparing two students' scores means anything.
    ///
    /// By the criteria's TITLES rather than their ids: a teacher who retypes a
    /// rubric rather than editing it has still made the same rubric, and an
    /// id comparison would quietly refuse to compare a whole term's work.
    func asksTheSameAs(_ other: MarksRubric) -> Bool {
        criteria.map(\.title) == other.criteria.map(\.title)
    }
}

/// One criterion's mark on one presentation.
struct MarksScore: Codable, Identifiable, Hashable {
    var criterionID: UUID
    /// nil while the evaluator has not marked this line yet - which is a real
    /// state and not a zero. A zero is a judgement; an unmarked line is not.
    var score: Int?
    var comment: String = ""
    var id: UUID { criterionID }
}

/// The rubric a presentation was marked on, with its marks. One `rubric.json`
/// per presentation folder.
struct MarksScoring: Codable {
    var v: Int = MarksScoring.schemaVersion
    var rubric: MarksRubric
    var scores: [MarksScore]
    var markedAt: Date?

    static let schemaVersion = 1
    static let fileName = "rubric.json"

    init(rubric: MarksRubric) {
        self.rubric = rubric
        self.scores = rubric.criteria.map { MarksScore(criterionID: $0.id, score: nil) }
        self.markedAt = nil
    }

    // MARK: Reading the marks

    func score(for criterion: MarksCriterion) -> MarksScore {
        scores.first { $0.criterionID == criterion.id }
            ?? MarksScore(criterionID: criterion.id, score: nil)
    }

    mutating func set(_ value: Int?, for criterion: MarksCriterion) {
        if let index = scores.firstIndex(where: { $0.criterionID == criterion.id }) {
            scores[index].score = value
        } else {
            scores.append(MarksScore(criterionID: criterion.id, score: value))
        }
        markedAt = Date()
    }

    mutating func setComment(_ text: String, for criterion: MarksCriterion) {
        if let index = scores.firstIndex(where: { $0.criterionID == criterion.id }) {
            scores[index].comment = text
        } else {
            scores.append(MarksScore(criterionID: criterion.id, score: nil, comment: text))
        }
    }

    /// Marked lines only. A half-filled rubric reports the half it has rather
    /// than pretending the blanks were zeros.
    var awarded: Int { scores.compactMap(\.score).reduce(0, +) }

    var availableOnMarkedLines: Int {
        rubric.criteria.filter { criterion in
            score(for: criterion).score != nil
        }.map(\.maxScore).reduce(0, +)
    }

    var isComplete: Bool {
        rubric.criteria.allSatisfy { score(for: $0).score != nil }
    }

    var markedCount: Int { scores.compactMap(\.score).count }

    /// 0...1 over the lines that were actually marked, or nil when none were.
    /// Used by the cohort pass, which cannot compare totals across rubrics of
    /// different lengths.
    var fraction: Double? {
        let available = availableOnMarkedLines
        guard available > 0 else { return nil }
        return Double(awarded) / Double(available)
    }

    /// "18/25", or "18/20 · 5 of 5 marked" when the rubric is half done.
    var totalLabel: String {
        guard markedCount > 0 else { return "not marked" }
        return "\(awarded)/\(availableOnMarkedLines)"
    }

    // MARK: Disk

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

    static func load(in folder: URL) -> MarksScoring? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        return try? decoder.decode(MarksScoring.self, from: data)
    }

    @discardableResult
    func save(in folder: URL) -> Bool {
        guard let data = try? Self.encoder.encode(self) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: Self.url(in: folder), options: .atomic)) != nil
    }
}

/// The rubric a new presentation starts from: whatever was used last.
enum MarksRubricStore {
    private static let key = "marksDefaultRubric"

    static func current(_ defaults: UserDefaults = .standard) -> MarksRubric {
        guard let data = defaults.data(forKey: key),
              let rubric = try? JSONDecoder().decode(MarksRubric.self, from: data) else {
            return .starter
        }
        return rubric
    }

    static func save(_ rubric: MarksRubric, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(rubric) else { return }
        defaults.set(data, forKey: key)
    }
}
