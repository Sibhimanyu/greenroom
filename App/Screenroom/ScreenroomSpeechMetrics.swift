//
//  ScreenroomSpeechMetrics.swift
//  Greenroom
//
//  The countable half of what Yoodli-shaped products do.
//
//  Filler words, pace, pauses. All of it is arithmetic over a transcript with
//  word timings, so all of it stays here rather than going to a model - the
//  same rule ScreenroomCohort follows, and for the same reason:
//  a number that can be recomputed and argued with is worth more to a student
//  disputing feedback than a sentence that sounds confident.
//
//  It also makes the agent pass cheaper and better. An agent handed "you said
//  'basically' 34 times, 4.1 per minute, clustered in the last third" can
//  spend its attention on what that MEANS. An agent asked to count them will
//  spend its attention counting, and get it wrong.
//
import Foundation

/// One word, and when it was said.
struct ScreenroomSpokenWord: Codable, Hashable {
    var text: String
    var atMs: Int
    var durationMs: Int

    var endMs: Int { atMs + durationMs }
}

struct ScreenroomSpeechMetrics: Codable, Hashable {

    var v: Int = 3
    var wordCount: Int
    var durationMs: Int

    /// Which transcriber produced the words these numbers came from.
    var engine: String = "unknown"

    /// Whether that transcriber returns what was actually said.
    ///
    /// This is the most important field in the file. Apple's recogniser is
    /// built for dictation and smooths disfluencies away, so a filler count
    /// taken from it is not a rough figure - it is a measurement of how well
    /// the recogniser deleted the evidence, and it reads as a confident zero.
    /// Everything that prints a filler number checks this first.
    var verbatim: Bool = false

    /// Words per minute over the whole presentation.
    var wordsPerMinute: Double

    /// Pace in half-minute windows, so "they sped up when they got nervous"
    /// is visible rather than averaged away.
    var paceWindow: [PaceWindow] = []

    var fillers: [Filler] = []

    /// Zero when the transcript was not verbatim, whatever the array holds.
    /// The count is what gets printed and compared, so the guard belongs on
    /// it rather than on each of its readers remembering.
    var fillerCount: Int { verbatim ? fillers.reduce(0) { $0 + $1.count } : 0 }
    var fillersPerMinute: Double

    var pauses: [Pause] = []

    /// Speaking time over total time. A presentation is not a recording of
    /// continuous talking, and the difference is where the thinking was.
    var talkRatio: Double

    // MARK: The rest of what a speech tool reports
    //
    // Everything below arrived with schema 3 and every one of them has a
    // default, so a speech.json written in September still decodes in June.
    // They are all arithmetic over the same word list, for the same reason
    // the fillers are: a student disputing "you hedge a lot" deserves the
    // list of hedges and their timestamps, not a model's impression.

    /// Softeners - "I think", "maybe", "just". Same shape as a filler
    /// because it is the same kind of claim: a word, how often, and where.
    var hedges: [Filler] = []

    /// Words a second reader might want to look at. Deliberately a short,
    /// boring list; see `carefulWords`.
    var careful: [Filler] = []

    /// How many different words were used, and how varied the vocabulary
    /// stayed. `vocabulary` is a moving-window type-token ratio, so it does
    /// not simply fall as the talk gets longer the way a plain unique/total
    /// does - a twenty-minute talk is not less varied than a two-minute one
    /// by arithmetic alone.
    var uniqueWords: Int = 0
    var vocabulary: Double = 0

    /// The content words leaned on most, with their counts. Stop words are
    /// dropped; "the" being the most used word is not a finding.
    var repeated: [Filler] = []

    /// Runs of speech bounded by a breath. Everything about sentence length,
    /// sentence openers and unbroken stretches is measured off these, since
    /// a verbatim transcript has no punctuation to measure off instead.
    var runs: [Run] = []

    /// Average words per run. The concision number: long runs are where a
    /// listener loses the thread.
    var wordsPerRun: Double = 0

    /// The longest stretch with no breath in it, and where it started.
    var longestRunMs: Int = 0
    var longestRunStartMs: Int = 0

    /// How each run opened, counted. "You started eleven of forty sentences
    /// with 'so'" is the kind of thing nobody hears themselves do.
    var starters: [Filler] = []

    var hedgeCount: Int { verbatim ? hedges.reduce(0) { $0 + $1.count } : 0 }
    var hedgesPerMinute: Double {
        let minutes = max(0.001, Double(durationMs) / 60_000)
        return Double(hedgeCount) / minutes
    }

    struct Run: Codable, Hashable, Identifiable {
        var startMs: Int
        var endMs: Int
        var words: Int
        /// Lowercased, punctuation stripped. Empty if the run had no words.
        var opener: String
        var id: Int { startMs }
        var lengthMs: Int { endMs - startMs }
    }

    struct PaceWindow: Codable, Hashable {
        var startMs: Int
        var words: Int
        var wordsPerMinute: Double
    }

    struct Filler: Codable, Hashable, Identifiable {
        var word: String
        var count: Int
        /// Where each one was said, so a card can point at them and a clip
        /// can be cut to one.
        var atMs: [Int]
        var id: String { word }
    }

    struct Pause: Codable, Hashable, Identifiable {
        var startMs: Int
        var lengthMs: Int
        var id: Int { startMs }
    }

    static let fileName = "speech.json"

    // MARK: What counts as a filler

    /// The list, stated openly so it can be argued with.
    ///
    /// Two kinds here. The first six are fillers in any English. The rest are
    /// the ones that actually turn up in the classroom this was built for -
    /// Indian English has its own set, and a filler list that only catches
    /// "um" would report a fluent-sounding speaker as having no crutch at all
    /// while they say "actually" every fifteen seconds.
    ///
    /// Deliberately NOT including "so" on its own. It opens a sentence
    /// legitimately far too often, and flagging it produces a number a
    /// student will correctly ignore, which teaches them to ignore the rest.
    static let fillerWords: Set<String> = [
        "um", "uh", "er", "erm", "hmm", "mm",
        "like", "actually", "basically", "literally",
        "right", "yeah", "okay",
    ]

    /// Two-word fillers, checked before the single words so "you know" is not
    /// counted as nothing and "kind of" is not counted as "of".
    static let fillerPhrases: [[String]] = [
        ["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"],
        ["and", "all"], ["or", "something"],
    ]

    /// A silence worth naming. Below this, it is breathing and punctuation.
    static let pauseMs = 2_000

    /// Where one run of speech ends and the next begins. Not a pause in the
    /// reportable sense - it is the gap you take to end a thought.
    static let breathMs = 600

    /// The pace a room follows comfortably, in words per minute.
    ///
    /// Not a rule. It is the band conversational English sits in, and it is
    /// drawn on the pace chart as shading rather than printed as a verdict,
    /// because what counts as too fast depends on the subject, the room and
    /// how much English the audience has.
    static let comfortablePace: ClosedRange<Double> = 115...180

    /// Hedges and softeners. The thing they have in common is that removing
    /// them makes the sentence more certain without changing what it claims.
    ///
    /// "just" is here knowing it will sometimes be wrong. It is the single
    /// most common confidence leak in a student presentation - "I just wanted
    /// to show" - and the report lists every instance with its timestamp, so
    /// a wrong one costs a glance rather than a grade.
    static let hedgeWords: Set<String> = [
        "maybe", "perhaps", "probably", "possibly", "somewhat",
        "slightly", "hopefully", "just", "apparently", "presumably",
    ]

    static let hedgePhrases: [[String]] = [
        ["i", "think"], ["i", "guess"], ["i", "believe"], ["i", "feel"],
        ["a", "bit"], ["a", "little"], ["not", "sure"], ["pretty", "much"],
        ["or", "whatever"], ["more", "less"],
    ]

    /// Words worth a second look before a room of thirty.
    ///
    /// Short on purpose. A long list of this kind produces a page of flags a
    /// teacher learns to scroll past, which costs the few that mattered. The
    /// report never calls these mistakes; it says they are here and lets the
    /// person who was in the room decide.
    static let carefulWords: Set<String> = [
        "manpower", "chairman", "chairmen", "mankind",
        "lame", "crazy", "insane", "dumb",
    ]

    static let carefulPhrases: [[String]] = [
        ["you", "guys"], ["man", "hours"],
    ]

    /// Not findings. Dropped before counting which words were leaned on.
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "of", "to", "in", "on",
        "at", "for", "with", "by", "from", "as", "is", "are", "was", "were",
        "be", "been", "being", "am", "do", "does", "did", "have", "has",
        "had", "i", "you", "he", "she", "it", "we", "they", "me", "him",
        "her", "us", "them", "my", "your", "his", "its", "our", "their",
        "this", "that", "these", "those", "there", "here", "what", "which",
        "who", "when", "where", "how", "why", "not", "no", "yes", "so",
        "can", "will", "would", "could", "should", "may", "might", "must",
        "about", "into", "over", "then", "than", "too", "very", "also",
        "all", "any", "some", "one", "two", "up", "out", "down", "s", "t",
    ]

    // MARK: The pass

    static func measure(words: [ScreenroomSpokenWord], durationMs: Int,
                        engine: String = "unknown", verbatim: Bool = false) -> ScreenroomSpeechMetrics {
        let ordered = words.sorted { $0.atMs < $1.atMs }
        let minutes = max(0.001, Double(durationMs) / 60_000)

        // Pace, in thirty-second windows.
        var windows: [PaceWindow] = []
        if durationMs > 0 {
            let windowMs = 30_000
            var start = 0
            while start < durationMs {
                let end = start + windowMs
                let inWindow = ordered.filter { $0.atMs >= start && $0.atMs < end }
                let span = Double(min(end, durationMs) - start) / 60_000
                windows.append(PaceWindow(
                    startMs: start,
                    words: inWindow.count,
                    wordsPerMinute: span > 0 ? Double(inWindow.count) / span : 0))
                start = end
            }
        }

        let normalised = ordered.map { normalise($0.text) }

        // Fillers, then hedges, then the careful list. Each pass claims the
        // word positions it matched so the three counts never double-count
        // the same word - "kind of" is a filler and stays one; it is not
        // also a hedge.
        var claimed = Set<Int>()
        let fillers = tally(normalised, at: ordered, singles: fillerWords,
                            phrases: fillerPhrases, claimed: &claimed)
        let hedges = tally(normalised, at: ordered, singles: hedgeWords,
                           phrases: hedgePhrases, claimed: &claimed)
        let careful = tally(normalised, at: ordered, singles: carefulWords,
                            phrases: carefulPhrases, claimed: &claimed)

        // Pauses, between the end of one word and the start of the next.
        var pauses: [Pause] = []
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let gap = b.atMs - a.endMs
            if gap >= pauseMs { pauses.append(Pause(startMs: a.endMs, lengthMs: gap)) }
        }

        let speakingMs = ordered.reduce(0) { $0 + $1.durationMs }

        // Runs: speech between breaths. Everything about sentence shape is
        // measured off these, because a verbatim transcript has no full
        // stops in it to measure off instead.
        var runs: [Run] = []
        var runStartIndex = 0
        func closeRun(endingAt last: Int) {
            guard last >= runStartIndex else { return }
            runs.append(Run(startMs: ordered[runStartIndex].atMs,
                            endMs: ordered[last].endMs,
                            words: last - runStartIndex + 1,
                            opener: normalised[runStartIndex]))
        }
        for index in 1..<max(1, ordered.count) where ordered[index].atMs - ordered[index - 1].endMs >= breathMs {
            closeRun(endingAt: index - 1)
            runStartIndex = index
        }
        if !ordered.isEmpty { closeRun(endingAt: ordered.count - 1) }

        let longest = runs.max { $0.lengthMs < $1.lengthMs }

        // Openers, counted the same way fillers are so the report can show
        // them the same way.
        var openerPositions: [String: [Int]] = [:]
        for run in runs where !run.opener.isEmpty {
            openerPositions[run.opener, default: []].append(run.startMs)
        }

        // Vocabulary. A moving-window type-token ratio rather than the plain
        // one, because unique/total falls with length for arithmetic reasons
        // rather than for anything the speaker did.
        let content = normalised.filter { !$0.isEmpty }
        let unique = Set(content).count
        var vocabulary: Double = 0
        if content.count > mattrWindow {
            var scores: [Double] = []
            for start in 0...(content.count - mattrWindow) {
                let window = content[start..<(start + mattrWindow)]
                scores.append(Double(Set(window).count) / Double(mattrWindow))
            }
            vocabulary = scores.reduce(0, +) / Double(scores.count)
        } else if !content.isEmpty {
            vocabulary = Double(unique) / Double(content.count)
        }

        // The words leaned on, minus the ones every sentence needs and the
        // ones already reported as fillers or hedges.
        let alreadyReported = Set(fillers.map(\.word) + hedges.map(\.word))
        var contentPositions: [String: [Int]] = [:]
        for (index, word) in normalised.enumerated() {
            guard word.count > 2, !stopWords.contains(word),
                  !alreadyReported.contains(word) else { continue }
            contentPositions[word, default: []].append(ordered[index].atMs)
        }

        return ScreenroomSpeechMetrics(
            wordCount: ordered.count,
            durationMs: durationMs,
            engine: engine,
            verbatim: verbatim,
            wordsPerMinute: Double(ordered.count) / minutes,
            paceWindow: windows,
            fillers: fillers,
            fillersPerMinute: Double(fillers.reduce(0) { $0 + $1.count }) / minutes,
            pauses: pauses.sorted { $0.lengthMs > $1.lengthMs },
            talkRatio: durationMs > 0 ? min(1, Double(speakingMs) / Double(durationMs)) : 0,
            hedges: hedges,
            careful: careful,
            uniqueWords: unique,
            vocabulary: vocabulary,
            repeated: Array(rank(contentPositions).filter { $0.count >= 3 }.prefix(8)),
            runs: runs,
            wordsPerRun: runs.isEmpty ? 0 : Double(ordered.count) / Double(runs.count),
            longestRunMs: longest?.lengthMs ?? 0,
            longestRunStartMs: longest?.startMs ?? 0,
            starters: Array(rank(openerPositions).prefix(8)))
    }

    /// The window MATTR averages over. Fifty is short for the literature and
    /// right for this: a two-minute class presentation is three hundred
    /// words, and a hundred-word window would leave four samples to average.
    static let mattrWindow = 50

    /// Counts one list of words and one list of two-word phrases, skipping
    /// any position an earlier pass already claimed.
    ///
    /// Phrases go first within a pass so "you know" is counted as itself
    /// rather than as nothing, and "kind of" is not counted as "of".
    private static func tally(_ normalised: [String],
                              at words: [ScreenroomSpokenWord],
                              singles: Set<String>,
                              phrases: [[String]],
                              claimed: inout Set<Int>) -> [Filler] {
        var positions: [String: [Int]] = [:]
        for phrase in phrases where phrase.count == 2 {
            for index in 0..<max(0, normalised.count - 1) {
                guard !claimed.contains(index), !claimed.contains(index + 1),
                      normalised[index] == phrase[0],
                      normalised[index + 1] == phrase[1] else { continue }
                claimed.insert(index)
                claimed.insert(index + 1)
                positions[phrase.joined(separator: " "), default: []].append(words[index].atMs)
            }
        }
        for (index, word) in normalised.enumerated() {
            guard !claimed.contains(index), singles.contains(word) else { continue }
            claimed.insert(index)
            positions[word, default: []].append(words[index].atMs)
        }
        return rank(positions)
    }

    /// Most-used first, alphabetical within a tie, so two runs over the same
    /// transcript produce the same report.
    private static func rank(_ positions: [String: [Int]]) -> [Filler] {
        positions
            .map { Filler(word: $0.key, count: $0.value.count, atMs: $0.value.sorted()) }
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                return left.word < right.word
            }
    }

    /// Lowercased, stripped of the punctuation a recogniser attaches. "Um,"
    /// and "um" are the same crutch.
    static func normalise(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    // MARK: Saying it

    /// Plain sentences, for the report and for the agent's brief.
    ///
    /// No judgement in them: "150 words per minute" rather than "too fast".
    /// What counts as too fast depends on the subject, the room and the
    /// speaker, and a number that tells a student they were wrong when they
    /// were not is the fastest way to make them stop reading.
    var sentences: [String] {
        var out: [String] = []
        out.append("\(wordCount) words in \(minutesLabel(durationMs)), an average of \(Int(wordsPerMinute.rounded())) words per minute.")

        if let fastest = paceWindow.max(by: { $0.wordsPerMinute < $1.wordsPerMinute }),
           let slowest = paceWindow.min(by: { $0.wordsPerMinute < $1.wordsPerMinute }),
           paceWindow.count >= 3, fastest.wordsPerMinute > slowest.wordsPerMinute * 1.4 {
            out.append("Pace varied: fastest around \(offsetLabel(fastest.startMs)) at \(Int(fastest.wordsPerMinute.rounded())) wpm, slowest around \(offsetLabel(slowest.startMs)) at \(Int(slowest.wordsPerMinute.rounded())).")
        }

        // The filler line always says where it stands, because a number
        // that cannot be trusted and does not say so is worse than no number.
        if !verbatim {
            out.append("Filler words were NOT counted: \(engine) returns a cleaned-up transcript, so the words this would count have already been removed from it. Transcribe with whisper to get a real figure.")
        } else if fillerCount > 0 {
            let top = fillers.prefix(3).map { "\"\($0.word)\" \($0.count)\u{00D7}" }.joined(separator: ", ")
            out.append("\(fillerCount) filler \(fillerCount == 1 ? "word" : "words"), \(String(format: "%.1f", fillersPerMinute)) a minute. Most used: \(top).")
        } else {
            out.append("No filler words from the list were detected.")
        }

        if verbatim, hedgeCount > 0 {
            let top = hedges.prefix(3).map { "\"\($0.word)\" \($0.count)\u{00D7}" }.joined(separator: ", ")
            out.append("\(hedgeCount) hedges and softeners, \(String(format: "%.1f", hedgesPerMinute)) a minute. Most used: \(top).")
        }

        if !runs.isEmpty {
            out.append("\(runs.count) stretches of speech between breaths, averaging \(String(format: "%.0f", wordsPerRun)) words each; the longest unbroken stretch ran \(String(format: "%.0f", Double(longestRunMs) / 1000))s from \(offsetLabel(longestRunStartMs)).")
        }

        if let opener = starters.first, runs.count >= 6, opener.count >= 3 {
            out.append("\(opener.count) of \(runs.count) stretches opened with \"\(opener.word)\".")
        }

        if vocabulary > 0 {
            out.append("\(uniqueWords) different words; vocabulary variety \(Int((vocabulary * 100).rounded()))% measured over fifty-word windows.")
        }

        if !repeated.isEmpty {
            out.append("Leaned on: " + repeated.prefix(5).map { "\"\($0.word)\" \($0.count)\u{00D7}" }.joined(separator: ", ") + ".")
        }

        if verbatim, !careful.isEmpty {
            out.append("Worth a second look: " + careful.map { "\"\($0.word)\"" }.joined(separator: ", ") + ". Not errors; the teacher decides.")
        }

        if let longest = pauses.first {
            out.append("\(pauses.count) \(pauses.count == 1 ? "pause" : "pauses") over two seconds; the longest was \(String(format: "%.1f", Double(longest.lengthMs) / 1000))s at \(offsetLabel(longest.startMs)).")
        }

        out.append("Speaking for \(Int((talkRatio * 100).rounded()))% of the time.")
        return out
    }

    private func offsetLabel(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func minutesLabel(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        if seconds < 60 { return "\(seconds) seconds" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    // MARK: Disk

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    static func load(in folder: URL) -> ScreenroomSpeechMetrics? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        return try? JSONDecoder().decode(ScreenroomSpeechMetrics.self, from: data)
    }

    @discardableResult
    func save(in folder: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        return (try? data.write(to: Self.url(in: folder), options: .atomic)) != nil
    }
}
