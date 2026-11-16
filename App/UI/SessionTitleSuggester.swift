//
//  SessionTitleSuggester.swift
//
//  A suggested title for a session nobody has named: "Course · Topic".
//
//  Pure and deterministic. The topic is two to four words taken from what was
//  said (transcript.txt lines), by counting the words that are not filler and
//  preferring a pair that comes up repeatedly. Nothing leaves the Mac.
//  The course is whatever the caller reliably knows (SessionMetadata.course);
//  nil means "do not say".
//
//  A title the user typed always wins, and the folder name is the last resort.
//
import Foundation

enum SessionTitleSuggester {

    /// Fewer spoken words than this and a topic would be a guess.
    static let minimumWords = 60

    /// The title to show: typed title, else the suggestion, else the fallback.
    static func displayTitle(custom: String?, course: String?, topic: String?, fallback: String) -> String {
        if let c = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        return suggestion(course: course, topic: topic) ?? fallback
    }

    /// "Course · Topic", or just the topic. A course alone is not a title.
    static func suggestion(course: String?, topic: String?) -> String? {
        let t = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !t.isEmpty else { return nil }
        let c = course?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return c.isEmpty ? t : "\(c) \u{00B7} \(t)"
    }

    /// Topic from the spoken sentences, or nil when there is too little said.
    static func topic(fromLines lines: [String]) -> String? {
        var tokens: [String] = []   // lowercased words, "" marks a sentence break
        for line in lines {
            var current = ""
            func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
            for ch in line.lowercased() {
                if ch.isLetter || ch == "'" || ch == "\u{2019}" { current.append(ch) }
                else if ch.isNumber { current.append(ch) }
                else {
                    flush()
                    if ".?!;:".contains(ch) { tokens.append("") }
                }
            }
            flush()
            tokens.append("")
        }
        let spoken = tokens.filter { !$0.isEmpty }
        guard spoken.count >= minimumWords else { return nil }

        func isContent(_ w: String) -> Bool {
            w.count >= 4 && !stopWords.contains(w) && !w.contains("'") && !w.contains("\u{2019}")
                && !w.allSatisfy(\.isNumber)
        }
        func stem(_ w: String) -> String {
            if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
            return w
        }

        var unigram: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var surface: [String: String] = [:]
        var bigram: [String: Int] = [:]
        for (i, w) in tokens.enumerated() where isContent(w) {
            let s = stem(w)
            unigram[s, default: 0] += 1
            if firstSeen[s] == nil { firstSeen[s] = i; surface[s] = w }
            if i + 1 < tokens.count, isContent(tokens[i + 1]) {
                bigram["\(s) \(stem(tokens[i + 1]))", default: 0] += 1
            }
        }

        func title(_ words: [String]) -> String {
            words.map { surface[$0] ?? $0 }.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }

        // A pair said at least twice reads as a phrase ("Quadratic Equations").
        let pairs = bigram.filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if let best = pairs.first { return title(best.key.split(separator: " ").map(String.init)) }

        // Otherwise the one or two words said most, in the order they came up.
        let top = unigram.filter { $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(2)
        guard let lead = top.first else { return nil }
        // A second word only joins when it was said as often as the first;
        // a weaker runner-up ("Fractions & Line") reads as noise.
        let topWords = top.filter { $0.value == lead.value }.map(\.key)
        let ordered = topWords.sorted { (firstSeen[$0] ?? 0) < (firstSeen[$1] ?? 0) }
        return ordered.count == 1 ? title(ordered) : ordered.map { title([$0]) }.joined(separator: " & ")
    }

    /// Words that carry no topic: grammar, filler, and what a teacher says about a lesson rather than in it.
    static let stopWords: Set<String> = [
        "about", "above", "after", "again", "also", "always", "another", "around", "because", "been", "before",
        "being", "below", "between", "both", "bring", "call", "called", "can't", "come", "could", "didn't",
        "does", "doing", "done", "down", "each", "else", "even", "ever", "every", "everyone", "first", "from",
        "gave", "give", "going", "gonna", "good", "great", "have", "having", "here", "know", "last", "later",
        "left", "less", "let's", "like", "little", "look", "looking", "made", "make", "many", "maybe", "more",
        "most", "much", "must", "need", "next", "okay", "once", "only", "other", "over", "please", "really",
        "right", "same", "say", "see", "seen", "several", "should", "show", "since", "some", "something",
        "sometimes", "still", "such", "sure", "take", "tell", "than", "thank", "thanks", "that", "that's",
        "their", "them", "then", "there", "there's", "these", "they", "thing", "things", "think", "this",
        "those", "through", "time", "today", "together", "under", "until", "very", "want", "well", "were",
        "what", "what's", "when", "where", "which", "while", "will", "with", "within", "without", "would",
        "yeah", "yes", "your", "you're", "class", "lesson", "students", "student", "everybody", "question",
        "questions", "answer", "answers", "page", "start", "started", "begin", "today's", "welcome", "just",
        "into", "back", "keep", "work", "word", "words", "part", "point", "example", "write", "written",
        "read", "going", "talk", "talking", "board", "book", "minute", "minutes",
        "quite", "actually", "basically", "exactly", "through", "using", "used", "uses", "find", "found",
        "means", "mean", "said", "says", "saying", "name", "does", "doesn't", "don't", "isn't", "wasn't",
        "rest", "won't", "wouldn't", "couldn't", "shouldn't", "aren't", "weren't", "hasn't", "haven't",
    ]
}
