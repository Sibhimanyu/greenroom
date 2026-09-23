//
//  ScreenroomInsights.swift
//  Greenroom
//
//  The report's readings, sorted into what went well and what to work on.
//
//  Modelled on how Yoodli lays out its results, which was studied from its
//  own published screenshots: every metric is one row with its name on the
//  left and its value, said the way a person would say it, on the right -
//  "4 fillers, 2%", "I think, I think", "None". Opened, a row reads the same
//  way every time: one sentence that says what to do, the evidence, a way to
//  hear it, and where this talk sits against the others.
//
//  What is borrowed is the grammar, not the look. The colours, type and
//  spacing are DESIGN.md's; the purple, the emoji and the drop shadows stay
//  where they were found.
//
//  The thresholds are stated here, in one place, so they can be argued with.
//  Most are Yoodli's published guidance (fillers and softeners under 3-4% of
//  words, the same opener on under 15% of sentences); none is research, and
//  the report says "usual", never "correct".
//
//  Everything below is arithmetic over files already on disk. Nothing here
//  needs the network or a model.
//
import Foundation

enum ScreenroomInsights {

    // MARK: Thresholds

    static let fillerShare = 0.03
    static let softenerShare = 0.04
    static let repetitionShare = 0.04
    static let openerShare = 0.15
    static let sentenceBand: ClosedRange<Double> = 8...20
    static let facingFloor = 0.6
    /// Talking more than this share of the time leaves no room for a point
    /// to land. A presentation is not a race to fill the silence.
    static let talkCeiling = 0.92

    // MARK: Repetition

    /// A word or two-word phrase said twice in a row: "I think, I think",
    /// "the the". Restarts, in other words - the audible sign of a sentence
    /// being rebuilt while it is being said.
    struct Repeat: Hashable, Identifiable {
        let phrase: String
        let atMs: Int
        var id: Int { atMs }
    }

    static func repeats(in words: [ScreenroomSpokenWord]) -> [Repeat] {
        let bare = words.map(normalised)
        var found: [Repeat] = []
        var i = 0
        while i < bare.count {
            // Two-word phrases first, so "I think I think" is one repeat and
            // not two stray "I"s.
            if i + 3 < bare.count, !bare[i].isEmpty,
               bare[i] == bare[i + 2], bare[i + 1] == bare[i + 3], bare[i] != bare[i + 1] {
                found.append(Repeat(phrase: "\(clean(words[i].text)) \(clean(words[i + 1].text)), \(clean(words[i + 2].text)) \(clean(words[i + 3].text))",
                                    atMs: words[i].atMs))
                i += 4
                continue
            }
            if i + 1 < bare.count, !bare[i].isEmpty, bare[i] == bare[i + 1] {
                found.append(Repeat(phrase: "\(clean(words[i].text)), \(clean(words[i + 1].text))",
                                    atMs: words[i].atMs))
                i += 2
                continue
            }
            i += 1
        }
        return found
    }

    // MARK: Questions

    struct Question: Hashable, Identifiable {
        let text: String
        let atMs: Int
        var id: Int { atMs }
    }

    /// Every sentence the transcript ends with a question mark.
    ///
    /// Only as good as the transcriber's punctuation: whisper punctuates,
    /// Apple's recogniser mostly does too, and neither is perfect. A missed
    /// question costs a row that says one fewer; nothing is scored on it.
    static func questions(in words: [ScreenroomSpokenWord]) -> [Question] {
        var out: [Question] = []
        var sentence: [ScreenroomSpokenWord] = []
        for word in words {
            sentence.append(word)
            let t = word.text.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("?") || t.hasSuffix(".") || t.hasSuffix("!") {
                if t.hasSuffix("?"), let first = sentence.first {
                    out.append(Question(text: sentence.map(\.text).joined(separator: " "),
                                        atMs: first.atMs))
                }
                sentence = []
            }
        }
        return out
    }

    // MARK: Pace, finely

    /// Pace sampled every few seconds from the words themselves, with a
    /// break wherever the speaker was silent.
    ///
    /// The half-minute windows in speech.json are right for a total and too
    /// coarse for a line: a 42-second talk has two of them. Counting words in
    /// a sliding window gives a curve with a shape, and leaving a gap over a
    /// silence stops the line pretending the speaker kept talking through it.
    struct PacePoint: Hashable {
        let seconds: Double
        let wordsPerMinute: Double
        /// Consecutive points share a segment; a silence starts a new one.
        let segment: Int
    }

    static func paceCurve(_ words: [ScreenroomSpokenWord], durationMs: Int,
                          everyMs: Int = 3_000, windowMs: Int = 20_000) -> [PacePoint] {
        guard durationMs > windowMs / 2, !words.isEmpty else { return [] }
        var points: [PacePoint] = []
        var segment = 0
        var lastWasSilent = false
        for t in stride(from: 0, through: durationMs, by: everyMs) {
            let near = words.contains { abs($0.atMs - t) <= 1_500 || ($0.atMs <= t && $0.endMs >= t) }
            if !near {
                if !lastWasSilent { segment += 1 }
                lastWasSilent = true
                continue
            }
            lastWasSilent = false
            let from = max(0, t - windowMs / 2)
            let to = min(durationMs, t + windowMs / 2)
            let span = max(1, to - from)
            let count = words.filter { $0.atMs >= from && $0.atMs < to }.count
            points.append(PacePoint(seconds: Double(t) / 1000,
                                    wordsPerMinute: Double(count) * 60_000 / Double(span),
                                    segment: segment))
        }
        return points
    }

    // MARK: Against the others

    /// "Faster than 3 of 5 other talks." Nil below two others: a class of
    /// one is not a comparison.
    static func standing(_ value: Double, among others: [Double],
                         higher: String, lower: String) -> String? {
        guard others.count >= 2 else { return nil }
        let above = others.filter { $0 < value }.count
        let below = others.filter { $0 > value }.count
        func phrase(_ word: String, _ n: Int) -> String {
            let lead = word.prefix(1).uppercased() + word.dropFirst()
            // "Faster than 2 of 2" is a sentence nobody says.
            return n == others.count ? "\(lead) than every other talk in this library."
                : "\(lead) than \(n) of \(others.count) other talks in this library."
        }
        // Level with everyone: "more than 0 of 2" was the old answer here.
        if above == 0, below == 0 { return "Level with the other \(others.count) talks in this library." }
        return above >= below ? phrase(higher, above) : phrase(lower, below)
    }

    // MARK: Helpers

    private static func normalised(_ word: ScreenroomSpokenWord) -> String {
        word.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}
