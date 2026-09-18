//
//  ScreenroomCohort.swift
//  Greenroom
//
//  The thing a human evaluator genuinely cannot do for themselves.
//
//  Premise 3 of docs/marks-evaluation-plan.md: the obvious pitch for AI here
//  is "it finds filler words", which is table stakes and which a dozen
//  products already do. The valuable version is consistency. You grade twelve
//  students on a Friday afternoon and your standards drift. Student 3 was
//  marked harder than student 9 on the same rubric line, and you cannot see it
//  from inside your own afternoon. That is checkable, and it is the thing that
//  is defensible when a grade is questioned.
//
//  Deliberately NOT the language model's job. Every finding here is
//  arithmetic: means, spreads and one correlation. A model asked "were these
//  marked consistently?" would answer confidently either way and could not
//  show its working, which is exactly the wrong property for something whose
//  whole purpose is to be shown to a student who is arguing about a grade.
//  The model gets the prose; the numbers stay numbers.
//
import Foundation

struct ScreenroomCohort {

    /// One presentation's marks, reduced to what a comparison needs.
    struct Entry: Identifiable {
        let folder: URL
        let presenter: String
        let scoring: ScreenroomScoring
        /// When the marking happened - the axis the order effect is measured
        /// along. Falls back to the folder's own date when a rubric was never
        /// saved with a timestamp.
        let markedAt: Date
        var id: URL { folder }
    }

    /// One thing worth saying about how this cohort was marked.
    struct Finding: Identifiable, Hashable {
        enum Weight: String, Hashable {
            /// Worth acting on before the grades go out.
            case check
            /// True and worth knowing, but not a problem.
            case note
        }
        var id: String { headline }
        let weight: Weight
        let headline: String
        /// The arithmetic, in a sentence, so the finding can be argued with.
        let detail: String
    }

    /// How few presentations make a comparison meaningless.
    ///
    /// Three is the floor for saying anything at all about a spread, and five
    /// for the order effect - a correlation over four points is noise wearing
    /// a number. Stated here rather than buried so the thresholds can be
    /// argued with.
    static let minimumForSpread = 3
    static let minimumForOrderEffect = 5

    /// Everything worth saying about `subject` relative to the others marked
    /// on the same rubric.
    ///
    /// `others` may contain the subject; it is filtered out. Entries whose
    /// rubric asks different questions are dropped rather than coerced, and
    /// the count of what was actually comparable is reported, because "we
    /// compared you against two people" and "against eleven" are different
    /// claims.
    static func findings(for subject: Entry, among all: [Entry]) -> [Finding] {
        let peers = all.filter {
            $0.folder != subject.folder
                && $0.scoring.rubric.asksTheSameAs(subject.scoring.rubric)
                && $0.scoring.markedCount > 0
        }
        guard subject.scoring.markedCount > 0 else { return [] }
        guard peers.count + 1 >= minimumForSpread else {
            return [Finding(weight: .note,
                            headline: "Not enough marked presentations to check consistency yet",
                            detail: "\(peers.count + 1) marked on this rubric. A spread needs at least \(minimumForSpread).")]
        }

        var findings: [Finding] = []
        findings.append(contentsOf: overallHarshness(subject: subject, peers: peers))
        findings.append(contentsOf: perCriterion(subject: subject, peers: peers))
        findings.append(contentsOf: orderEffect(among: [subject] + peers))
        return findings
    }

    // MARK: Is this student marked unlike the rest?

    private static func overallHarshness(subject: Entry, peers: [Entry]) -> [Finding] {
        guard let mine = subject.scoring.fraction else { return [] }
        let theirs = peers.compactMap(\.scoring.fraction)
        guard theirs.count >= 2 else { return [] }
        let average = mean(theirs)
        let spread = standardDeviation(theirs)
        let delta = mine - average

        // One standard deviation, and never on a cohort whose spread is
        // essentially zero - if everybody scored the same, a point of
        // difference is not a finding, it is the only difference there is.
        // As in perCriterion: when the group agreed with itself, distance
        // from it is the whole signal, so a spread-relative test would go
        // quiet exactly when it should speak up.
        let unanimous = spread <= 0.01
        let notable = unanimous ? abs(delta) >= 0.10 : abs(delta) >= spread
        guard notable else {
            return [Finding(weight: .note,
                            headline: "Marked in line with the rest of the group",
                            detail: "\(percent(mine)) against a group average of \(percent(average)) over \(theirs.count + 1) presentations.")]
        }
        let direction = delta > 0 ? "above" : "below"
        let against = unanimous
            ? "every other presentation scored \(percent(average))"
            : "the group's own spread is \(percent(spread))"
        return [Finding(
            weight: .note,
            headline: "Marked well \(direction) the group",
            detail: "\(percent(mine)) against a group average of \(percent(average)), and \(against). Worth a second look only if nothing about the presentation explains it.")]
    }

    // MARK: Which line is out of step?

    private static func perCriterion(subject: Entry, peers: [Entry]) -> [Finding] {
        var findings: [Finding] = []
        for criterion in subject.scoring.rubric.criteria {
            guard let mine = subject.scoring.score(for: criterion).score else { continue }
            // Peers are matched by TITLE, since ids differ across snapshots of
            // the same rubric (see ScreenroomRubric.asksTheSameAs).
            let theirs: [Int] = peers.compactMap { peer in
                guard let match = peer.scoring.rubric.criteria.first(where: { $0.title == criterion.title })
                else { return nil }
                return peer.scoring.score(for: match).score
            }
            guard theirs.count >= 2 else { continue }
            let average = mean(theirs.map(Double.init))
            let spread = standardDeviation(theirs.map(Double.init))
            let delta = Double(mine) - average
            // Two rules, because a cohort that agreed with itself and a
            // cohort that did not are different situations.
            //
            // The first version had only the spread rule, and it got the
            // easier case exactly backwards: when every other student scored
            // the same mark on a line and this one is four points away, the
            // spread is zero, so a "more than 1.5 spreads" test suppressed
            // the single most obvious inconsistency a rubric can contain.
            // A unanimous group is the strongest baseline there is, not the
            // weakest, so it answers to a plain distance instead.
            let unanimous = spread <= 0.01
            let notable = unanimous ? abs(delta) >= 1
                                    : (abs(delta) >= 1.5 * spread && abs(delta) >= 1)
            guard notable else { continue }
            let against = unanimous
                ? "every other presentation scored \(oneDecimal(average)) on this line"
                : "the group's own spread on this line is \(oneDecimal(spread))"
            findings.append(Finding(
                weight: .check,
                headline: "\(criterion.title): \(mine) where the group averages \(oneDecimal(average))",
                detail: "That is \(oneDecimal(abs(delta))) \(delta > 0 ? "above" : "below") the average, and \(against). Either the presentation really was \(delta > 0 ? "that much better" : "that much weaker") on this line, or this one was marked to a different standard."))
        }
        return findings
    }

    // MARK: Did the afternoon drift?

    /// The classic, and the one nobody can see from inside: marks sliding up
    /// or down as the session goes on. Measured as the correlation between
    /// the order the presentations were marked in and what they scored.
    private static func orderEffect(among entries: [Entry]) -> [Finding] {
        let ordered = entries.sorted { $0.markedAt < $1.markedAt }
        let fractions = ordered.compactMap(\.scoring.fraction)
        guard fractions.count == ordered.count, fractions.count >= minimumForOrderEffect else { return [] }
        let positions = (0..<fractions.count).map(Double.init)
        guard let r = correlation(positions, fractions) else { return [] }
        guard abs(r) >= 0.5 else {
            return [Finding(weight: .note,
                            headline: "No drift across the marking order",
                            detail: "Scores show no trend from the first presentation marked to the last (r = \(twoDecimals(r)) over \(fractions.count)).")]
        }
        let direction = r < 0 ? "downward" : "upward"
        let first = fractions.first ?? 0
        let last = fractions.last ?? 0
        return [Finding(
            weight: .check,
            headline: "Marks drifted \(direction) through the session",
            detail: "Scores trend \(direction) with the order marked (r = \(twoDecimals(r)) over \(fractions.count) presentations; first \(percent(first)), last \(percent(last))). This is the drift a marker cannot see from inside an afternoon \u{2014} worth re-reading the first and last few against each other before the grades go out.")]
    }

    // MARK: Arithmetic

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Population standard deviation, not the sample one. The cohort IS the
    /// population here - these are all the presentations there were, not a
    /// sample drawn from more of them.
    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = mean(values)
        let variance = values.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(values.count)
        return variance.squareRoot()
    }

    /// Pearson's r, or nil when either side does not vary at all.
    static func correlation(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        let meanA = mean(a), meanB = mean(b)
        var top = 0.0, leftSum = 0.0, rightSum = 0.0
        for (x, y) in zip(a, b) {
            let dx = x - meanA, dy = y - meanB
            top += dx * dy
            leftSum += dx * dx
            rightSum += dy * dy
        }
        let bottom = (leftSum * rightSum).squareRoot()
        guard bottom > 0 else { return nil }
        return top / bottom
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func twoDecimals(_ value: Double) -> String { String(format: "%.2f", value) }
}
