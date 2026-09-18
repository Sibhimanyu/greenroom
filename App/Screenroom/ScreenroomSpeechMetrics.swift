//
//  ScreenroomSpeechMetrics.swift
//  Greenroom
//
//  The countable half of what Yoodli-shaped products do.
//
//  Filler words, pace, pauses. All of it is arithmetic over a transcript with
//  word timings, so all of it stays here rather than going to a model - the
//  same rule ScreenroomCohort and ScreenroomAgreement follow, and for the same reason:
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

    var v: Int = 2
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

        // Fillers. Phrases first so their words are not counted twice.
        var counts: [String: [Int]] = [:]
        var consumed = Set<Int>()
        let normalised = ordered.map { normalise($0.text) }

        for phrase in fillerPhrases {
            guard phrase.count == 2 else { continue }
            for index in 0..<max(0, normalised.count - 1) {
                guard !consumed.contains(index), !consumed.contains(index + 1),
                      normalised[index] == phrase[0], normalised[index + 1] == phrase[1] else { continue }
                consumed.insert(index)
                consumed.insert(index + 1)
                counts[phrase.joined(separator: " "), default: []].append(ordered[index].atMs)
            }
        }
        for (index, word) in normalised.enumerated() {
            guard !consumed.contains(index), fillerWords.contains(word) else { continue }
            counts[word, default: []].append(ordered[index].atMs)
        }

        var fillers: [Filler] = []
        for (word, positions) in counts {
            fillers.append(Filler(word: word, count: positions.count, atMs: positions.sorted()))
        }
        // Most-used first, alphabetical within a tie so two runs of the same
        // transcript produce the same report.
        fillers.sort { left, right in
            if left.count != right.count { return left.count > right.count }
            return left.word < right.word
        }

        // Pauses, between the end of one word and the start of the next.
        var pauses: [Pause] = []
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let gap = b.atMs - a.endMs
            if gap >= pauseMs { pauses.append(Pause(startMs: a.endMs, lengthMs: gap)) }
        }

        let speakingMs = ordered.reduce(0) { $0 + $1.durationMs }

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
            talkRatio: durationMs > 0 ? min(1, Double(speakingMs) / Double(durationMs)) : 0)
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
