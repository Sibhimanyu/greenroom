//
//  ScreenroomRubric.swift
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
//  That snapshot is also what makes the cohort pass honest: ScreenroomCohort only
//  compares presentations whose criteria actually match, rather than assuming
//  that two things both called "Structure" meant the same thing.
//
import Foundation

/// One line of a rubric: a thing being judged, and the range it is judged on.
struct ScreenroomCriterion: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    /// One line telling the evaluator what this criterion is actually asking,
    /// shown under the title. The plan's premise 4 again: a criterion whose
    /// meaning has to be remembered costs attention every time it is used.
    var hint: String = ""
    var maxScore: Int = 5
}

/// The criteria, as a set. Named so a teacher can keep more than one.
struct ScreenroomRubric: Codable, Hashable {
    var name: String
    var criteria: [ScreenroomCriterion]

    /// A starting point, not a recommendation.
    ///
    /// Five lines because a rubric long enough to be thorough is a rubric that
    /// does not get filled in while a student is still standing up. These are
    /// the ones that recur in every speaking rubric the author could find;
    /// they are meant to be edited.
    static let starter = ScreenroomRubric(name: "Presentation", criteria: [
        ScreenroomCriterion(title: "Structure",
                       hint: "Did it open, go somewhere, and land?"),
        ScreenroomCriterion(title: "Clarity",
                       hint: "Could you follow it without already knowing the subject?"),
        ScreenroomCriterion(title: "Delivery",
                       hint: "Pace, volume, eye contact, filler."),
        ScreenroomCriterion(title: "Evidence",
                       hint: "Were the claims backed by something?"),
        ScreenroomCriterion(title: "Response",
                       hint: "How they handled questions and the unexpected."),
    ])

    /// True when two rubrics are asking the same questions, which is the only
    /// case where comparing two students' scores means anything.
    ///
    /// By the criteria's TITLES rather than their ids: a teacher who retypes a
    /// rubric rather than editing it has still made the same rubric, and an
    /// id comparison would quietly refuse to compare a whole term's work.
    func asksTheSameAs(_ other: ScreenroomRubric) -> Bool {
        criteria.map(\.title) == other.criteria.map(\.title)
    }
}

/// One criterion's mark on one presentation.
struct ScreenroomScore: Codable, Identifiable, Hashable {
    var criterionID: UUID
    /// nil while nothing has marked this line yet - which is a real state and
    /// not a zero. A zero is a judgement; an unmarked line is not.
    var score: Int?
    /// WHY this mark. Written by whatever did the marking, in one line, and
    /// shown next to the number wherever the number is shown.
    ///
    /// A score with no reason is not feedback, it is an assertion. That was
    /// survivable while a teacher typed both and could remember their own
    /// reasoning; it is not survivable when something else does the marking
    /// and the student asks why.
    var comment: String = ""
    var id: UUID { criterionID }
}

/// The rubric a presentation was marked on, with its marks. One `rubric.json`
/// per presentation folder.
struct ScreenroomScoring: Codable {
    var v: Int = ScreenroomScoring.schemaVersion
    var rubric: ScreenroomRubric
    var scores: [ScreenroomScore]
    var markedAt: Date?

    /// What did the marking, in the words the report will print.
    ///
    /// The rubric used to be a form the teacher filled in. It is now an
    /// output of the analysis: the same pass that reads the notes and the
    /// transcript scores each line and says why. So the file has to record
    /// which engine's judgement it is holding - a mark from a large model
    /// reading a transcript and one from a teacher who was in the room are
    /// different kinds of claim.
    var markedBy: String?

    static let schemaVersion = 1
    static let fileName = "rubric.json"

    init(rubric: ScreenroomRubric) {
        self.rubric = rubric
        self.scores = rubric.criteria.map { ScreenroomScore(criterionID: $0.id, score: nil) }
        self.markedAt = nil
    }

    // MARK: Reading the marks

    func score(for criterion: ScreenroomCriterion) -> ScreenroomScore {
        scores.first { $0.criterionID == criterion.id }
            ?? ScreenroomScore(criterionID: criterion.id, score: nil)
    }

    /// Applies a whole set of marks at once, matched by criterion TITLE.
    ///
    /// By title rather than id, because whatever produced them was reading
    /// the rubric as words and has no idea what a UUID is.
    mutating func apply(_ marks: [(title: String, score: Int, reason: String)], by engine: String) {
        for mark in marks {
            guard let criterion = rubric.criteria.first(where: {
                $0.title.compare(mark.title, options: .caseInsensitive) == .orderedSame
            }) else { continue }
            // Clamped rather than trusted: a model asked for 1-5 will
            // occasionally answer 7, and a total that exceeds its own maximum
            // is the kind of thing a student notices first.
            let clamped = min(max(mark.score, 0), criterion.maxScore)
            set(clamped, for: criterion)
            setComment(mark.reason, for: criterion)
        }
        markedBy = engine
        markedAt = Date()
    }

    mutating func set(_ value: Int?, for criterion: ScreenroomCriterion) {
        if let index = scores.firstIndex(where: { $0.criterionID == criterion.id }) {
            scores[index].score = value
        } else {
            scores.append(ScreenroomScore(criterionID: criterion.id, score: value))
        }
        markedAt = Date()
    }

    mutating func setComment(_ text: String, for criterion: ScreenroomCriterion) {
        if let index = scores.firstIndex(where: { $0.criterionID == criterion.id }) {
            scores[index].comment = text
        } else {
            scores.append(ScreenroomScore(criterionID: criterion.id, score: nil, comment: text))
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

    static func load(in folder: URL) -> ScreenroomScoring? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        return try? decoder.decode(ScreenroomScoring.self, from: data)
    }

    @discardableResult
    func save(in folder: URL) -> Bool {
        guard let data = try? Self.encoder.encode(self) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: Self.url(in: folder), options: .atomic)) != nil
    }
}

/// The rubric a new presentation starts from: whatever was used last.
enum ScreenroomRubricStore {
    private static let key = "screenroomDefaultRubric"

    static func current(_ defaults: UserDefaults = .standard) -> ScreenroomRubric {
        guard let data = defaults.data(forKey: key),
              let rubric = try? JSONDecoder().decode(ScreenroomRubric.self, from: data) else {
            return .starter
        }
        return rubric
    }

    static func save(_ rubric: ScreenroomRubric, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(rubric) else { return }
        defaults.set(data, forKey: key)
    }
}
