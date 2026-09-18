//
//  ScreenroomAnalyst.swift
//  Greenroom
//
//  The second pass: reads what the evaluator wrote and turns it into
//  something the speaker can be handed.
//
//  **It reads the notes, not the video.** That is approach C's idea from
//  docs/marks-evaluation-plan.md, taken into approach A as the plan
//  recommended, and it is the cheapest good idea in the whole design. A pass
//  over twelve students' notes is a few hundred words of text; a pass over
//  twelve students' video is a batch job with a bill attached. It also happens
//  to be the pass with the higher ceiling: the notes contain the one thing no
//  amount of footage analysis recovers - a human being in the room deciding
//  what mattered.
//
//  On-device, through the same FoundationModels framework Cues uses, for the
//  same reasons: no key to configure, no bill, and nothing about a student's
//  performance leaving the Mac. The framework is weak-linked and macOS 26
//  only, so every use sits behind `#available`.
//
//  **When the model is not there, the pass still runs.** Apple Intelligence
//  is off on most Macs and absent from all of them before macOS 26, and a
//  report that simply fails on those machines would make the whole feature
//  conditional on a setting the teacher may not control. So there are two
//  engines, and the analysis records which one wrote it. The counted engine
//  claims nothing it cannot show: it reports what is in the notes, not what
//  the notes mean.
//
//  One lesson carried over from Cues, at the cost of a paragraph: the
//  instructions below contain NO worked examples. The first version of the
//  Cues prompt illustrated a category with two real product names, and the
//  model then emitted those two names 26 times across a class that never
//  mentioned either. A small model treats a concrete example as a candidate
//  answer. Everything here is described by shape, and the rule for having
//  nothing to say is stated outright.
//
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - What the model is asked to produce

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedFeedback {
    @Guide(description: "Two or three sentences written TO the speaker, in the second person, summing up how the presentation went according to the notes. Plain and specific. Never encouraging for its own sake.")
    var summary: String

    @Guide(description: "Things the notes say went well, one short sentence each, in the second person. Only what the notes actually record. Empty if the notes record nothing good.", .maximumCount(4))
    var strengths: [String]

    @Guide(description: "Things the notes say to work on, one short sentence each, in the second person, each one actionable next time. Only what the notes actually record.", .maximumCount(4))
    var workOn: [String]

    @Guide(description: "Things true of the notes taken as a whole rather than of any single note: a theme that recurs, a stretch of the presentation nothing was written about, the same observation made more than once. Empty when there is no such pattern.", .maximumCount(3))
    var patterns: [String]

    @Guide(description: "One entry for every rubric line you were given, in the same order, with its title copied exactly.", .maximumCount(8))
    var marks: [GeneratedMark]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedMark {
    @Guide(description: "The rubric line's title, copied exactly as it was given to you.")
    var title: String
    @Guide(description: "The score for this line, within the range you were given.")
    var score: Int
    @Guide(description: "One line saying why this score rather than the one above or below it. Say what would have earned the higher mark. If the notes cannot tell you about this line, say so instead of guessing.")
    var reason: String
}
#endif

enum ScreenroomAnalyst {

    /// Whether the on-device model can run here, and why not when it cannot.
    /// Mirrors FoundationModelsDetector so Settings and this window say the
    /// same thing about the same Mac.
    static var modelAvailability: (available: Bool, reason: String?) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, nil)
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return (false, "Apple Intelligence is off in System Settings")
                case .deviceNotEligible:
                    return (false, "this Mac cannot run Apple Intelligence")
                case .modelNotReady:
                    return (false, "the model is still downloading or preparing")
                @unknown default:
                    return (false, "not available")
                }
            }
        }
        return (false, "Screenroom needs macOS 26 for the written pass")
        #else
        return (false, "this build has no on-device model")
        #endif
    }

    static let writtenEngine = "Apple Intelligence (on-device)"
    static let countedEngine = "Counted from the notes"

    // MARK: The pass

    /// Reads the notes and produces the analysis.
    ///
    /// `consistency` comes in already computed rather than being worked out
    /// here: it is arithmetic over the whole cohort and has nothing to do with
    /// which engine writes the prose. See ScreenroomCohort for why those findings
    /// are deliberately kept away from the model.
    static func analyse(notes: [ScreenroomNote],
                        scoring: ScreenroomScoring?,
                        presenter: String,
                        consistency: [String]) async -> ScreenroomAnalysis {
        guard !notes.isEmpty else {
            return ScreenroomAnalysis(
                engine: countedEngine,
                summary: "No notes were taken during this presentation, so there is nothing to report back.",
                consistency: consistency)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), modelAvailability.available {
            if let written = await writtenPass(notes: notes, scoring: scoring,
                                               presenter: presenter,
                                               consistency: consistency) {
                return written
            }
            // Fall through. A model that refused or errored is not a reason to
            // hand back nothing; the counted pass is always available.
        }
        #endif

        return countedPass(notes: notes, scoring: scoring, consistency: consistency)
    }

    // MARK: The written pass

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static let instructions = """
    You are helping a teacher turn their own notes about a student's presentation into feedback for that \
    student. The notes were typed live, while it was happening, so they are terse and in no particular \
    order of importance. Each one is stamped with how far into the presentation it was written. \
    Write only from the notes. Every sentence you produce must be traceable to something a note actually \
    says. Never invent an incident, never add advice the notes do not support, and never soften or \
    contradict a note because it is unkind. \
    Write to the student, as "you". Be plain and specific; a general sentence that would fit any \
    presentation is worse than no sentence. Do not praise for the sake of balance: if the notes record \
    nothing that went well, return nothing for strengths, and the same for things to work on. \
    A note is an observation, not a verdict. Where a note describes something neutral, treat it as \
    context rather than forcing it into a strength or a fault. \
    Use the timestamps to tell when in the presentation something happened, and to notice a stretch the \
    notes say nothing about. Do not quote a timestamp as a number in your sentences; say it in words.
    """

    @available(macOS 26.0, *)
    private static func writtenPass(notes: [ScreenroomNote],
                                    scoring: ScreenroomScoring?,
                                    presenter: String,
                                    consistency: [String]) async -> ScreenroomAnalysis? {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt(notes: notes, scoring: scoring, presenter: presenter),
                generating: GeneratedFeedback.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 700))
            let content = response.content
            let summary = content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return nil }
            return ScreenroomAnalysis(
                engine: writtenEngine,
                summary: summary,
                strengths: clean(content.strengths),
                workOn: clean(content.workOn),
                patterns: clean(content.patterns),
                marks: content.marks.compactMap { mark in
                    let title = mark.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    return ScreenroomAnalysis.Mark(
                        title: title, score: mark.score,
                        reason: mark.reason.trimmingCharacters(in: .whitespacesAndNewlines))
                },
                consistency: consistency)
        } catch {
            // Guardrail refusals, context overflows and everything else land
            // in the same place: the counted pass. A student's feedback is not
            // worth a retry loop that might produce something worse.
            return nil
        }
    }

    @available(macOS 26.0, *)
    private static func prompt(notes: [ScreenroomNote], scoring: ScreenroomScoring?, presenter: String) -> String {
        var lines: [String] = []
        lines.append("Student: \(presenter.isEmpty ? "the speaker" : presenter)")
        if let last = notes.map(\.atMs).max() {
            lines.append("Notes were taken across the first \(last / 60000) minutes and \((last % 60000) / 1000) seconds of the presentation.")
        }
        lines.append("")
        lines.append("The teacher's notes, in order:")
        for note in notes {
            lines.append("- at \(note.offsetLabel): \(note.text)")
        }
        if let scoring {
            lines.append("")
            lines.append("Mark every one of these lines. Copy each title exactly, score within its range, and give one line of reasoning:")
            for criterion in scoring.rubric.criteria {
                lines.append("- \(criterion.title) (0 to \(criterion.maxScore))"
                             + (criterion.hint.isEmpty ? "" : " \u{2014} \(criterion.hint)"))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func clean(_ items: [String]) -> [String] {
        items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 2 }
    }
    #endif

    // MARK: The counted pass

    /// What can be said about the notes without reading them.
    ///
    /// Every sentence here is arithmetic over timestamps and rubric numbers,
    /// and it says so. It exists because a Mac without Apple Intelligence
    /// should still produce a report, and because a teacher deciding whether
    /// to trust the written pass benefits from having seen what the honest
    /// floor looks like.
    static func countedPass(notes: [ScreenroomNote],
                            scoring: ScreenroomScoring?,
                            consistency: [String]) -> ScreenroomAnalysis {
        let span = notes.map(\.atMs).max() ?? 0
        var patterns: [String] = []

        patterns.append("\(notes.count) \(notes.count == 1 ? "note was" : "notes were") taken, across \(minutesLabel(span)) of the presentation.")

        if let gap = longestGap(in: notes), gap.lengthMs >= 120_000 {
            patterns.append("The longest stretch with nothing written was \(minutesLabel(gap.lengthMs)), from \(offsetLabel(gap.startMs)) to \(offsetLabel(gap.endMs)).")
        }
        if notes.count >= 4 {
            let half = span / 2
            let early = notes.filter { $0.atMs <= half }.count
            let late = notes.count - early
            if early >= 2 * max(late, 1) {
                patterns.append("Most of the notes land in the first half, which usually means the opening drew more attention than the close.")
            } else if late >= 2 * max(early, 1) {
                patterns.append("Most of the notes land in the second half.")
            }
        }

        var summary = "This report lists the notes taken during the presentation. "
        summary += "It was counted from the notes rather than written, so it describes what was recorded and does not interpret it"
        summary += scoring == nil ? "." : ", and the rubric is not marked: counting cannot judge."

        var workOn: [String] = []
        if let scoring, scoring.markedCount > 0 {
            let lines = scoring.rubric.criteria.compactMap { criterion -> (String, Double)? in
                guard let value = scoring.score(for: criterion).score, criterion.maxScore > 0 else { return nil }
                return (criterion.title, Double(value) / Double(criterion.maxScore))
            }
            if let weakest = lines.min(by: { $0.1 < $1.1 }), weakest.1 < 0.7 {
                workOn.append("\(weakest.0) was the lowest-scoring line on the rubric.")
            }
            if let strongest = lines.max(by: { $0.1 < $1.1 }), strongest.1 >= 0.8 {
                return ScreenroomAnalysis(engine: countedEngine, summary: summary,
                                     strengths: ["\(strongest.0) was the highest-scoring line on the rubric."],
                                     workOn: workOn, patterns: patterns, consistency: consistency)
            }
        }
        return ScreenroomAnalysis(engine: countedEngine, summary: summary,
                             workOn: workOn, patterns: patterns, consistency: consistency)
    }

    /// The longest run of presentation with no note in it, measured between
    /// consecutive notes. Not from zero to the first note: an evaluator
    /// settling in is not a silence worth reporting.
    static func longestGap(in notes: [ScreenroomNote]) -> (startMs: Int, endMs: Int, lengthMs: Int)? {
        let ordered = notes.map(\.atMs).sorted()
        guard ordered.count >= 2 else { return nil }
        var best: (Int, Int, Int)?
        for (a, b) in zip(ordered, ordered.dropFirst()) where best == nil || b - a > best!.2 {
            best = (a, b, b - a)
        }
        return best
    }

    private static func offsetLabel(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func minutesLabel(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 { return "\(minutes) \(minutes == 1 ? "minute" : "minutes")" }
        return "\(minutes)m \(remainder)s"
    }
}
