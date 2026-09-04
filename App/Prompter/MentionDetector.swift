//
//  MentionDetector.swift
//  Greenroom
//
//  "Did the teacher just name something we could find?"
//
//  Two answers to that question share one interface: Apple's on-device
//  language model (FoundationModelsDetector.swift, macOS 26 with Apple
//  Intelligence turned on) and the word-pattern detector below, which is the
//  fallback when the model is unavailable and the reference the model is
//  measured against. Both see the same input - the sentences that have not
//  been looked at yet, a few words of lead-in for context, and the names of
//  everyone in the meeting, which must never become a query.
//
//  The heuristic is deliberately conservative. A false card costs a glance and
//  a click of ×; a false card that is a student's name costs a Wikipedia
//  request carrying a child's name. So person mentions need a cue ("by",
//  "author", "wrote") or two capitalised words, and the roster filter runs
//  before anything else.
//
import Foundation
import NaturalLanguage

protocol MentionDetector {
    /// "Apple Intelligence (on-device)" or "word patterns" - for the status
    /// log's first line and the Settings row.
    var name: String { get }
    /// The analytics bucket: "ai" | "heuristic".
    var analyticsCode: String { get }
    func detect(newText: String, context: String, excludedNames: [String]) async throws -> [Mention]
}

/// Cue phrases and capitalisation. No network, no model, no learning.
struct HeuristicDetector: MentionDetector {
    let name = "word patterns"
    let analyticsCode = "heuristic"

    /// Words that end a title when they follow it. "the book called Matilda
    /// which is about" → "Matilda".
    private static let stopWords: Set<String> = [
        "which", "that", "and", "but", "so", "because", "where", "when", "who", "it", "its",
        "is", "was", "the", "a", "an", "about", "by", "in", "on", "at", "to", "of", "for",
        "with", "this", "these", "those", "then", "now", "today", "yesterday", "okay", "ok",
        "right", "yeah", "yes", "no", "um", "uh", "like", "very", "really", "just", "also"
    ]

    /// Cue → kind. The capture is what follows the cue up to a boundary.
    ///
    /// Case-insensitivity is scoped to the cue words with `(?i:…)`. A blanket
    /// `(?i)` made `[A-Z]` match anything, and "the country called India has"
    /// came back as the place "India has".
    private static let cues: [(pattern: String, kind: Mention.Kind, confidence: Double)] = [
        // Books
        (#"\b(?i:the|a|this|that) (?i:book|story|novel|picture book|storybook) (?i:called|named|titled) ["“]?([^"”.,;!?]{2,60})"#, .book, 0.8),
        (#"\b(?i:reading|read|finished|started) (?i:the book |a book |the story )?["“]([^"”]{2,60})["”]"#, .book, 0.75),
        (#"\b(?i:book|story|novel) ["“]([^"”]{2,60})["”]"#, .book, 0.75),
        (#"\b(?i:we(?:'re| are) (?:reading|going to read|starting)) (?!(?i:the|a|this) (?i:book|story|novel))([A-Z][^.,;!?]{2,50}?)(?= (?i:by|today|tomorrow|now)\b|[.,;!?]|$)"#, .book, 0.6),
        // Videos
        (#"\b(?i:a|the|this) (?i:video|clip|documentary|cartoon|film|movie) (?i:about|called|of) ([^.,;!?]{2,60})"#, .video, 0.75),
        (#"\b(?i:i|we) (?i:watched|saw) (?i:a |the )?(?i:video|clip|documentary|cartoon|film|movie)?(?: (?i:on youtube))? (?i:about|called|of) ([^.,;!?]{2,60})"#, .video, 0.7),
        (#"\b(?i:on youtube) (?i:about|called|of) ([^.,;!?]{2,60})"#, .video, 0.75),
        // Topics
        (#"\b(?i:let's|let us) (?i:talk|learn|read) (?i:about) ([^.,;!?]{2,50})"#, .topic, 0.6),
        (#"\b(?i:do you know) (?i:what|about) (?i:a |an |the )?([^.,;!?]{2,40}?) (?i:is|are|means|was)\b"#, .topic, 0.55),
        (#"\b(?i:what) (?i:is|are) (?i:a |an |the )?([^.,;!?]{2,40}?)\?"#, .topic, 0.5),
        (#"\b(?i:the word) ["“]?([A-Za-z][a-z-]{3,30})["”]?"#, .topic, 0.55),
        // People (a cue, or the tagger below)
        (#"\b(?i:written|book|story|novel|poem|by the author|author) (?i:by) ((?:[A-Z]\. ?)*[A-Z][a-z]+(?: [A-Z]\.)*(?: [A-Z][a-z]+){1,2})"#, .person, 0.75),
        (#"\b(?i:the author|the writer|the poet|the scientist|the artist|the president|the king|the queen) ([A-Z][a-z]+(?: [A-Z][a-z]+){1,2})"#, .person, 0.7),
        // Places
        (#"\b(?i:the country|the city|the river|the mountain|the ocean|the continent|the state|the planet) (?i:of |called )?([A-Z][A-Za-z]+(?: [A-Z][A-Za-z]+){0,2})"#, .place, 0.7)
    ]

    /// Words that are never a thing to look up on their own: the places the
    /// teacher is looking, not what they found there.
    private static let blocklist: Set<String> = [
        "youtube", "google", "internet", "zoom", "online", "video", "book", "story", "class", "screen", "page"
    ]

    func detect(newText: String, context: String, excludedNames: [String]) async throws -> [Mention] {
        let text = Self.clean(newText)
        guard text.split(whereSeparator: \.isWhitespace).count >= 3 else { return [] }
        var found: [Mention] = []

        for cue in Self.cues {
            guard let regex = try? NSRegularExpression(pattern: cue.pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                guard let captured = Range(match.range(at: 1), in: text) else { continue }
                let phrase = Self.trimToTitle(String(text[captured]))
                guard let query = Self.acceptable(phrase, kind: cue.kind) else { continue }
                found.append(Mention(kind: cue.kind, query: query, confidence: cue.confidence))
            }
        }

        // Named entities the tagger is sure about. Places and organisations
        // are cheap wins; people only with a cue or two capitalised words -
        // the tagger calls a lone "Matilda" a person, and that is a child in
        // the room as often as it is a book.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            let phrase = String(text[range])
            switch tag {
            case .placeName?:
                if let query = Self.acceptable(phrase, kind: .place) {
                    found.append(Mention(kind: .place, query: query, confidence: 0.6))
                }
            case .personalName?:
                let words = phrase.split(separator: " ")
                if words.count >= 2, let query = Self.acceptable(phrase, kind: .person) {
                    found.append(Mention(kind: .person, query: query, confidence: 0.55))
                }
            case .organizationName?:
                if let query = Self.acceptable(phrase, kind: .topic) {
                    found.append(Mention(kind: .topic, query: query, confidence: 0.5))
                }
            default:
                break
            }
            return true
        }

        return Self.filter(found, excludedNames: excludedNames)
    }

    // MARK: Shared with the model detector

    /// Drops mentions that name someone in the meeting, dedupes by key, keeps
    /// the highest-confidence copy, and caps the batch. The roster rule is
    /// enforced here for BOTH detectors, so a model that ignores its
    /// instructions still cannot send a student's name anywhere.
    static func filter(_ mentions: [Mention], excludedNames: [String]) -> [Mention] {
        let excludedTokens: Set<String> = Set(excludedNames.flatMap { name in
            Mention.normalize(name).split(separator: " ").map(String.init).filter { $0.count >= 3 }
        })
        var byKey: [String: Mention] = [:]
        for mention in mentions {
            let key = mention.normalizedKey
            guard !key.isEmpty else { continue }
            let tokens = key.split(separator: " ").map(String.init)
            // A person mention sharing any token with a roster name is dropped;
            // any other kind is dropped only when it IS a roster name.
            if mention.kind == .person {
                if tokens.contains(where: { excludedTokens.contains($0) }) { continue }
            } else if excludedNames.contains(where: { Mention.normalize($0) == key }) {
                continue
            }
            if let existing = byKey[key], existing.confidence >= mention.confidence { continue }
            byKey[key] = mention
        }
        // Two cues can capture the same title at different lengths ("Charlotte's
        // Web" and "the book called Charlotte's Web"). Keep the shorter one -
        // it is the tighter query - and drop any mention that merely contains
        // another mention of the same kind.
        let keys = Array(byKey.keys)
        for key in keys {
            guard let mention = byKey[key] else { continue }
            let contained = keys.contains { other in
                other != key && byKey[other]?.kind == mention.kind
                    && other.count < key.count && (" " + key + " ").contains(" " + other + " ")
            }
            if contained { byKey.removeValue(forKey: key) }
        }
        return Array(byKey.values.sorted { $0.confidence > $1.confidence }.prefix(5))
    }

    /// Names in the roster that a mention collided with, for the log line.
    static func rosterCollisions(_ mentions: [Mention], excludedNames: [String]) -> [String] {
        let kept = Set(filter(mentions, excludedNames: excludedNames).map(\.normalizedKey))
        return mentions.filter { !kept.contains($0.normalizedKey) && $0.kind == .person }.map(\.query)
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Words that end a title wherever they fall after its first word. The
    /// soft stop words above only cut after the second word, so "Diary of a
    /// Wimpy Kid" survives; these cut earlier because nothing findable
    /// continues past them: "volcanoes on YouTube" is about volcanoes.
    private static let hardStops: Set<String> = [
        "on", "which", "that", "because", "and", "but", "so", "then", "yesterday", "today", "tomorrow",
        "when", "where", "while", "okay", "ok", "right", "yeah"
    ]

    /// Cuts a capture at the first hard stop after the first word or the first
    /// soft stop after the second, and strips trailing filler.
    private static func trimToTitle(_ raw: String) -> String {
        var words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
            .split(separator: " ").map(String.init)
        if let cut = words.indices.dropFirst(1).first(where: { hardStops.contains(words[$0].lowercased()) }) {
            words = Array(words[..<cut])
        }
        if let cut = words.indices.dropFirst(2).first(where: { stopWords.contains(words[$0].lowercased()) }) {
            words = Array(words[..<cut])
        }
        while let last = words.last, stopWords.contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Length and shape checks so a cue that swallowed half a sentence does
    /// not become a query.
    private static func acceptable(_ phrase: String, kind: Mention.Kind) -> String? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        let words = trimmed.split(separator: " ")
        guard !words.isEmpty, words.count <= 7, trimmed.count >= 3, trimmed.count <= 60 else { return nil }
        // Every word a stop word or a pronoun: not a thing.
        if words.allSatisfy({ stopWords.contains($0.lowercased()) }) { return nil }
        if words.count == 1, blocklist.contains(trimmed.lowercased()) { return nil }
        if ["i", "you", "we", "they", "he", "she", "it", "me", "us", "them"].contains(trimmed.lowercased()) { return nil }
        return trimmed
    }
}
