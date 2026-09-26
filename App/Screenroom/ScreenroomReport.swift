//
//  ScreenroomReport.swift
//  Greenroom
//
//  The thing the speaker is actually handed.
//
//  Markdown, written into the presentation's folder as report.md. Not PDF,
//  not HTML, not a window: a student is going to be sent this, on whatever
//  they read things on, and they may want to answer it. Markdown opens
//  everywhere, prints from anywhere, pastes into an email without losing its
//  headings, and can be read with `cat` in ten years.
//
//  **Two audiences, and they do not get the same document.** The cohort
//  consistency findings are about the MARKER, not the student - "marks
//  drifted downward through the session" is a fact about a Friday afternoon,
//  and putting it in the student's copy invites an argument about someone
//  else's grade rather than a conversation about their own presentation. The
//  teacher keeps those. They exist so that when a grade IS questioned, the
//  person answering has already looked.
//
import Foundation

enum ScreenroomReport {

    enum Audience {
        /// What the student is handed. Their presentation, their notes, their
        /// marks, and nothing about anybody else's.
        case speaker
        /// What the teacher keeps. Everything, including how this marking sat
        /// against the rest of the cohort.
        case evaluator
    }

    static let fileName = "report.md"

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    /// Compiles the whole report.
    ///
    /// Everything is optional except the notes, because everything except the
    /// notes is optional in real use: a teacher who watched, typed, and never
    /// opened the rubric should still be able to send something.
    static func markdown(presenter: String,
                         presentedAt: Date,
                         notes: [ScreenroomNote],
                         scoring: ScreenroomScoring?,
                         analysis: ScreenroomAnalysis?,
                         metrics: ScreenroomSpeechMetrics? = nil,
                         presence: ScreenroomPresence? = nil,
                         for audience: Audience) -> String {
        var out: [String] = []

        let name = presenter.trimmingCharacters(in: .whitespaces)
        // "Presentation", not "Screen". Greens and Screens are the app's own
        // words for its two halves and they are useful inside the app; this
        // document goes to a student who has never seen Greenroom, and a
        // heading reading "# Screen" would mean nothing to them.
        out.append("# \(name.isEmpty ? "Presentation" : name)")
        out.append("")
        out.append(presentedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))
        out.append("")

        if let analysis {
            // The verdict first, as the report window shows it. It was left
            // out of the file the student is handed, so the one line the
            // report leads with never reached them.
            if let headline = analysis.headline?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty {
                out.append("## \(escape(headline))")
                out.append("")
            }
            if !analysis.summary.isEmpty {
                out.append(analysis.summary)
                out.append("")
            }
            out.append(contentsOf: bulletSection("What went well", analysis.strengths))
            out.append(contentsOf: bulletSection("What to work on", analysis.workOn))
            out.append(contentsOf: bulletSection("Across the whole presentation", analysis.patterns))
        }

        if let scoring, scoring.markedCount > 0 {
            out.append("## Marks")
            out.append("")
            out.append("| | Score | |")
            out.append("|---|---|---|")
            for criterion in scoring.rubric.criteria {
                let mark = scoring.score(for: criterion)
                let value = mark.score.map { "\($0)/\(criterion.maxScore)" } ?? "\u{2014}"
                out.append("| **\(escape(criterion.title))** | \(value) | \(escape(mark.comment)) |")
            }
            out.append("| **Total** | **\(scoring.totalLabel)** | |")
            out.append("")
        }

        // The measured half, kept apart from the written half above and
        // labelled as counted. A student who disagrees with a sentence can
        // argue about it; a student who disagrees with a count can go and
        // look at the timestamp.
        if let metrics, metrics.wordCount > 0 {
            out.append("## How you delivered it")
            out.append("")
            out.append("Counted from the recording, not written by a model.")
            out.append("")
            out.append("| | |")
            out.append("|---|---|")
            out.append("| Pace | \(Int(metrics.wordsPerMinute.rounded())) words a minute |")
            if metrics.verbatim {
                out.append("| Filler words | \(metrics.fillerCount) (\(String(format: "%.1f", metrics.fillersPerMinute)) a minute) |")
                out.append("| Hedges and softeners | \(metrics.hedgeCount) |")
            }
            if metrics.wordsPerRun > 0 {
                out.append("| Sentence length | \(Int(metrics.wordsPerRun.rounded())) words on average |")
            }
            if metrics.vocabulary > 0 {
                out.append("| Vocabulary variety | \(Int((metrics.vocabulary * 100).rounded()))% |")
            }
            out.append("| Talking | \(Int((metrics.talkRatio * 100).rounded()))% of the time |")
            if let presence, presence.sampleCount > 0 {
                out.append("| Facing the room | \(Int((presence.facingRatio * 100).rounded()))% of frames with a face in them |")
                if let ratio = presence.gestureRatio {
                    out.append("| Hands up and moving | \(Int((ratio * 100).rounded()))% of frames |")
                }
            }
            out.append("")
            if metrics.verbatim, !metrics.fillers.isEmpty {
                out.append("Most-used fillers: " + metrics.fillers.prefix(5)
                    .map { "**\(escape($0.word))** \($0.count)\u{00D7}" }.joined(separator: ", ") + ".")
                out.append("")
            }
            if presence != nil {
                out.append("_\"Facing the room\" is the angle of the head, sampled every two seconds. It is not eye contact: nothing here measured where your eyes were pointed._")
                out.append("")
            }
        }

        if !notes.isEmpty {
            out.append("## Notes taken during the presentation")
            out.append("")
            out.append("Each one is timed from the start of the recording.")
            out.append("")
            for note in notes {
                out.append("- `\(note.offsetLabel)` \(escape(note.text))")
            }
            out.append("")
        }

        if audience == .evaluator, let analysis, !analysis.consistency.isEmpty {
            out.append("## For the marker, not the speaker")
            out.append("")
            out.append("How this marking sat against the rest of the group. Arithmetic, not judgement.")
            out.append("")
            for finding in analysis.consistency {
                out.append("- \(escape(finding))")
            }
            out.append("")
        }

        out.append("---")
        out.append("")
        if let analysis {
            out.append("_Notes typed live during the presentation. The written sections came from \(escape(analysis.engine)), reading those notes and nothing else \u{2014} not the recording._")
        } else {
            out.append("_Notes typed live during the presentation._")
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    @discardableResult
    static func write(_ markdown: String, in folder: URL) -> URL? {
        let target = url(in: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? markdown.write(to: target, atomically: true, encoding: .utf8)) != nil else { return nil }
        return target
    }

    private static func bulletSection(_ title: String, _ items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        var out = ["## \(title)", ""]
        out.append(contentsOf: items.map { "- \(escape($0))" })
        out.append("")
        return out
    }

    /// A note is prose typed in a hurry, and a pipe or a backtick in it would
    /// otherwise break the table or open a code span that never closes.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "`", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
