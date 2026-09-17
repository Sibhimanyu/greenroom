//
//  SessionSummary.swift
//  Greenroom
//
//  What the class was about, written by the Mac that recorded it.
//
//  The transcript is already saved beside the recording; it is just not
//  readable anywhere in the app, so the only way to see what a class covered
//  was to open a text file in Finder. This reads it, and asks Apple's on-device
//  model for a short account of it.
//
//  On-device, and it matters here more than anywhere else in the app. A class
//  transcript is children speaking. Cues already holds the line that only a
//  short search phrase ever leaves the Mac; sending a whole lesson to a cloud
//  model to be summarised would break that in the one place the stakes are
//  highest. SystemLanguageModel runs locally or this feature does not exist.
//
//  Cached to summary.md in the session's own folder. A summary costs seconds of
//  the Mac's attention, the transcript never changes once the class has ended,
//  and the teacher may open the same class many times.
//
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SessionSummary {

    /// One line per finalised sentence: `h:mm:ss<TAB>text`. Comment lines start
    /// with `#`.
    struct Line: Identifiable {
        let id = UUID()
        let stamp: String
        let text: String
    }

    static func transcriptURL(in folder: URL) -> URL {
        folder.appendingPathComponent("transcript.txt")
    }
    static func summaryURL(in folder: URL) -> URL {
        folder.appendingPathComponent("summary.md")
    }

    /// The transcript's spoken lines, comments and blanks dropped.
    static func lines(in folder: URL) -> [Line] {
        guard let raw = try? String(contentsOf: transcriptURL(in: folder), encoding: .utf8) else {
            return []
        }
        return raw.split(separator: "\n").compactMap { row -> Line? in
            guard !row.hasPrefix("#") else { return nil }
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return Line(stamp: parts[0], text: parts[1])
        }
    }

    /// The cached summary, if this class has been summarised before.
    static func cached(in folder: URL) -> String? {
        guard let text = try? String(contentsOf: summaryURL(in: folder), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Tidied on read too: summaries written before tidy existed are still
        // on disk, and a teacher should not have to regenerate one to lose a
        // dangling heading.
        let clean = tidy(text)
        return clean.isEmpty ? nil : clean
    }

    /// Why the button is unavailable, or nil when it can run.
    static var unavailableReason: String? {
        guard #available(macOS 26.0, *) else {
            return "Summaries need macOS 26. The transcript is all yours below."
        }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to summarise a class on this Mac."
        case .unavailable(.modelNotReady):
            return "Apple's language model is still downloading. Try again shortly."
        case .unavailable(.deviceNotEligible):
            return "This Mac cannot run Apple's on-device model."
        case .unavailable:
            return "Apple's on-device model is unavailable right now."
        @unknown default:
            return "Apple's on-device model is unavailable right now."
        }
        #else
        return "Summaries need macOS 26."
        #endif
    }

    /// Shape only, no examples.
    ///
    /// The same trap the Cues detector fell into twice applies here: a
    /// small model treats anything concrete in its instructions as a candidate
    /// answer, and product names put in as examples came back 26 times in one
    /// class. So this describes the SHAPE of the summary and never its content.
    private static let instructions = """
    You are given the transcript of one lesson, as timestamped lines. Write a short \
    account of it for the teacher who taught it, so they can remember what happened \
    without rereading the whole thing.

    Three parts, in this order and no other:
    A single sentence saying what the lesson was about.
    Then a handful of bullet points, each naming one thing that was covered, in the \
    order it came up.
    Then one line beginning "Follow up:" if anything was left unfinished or promised, \
    and nothing at all if there was not.

    The transcript is what an English speech model made of a bilingual classroom, so \
    parts of it are garbled or missing. Summarise only what is actually there. Never \
    invent a topic, a name, or an event that the lines do not contain, and if the \
    transcript is too thin to summarise, say exactly that in one sentence instead of \
    guessing. Do not mention the transcript's quality otherwise, and do not describe \
    your own output.
    """

    /// Notes taken from one part of a class. Bullets only, so the reduce pass
    /// that reads them back gets facts and not three competing preambles.
    private static let partInstructions = """
    You are given part of the transcript of one lesson, as timestamped lines. List what \
    was covered in this part, as a few short bullet points, in the order it came up.

    Write bullet points and nothing else: no heading, no introduction, no closing line.

    The transcript is what an English speech model made of a bilingual classroom, so \
    parts of it are garbled or missing. List only what is actually there. Never invent a \
    topic, a name, or an event that the lines do not contain. If this part contains \
    nothing worth noting, write nothing at all.
    """

    /// The same account as `instructions`, but written from notes.
    private static let reduceInstructions = """
    You are given notes taken from one lesson, in order. Write a short account of the \
    lesson for the teacher who taught it, so they can remember what happened without \
    rereading everything.

    Three parts, in this order and no other:
    A single sentence saying what the lesson was about.
    Then a handful of bullet points, each naming one thing that was covered, in the \
    order it came up.
    Then one line beginning "Follow up:" if anything was left unfinished or promised, \
    and nothing at all if there was not.

    Merge notes that repeat the same thing, and keep the whole lesson in view rather \
    than dwelling on its beginning. Never invent a topic, a name, or an event that the \
    notes do not contain. Do not mention the notes and do not describe your own output.
    """

    /// Characters of transcript per pass.
    ///
    /// Apple's on-device model holds roughly 4k tokens of input and output
    /// together. A real 40-minute class transcribes to about 22 KB, so it was
    /// never going to fit: the first version of this offered a single pass and
    /// told the teacher their class was "too long", which is the app refusing
    /// the only case that actually matters. ~4000 characters is near 1000
    /// tokens, leaving the instructions and the reply plenty of room.
    private static let chunkBudget = 4000

    /// Groups consecutive lines into passes of at most `budget` characters.
    static func chunk(_ spoken: [Line], budget: Int) -> [[Line]] {
        var parts: [[Line]] = []
        var current: [Line] = []
        var size = 0
        for line in spoken {
            let cost = line.stamp.count + line.text.count + 3
            // A single line longer than the budget still has to go somewhere.
            if !current.isEmpty, size + cost > budget {
                parts.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += cost
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func render(_ part: [Line]) -> String {
        part.map { "\($0.stamp)  \($0.text)" }.joined(separator: "\n")
    }

    /// Drops a "Follow up:" heading with nothing under it.
    ///
    /// The instructions say to write that line only when something was left
    /// unfinished, and the model mostly obeys - but a real class summarised on
    /// this Mac still ended "Lesson about numbers. * 15 and 15 * Dina Follow
    /// up:", a header promising a line that never came. Asking a small model
    /// again would not fix it reliably; deleting an empty heading is exact.
    static func tidy(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func bare(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_#-"))
                .trimmingCharacters(in: .whitespaces)
        }

        // A "Follow up" section that says there is nothing to follow up.
        //
        // The 413-line class produced "Follow-up:" then "There were no
        // unfinished or promised tasks." - the heading obeyed and its body
        // contradicted it. Instructions did not stop that; matching the shape
        // does.
        if let head = lines.lastIndex(where: {
            let l = bare($0).lowercased()
            return l.hasPrefix("follow up") || l.hasPrefix("follow-up")
        }) {
            let inline = bare(lines[head]).drop(while: { $0 != ":" }).dropFirst()
            let body = ([String(inline)] + lines[(head + 1)...].map(bare))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".*_ "))
                .lowercased()
            let empty = body.isEmpty
                || ["none", "nothing", "n/a", "na"].contains(body)
                || body.hasPrefix("there were no") || body.hasPrefix("there are no")
                || body.hasPrefix("there was no") || body.hasPrefix("there is no")
                || body.hasPrefix("nothing was") || body.hasPrefix("nothing is")
                || body.hasPrefix("no unfinished") || body.hasPrefix("no follow")
                || body.hasPrefix("none were") || body.hasPrefix("no tasks")
            if empty { lines.removeSubrange(head...) }
        }

        // Scaffolding headings. The instructions ask for three parts and no
        // other, but the model still labels them; a teacher wants the account,
        // not a document structure.
        let scaffolding: Set<String> = [
            "lesson summary", "summary", "key points", "key point",
            "main points", "topics covered", "overview", "lesson overview"
        ]
        lines.removeAll { line in
            let l = bare(line).lowercased()
            guard l.hasSuffix(":") else { return false }
            return scaffolding.contains(String(l.dropLast()).trimmingCharacters(in: .whitespaces))
        }

        // Removing a heading leaves the blank line that followed it, so a gap
        // opens where the label used to be.
        var collapsed: [String] = []
        for line in lines {
            let isBlank = bare(line).isEmpty
            if isBlank, collapsed.last.map({ bare($0).isEmpty }) == true { continue }
            collapsed.append(line)
        }
        lines = collapsed

        while let last = lines.last, bare(last).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a summarise attempt produced.
    enum Outcome {
        case summary(String)
        /// Shown in place of the summary. The panel has room to say what went
        /// wrong, so failures are sentences rather than error codes.
        case problem(String)
    }

    /// One model call's result. `tooLong` is recoverable by splitting, so it
    /// is a value here rather than a message shown to the teacher.
    private enum Reply {
        case ok(String)
        case tooLong
        case failed(String)
    }

    @available(macOS 26.0, *)
    private static func ask(_ instructions: String, _ prompt: String,
                            limit: Int) async -> Reply {
        #if canImport(FoundationModels)
        // A fresh session per call: these passes are independent, and reusing
        // one would accumulate the whole class in its context, which is the
        // problem being solved.
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: limit))
            return .ok(response.content.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                return .tooLong
            case .guardrailViolation, .refusal:
                return .failed("Apple's model declined to summarise this class.")
            default:
                return .failed("The summary failed: \(error.localizedDescription)")
            }
        } catch {
            return .failed("The summary failed: \(error.localizedDescription)")
        }
        #else
        return .failed("Summaries need macOS 26.")
        #endif
    }

    /// Writes summary.md and returns it.
    ///
    /// `progress` is called as each pass starts, because a long class is
    /// several model calls and a spinner alone would look hung.
    @available(macOS 26.0, *)
    static func generate(for folder: URL,
                         progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        #if canImport(FoundationModels)
        let spoken = lines(in: folder)
        guard !spoken.isEmpty else {
            return .problem("Nothing was transcribed for this class, so there is nothing to summarise.")
        }

        var budget = chunkBudget
        // Three attempts, halving the pass size each time. A budget that turns
        // out to be too big for this model shows up as .tooLong, not as a
        // wrong answer, so it can be retried honestly.
        for _ in 0..<3 {
            let parts = chunk(spoken, budget: budget)

            // A short class is one pass, which is both faster and better than
            // map-reduce: nothing gets summarised twice.
            if parts.count == 1 {
                progress("Reading the class\u{2026}")
                switch await ask(instructions, "Transcript:\n\(render(spoken))", limit: 700) {
                case .ok(let text):   return finish(text, in: folder)
                case .failed(let m):  return .problem(m)
                case .tooLong:        budget /= 2; continue
                }
            }

            // Map: notes per part.
            var notes: [String] = []
            var overflowed = false
            for (index, part) in parts.enumerated() {
                progress("Reading part \(index + 1) of \(parts.count)\u{2026}")
                switch await ask(partInstructions, "Transcript:\n\(render(part))", limit: 300) {
                case .ok(let text):
                    if !text.isEmpty { notes.append(text) }
                case .failed(let m):
                    return .problem(m)
                case .tooLong:
                    overflowed = true
                }
                if overflowed { break }
                if Task.isCancelled { return .problem("Summary cancelled.") }
            }
            if overflowed { budget /= 2; continue }
            guard !notes.isEmpty else {
                return .problem("This class transcribed too thinly to summarise.")
            }

            // Reduce: notes into one account, folding repeatedly if the notes
            // are themselves too much for one pass.
            progress("Writing the summary\u{2026}")
            var joined = notes.joined(separator: "\n")
            var rounds = 0
            while true {
                switch await ask(reduceInstructions, "Notes:\n\(joined)", limit: 700) {
                case .ok(let text):
                    return finish(text, in: folder)
                case .failed(let m):
                    return .problem(m)
                case .tooLong:
                    rounds += 1
                    guard rounds <= 3 else { return .problem("This class is too long to summarise on this Mac.") }
                    progress("Condensing the notes\u{2026}")
                    // Fold the notes in halves until they fit.
                    let folded = chunk(joined.split(separator: "\n").map { Line(stamp: "", text: String($0)) },
                                       budget: budget)
                    var next: [String] = []
                    for group in folded {
                        switch await ask(partInstructions,
                                         "Transcript:\n" + group.map(\.text).joined(separator: "\n"),
                                         limit: 300) {
                        case .ok(let text): if !text.isEmpty { next.append(text) }
                        case .failed(let m): return .problem(m)
                        case .tooLong: return .problem("This class is too long to summarise on this Mac.")
                        }
                    }
                    guard !next.isEmpty else { return .problem("This class is too long to summarise on this Mac.") }
                    joined = next.joined(separator: "\n")
                }
            }
        }
        return .problem("This class is too long to summarise on this Mac.")
        #else
        return .problem("Summaries need macOS 26.")
        #endif
    }

    private static func finish(_ raw: String, in folder: URL) -> Outcome {
        let text = tidy(raw)
        guard !text.isEmpty else { return .problem("The model returned nothing.") }
        try? Data(text.utf8).write(to: summaryURL(in: folder))
        return .summary(text)
    }
}
