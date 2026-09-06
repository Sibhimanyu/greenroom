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
//  What the patterns look for was learned from a recorded class, not
//  guessed. The first version looked for book titles and capitalised names;
//  replayed against 45 minutes of a real lesson it found none of the eight
//  things the teacher referred to and produced nineteen false alarms, every
//  one a Tamil word the transcriber had capitalised. The lesson is Indian
//  English with Tamil mixed in, so capitalisation and Apple's name tagger
//  are worthless there - and the teacher does not name books to look up; he
//  names tools ("it's called Haiku Deck"), products ("Kindle Paperwhite,
//  they call it"), words ("the word pabulum") and quotations, and reaches for
//  the browser six to forty-five seconds later. So every rule below starts
//  from a spoken tell, and nothing is detected from capitalisation alone.
//
//  Scored against that class: 16 lookups, 90% recall, 56% precision. The
//  on-device model (FoundationModelsDetector, opt-in) reaches 100% recall on
//  the same class but 264 lookups at 3% precision, which is why the patterns
//  are what a lesson runs on. The transcript, truth file and detection dumps
//  behind those numbers are kept OUTSIDE this repo (~/PrompterBench-evidence)
//  because they are a real class with children's names in them.
//
import Foundation

protocol MentionDetector {
    /// "Apple Intelligence (on-device)" or "word patterns" - for the status
    /// log's first line and the Settings row.
    var name: String { get }
    /// The analytics bucket: "ai" | "heuristic".
    var analyticsCode: String { get }
    /// True when a pass costs nothing worth rationing. Regexes are free, so
    /// they run on every finalised sentence; a model pass is seconds of the
    /// Mac's attention, so it waits for enough new words to be worth it.
    var isCheap: Bool { get }
    func detect(newText: String, context: String, excludedNames: [String]) async throws -> [Mention]
}

/// Word patterns first; the model only where they are silent.
///
/// Phase 3 of docs/prompter-search-improvement-plan.md: the model is a
/// SECONDARY candidate generator, not a replacement. Measured against a real
/// class the two are not close - word patterns 16 lookups at 56% precision,
/// the model 264 at 3% - but the model is the only one that finds a thing said
/// with no verbal tell ("haven't joined book fusion"). Running it instead of
/// the patterns threw away the good source to get the greedy one. Running it
/// after them keeps both: a sentence with an explicit tell is answered by the
/// rule that is right about it, and the model is left the sentences nobody
/// else can read.
///
/// Composed rather than run in parallel because the transcript can only be
/// consumed once - `unprocessedText` marks every sentence processed as it
/// hands them over, so two detectors reading it would each see half a class.
///
/// Cheap on purpose. The patterns leg costs under a millisecond and answers
/// most batches on its own, so it keeps running on every finalised sentence.
/// Only a silent batch pays for the model, and while that pass is in flight
/// `runDetection` declines to start another - so new speech accumulates and
/// arrives in the next batch rather than being dropped or piling up passes.
struct CompositeDetector: MentionDetector {
    let name = "word patterns, with Apple Intelligence for the rest"
    let analyticsCode = "composite"
    let isCheap = true

    let patterns = HeuristicDetector()
    let model: MentionDetector

    func detect(newText: String, context: String, excludedNames: [String]) async throws -> [Mention] {
        let byPattern = try await patterns.detect(newText: newText, context: context,
                                                  excludedNames: excludedNames)
        guard byPattern.isEmpty else { return byPattern }
        // A batch that is not English is not a batch to mine for named things.
        //
        // The patterns are safe here on their own - they need English cue words
        // to fire at all - but the model reads anything and will find a name in
        // it. In one real class this sentence, zero of five words in the
        // dictionary, produced two of the three wrong links: "Orukuntu" became
        // a Turkish footballer and "Kayam" became a concert-tent hire company.
        // Above half, not at it. A real class on 6 Sep transcribed
        // "Feeting season, Jao Maa" - two of its four words are in the Mac's
        // dictionary, so it scored exactly 0.50, passed a >= 0.5 test, and
        // produced both of that class's false alarms. A sentence that is half
        // not-English is not a sentence to mine for names, and a threshold a
        // real failure lands exactly on is the wrong threshold.
        guard HeuristicDetector.englishRatio(newText) > 0.5 else { return [] }
        let byModel = try await model.detect(newText: newText, context: context,
                                             excludedNames: excludedNames)
            .map { mention -> Mention in
                var tagged = mention
                tagged.foundBy = .model
                return tagged
            }
        // The roster rule is applied again here, on the way out.
        //
        // Both detectors already apply it, so this is belt and braces - and it
        // is worth it for this one property. A composite that trusts whatever
        // it wraps is only as safe as the least careful thing anyone plugs into
        // it later, and the failure mode is a child's name leaving the Mac.
        // The bench caught exactly that: a stub detector that skipped the
        // filter sent "Arun Kumar" straight through the composite.
        // HeuristicDetector.filter is idempotent, so applying it twice costs a
        // set intersection and nothing else.
        return HeuristicDetector.filter(byModel, excludedNames: excludedNames)
    }
}

/// Spoken tells and what follows them. No network, no model, no learning.
struct HeuristicDetector: MentionDetector {
    let name = "word patterns"
    let analyticsCode = "heuristic"
    let isCheap = true

    /// Words that end a title when they follow it. "the book called Matilda
    /// which is about" → "Matilda".
    private static let stopWords: Set<String> = [
        "which", "that", "and", "but", "so", "because", "where", "when", "who", "it", "its",
        "is", "was", "the", "a", "an", "about", "by", "in", "on", "at", "to", "of", "for",
        "with", "this", "these", "those", "then", "now", "today", "yesterday", "okay", "ok",
        "right", "yeah", "yes", "no", "um", "uh", "like", "very", "really", "just", "also", "or"
    ]

    /// Words that end a title wherever they fall after its first word. The
    /// soft stop words above only cut after the second word, so "Diary of a
    /// Wimpy Kid" survives; these cut earlier because nothing findable
    /// continues past them: "volcanoes on YouTube" is about volcanoes.
    private static let hardStops: Set<String> = [
        "on", "which", "that", "because", "and", "but", "so", "then", "yesterday", "today", "tomorrow",
        "when", "where", "while", "okay", "ok", "right", "yeah", "or", "no", "um", "uh"
    ]

    /// Everyday classroom nouns that are never worth a lookup on their own.
    ///
    /// Measured against a real class: the model offered "work", "schools",
    /// "food", "paper", "people" and the like as things to search. As a single
    /// word none of them is what a teacher would open a tab for, and dropping
    /// them cost none of the ten real hits while removing a tenth of the
    /// traffic. A word here is only blocked when it stands ALONE - "paper
    /// white" and "font design" survive.
    static let genericWords: Set<String> = [
        "work", "works", "school", "schools", "food", "paper", "papers", "screen", "screens",
        "book", "books", "story", "stories", "class", "classes", "people", "person", "student",
        "students", "teacher", "time", "day", "days", "thing", "things", "word", "words",
        "reading", "writing", "design", "font", "fonts", "point", "points", "line", "lines",
        "page", "pages", "idea", "ideas", "life", "question", "questions", "answer", "answers",
        "picture", "pictures", "video", "light", "group", "groups", "place", "today",
        "yesterday", "morning", "name", "names", "hand", "eye", "ear", "head", "heart"
    ]

    /// True when a phrase is worth spending a request on at all.
    ///
    /// Three rules, measured against a real class to cost nothing in recall:
    ///
    /// 1. The name has to have actually been said. The model invents items
    ///    despite being told not to.
    /// 2. A single word that is in the Mac's dictionary is ordinary English,
    ///    not a thing to look up - "roads", "explain", "scarves", "work".
    ///    A hand-written list of such words was never going to be complete;
    ///    the dictionary is. Checked against the real hits first: "Tahoma",
    ///    "monospace", "Verdana" and "BookFusion" are all absent from it and
    ///    survive.
    /// 3. Except when he used it as a NAME. "Kindle", "Amazon" and "Haiku"
    ///    are all in the dictionary (the verb, the river, the poem), so a
    ///    dictionary word still passes if it appears capitalised in the middle
    ///    of a sentence - which is how a brand reads and how an ordinary noun
    ///    does not. Sentence-initial capitals do not count, or every word that
    ///    opened a sentence would qualify.
    ///
    /// Multi-word phrases skip all of this: "paper white" and "font design"
    /// are not what these rules are aimed at.
    static func worthLookingUp(_ query: String, spokenIn text: String) -> Bool {
        let normalized = Mention.normalize(query)
        guard !normalized.isEmpty else { return false }
        // Said, allowing for the transcriber's spacing and punctuation.
        guard Mention.normalize(text).contains(normalized) else { return false }

        let words = normalized.split(separator: " ").map(String.init)
        guard words.count == 1, let word = words.first else { return true }
        if genericWords.contains(word) { return false }
        guard isEverydayWord(word) else { return true }
        // There was briefly a bypass here letting any ordinary word of eight
        // letters or more through, on the theory that a long word is a subject
        // word. Length is not that signal. It admitted "happening" from "what
        // is happening right now?", and would have admitted "everything",
        // "something", "different", "important" and "beginning" - measured, all
        // nine or ten letters, all in the dictionary. One real class produced
        // exactly one prompt and it was "happening". Reverted.
        return usedAsAName(query, in: text)
    }

    /// True when the sentence actually asks about a word, rather than merely
    /// containing one.
    ///
    /// A definition card is only ever right when the teacher is asking or
    /// explaining what something means. Without this, the model labels any
    /// noun-shaped word a `.word` and the class gets a dictionary entry for
    /// "happening" out of "what is happening right now?". The dictionary path
    /// sends nothing off the Mac, which is exactly why it needed a rule of its
    /// own: the request filters do not apply to it and it looked free.
    static func asksAboutTheWord(_ query: String, in text: String) -> Bool {
        let name = NSRegularExpression.escapedPattern(for: query)
        let tells = [
            #"(?i)\bwhat\s+(?:does|do)\s+"# + name + #"\s+mean\b"#,
            #"(?i)\bwhat\s+is\s+(?:the\s+)?meaning\s+of\s+"# + name + #"\b"#,
            #"(?i)\bmeaning\s+of\s+(?:the\s+word\s+)?"# + name + #"\b"#,
            #"(?i)\bthe\s+word\s+"# + name + #"\b"#,
            #"(?i)\b"# + name + #"\s+means\b"#,
            #"(?i)\bdefine\s+"# + name + #"\b"#,
            #"(?i)\bcalled\s+"# + name + #"\b"#
        ]
        return tells.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// True when someone is being quoted, rather than merely talking.
    ///
    /// The word-pattern detector has always required this: its quote cue is
    /// built around "quote", "famous line", "as he said". The model was under
    /// no such obligation and simply labelled things `.quote`, so a greeting
    /// became a quotation - "Hello, how is everyone today?" was served the
    /// Wikiquote page for How to Train Your Dragon in a live class. A word
    /// count does not separate those: the greeting is five words and "As a
    /// woman like that was really into me" is nine, and both are wrong. What
    /// separates them is whether anybody said a quotation was coming.
    static func hasRecitationCue(_ text: String) -> Bool {
        let pattern = #"(?i)\b(quot(?:e|es|ed|ing|ation|ations)|famous (?:line|lines|words|saying|speech)|as (?:he|she|they) (?:said|says|put it|wrote)|in (?:his|her|their) words|the line goes|to borrow a phrase)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The share of a batch's words that are English, by the Mac's dictionary.
    ///
    /// The one signal that separates a lesson from the noise around it. This
    /// class is taught in Indian English with Tamil mixed in, and there is no
    /// Tamil speech model on this platform, so Tamil arrives as plausible
    /// English-looking nonsense: "Eppudu, Orukuntu, Indha, veyyil, Kayam."
    /// Measured on real sentences, the separation is total - the Tamil ones
    /// score 0% and the English ones 83-100%.
    static func englishRatio(_ text: String) -> Double {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count > 1 }
        guard !tokens.isEmpty else { return 0 }
        return Double(tokens.filter { isEverydayWord($0) }.count) / Double(tokens.count)
    }

    /// In the Mac's own dictionary, so an ordinary English word.
    static func isEverydayWord(_ word: String) -> Bool {
        let lowered = word.lowercased()
        let range = CFRange(location: 0, length: lowered.utf16.count)
        guard let definition = DCSCopyTextDefinition(nil, lowered as CFString, range)?.takeRetainedValue() as String? else { return false }
        return !definition.isEmpty
    }

    /// Capitalised somewhere that is not the start of a sentence.
    static func usedAsAName(_ query: String, in text: String) -> Bool {
        let capitalized = query.prefix(1).uppercased() + query.dropFirst().lowercased()
        let pattern = "(?<![.!?]\\s)(?<!^)\\b" + NSRegularExpression.escapedPattern(for: capitalized) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Words that are never a thing to look up on their own: the places the
    /// teacher is looking, not what they found there.
    private static let blocklist: Set<String> = [
        "youtube", "google", "internet", "zoom", "online", "video", "book", "story", "class", "screen", "page",
        "this", "that", "it", "one", "something", "anything", "everything", "nothing", "here", "there"
    ]

    /// What follows a tell, up to a boundary. `[^.,;!?]` runs to the next
    /// punctuation; trimToTitle then cuts at the first stop word.
    private static let span = #"["“]?([A-Za-z][^.,;!?"”]{2,60}?)["”]?"#

    /// One spoken tell.
    ///
    /// `guarded` sends what the cue captured through `worthLookingUp` before it
    /// counts. Almost no cue wants that: when the teacher says "the word
    /// pabulum" or "a video about volcanoes", the tell IS the evidence, and the
    /// phrase being an ordinary English word is not a reason to ignore a direct
    /// request. Measured - applying the guard everywhere held precision at 100%
    /// and dropped recall from 100% to 80%, losing photosynthesis, volcanoes
    /// and all three definition cases.
    ///
    /// The exception is the cues that INFER a subject from a question instead
    /// of being handed one. "What is monospace?" and "What is happening right
    /// now?" are the same shape, and only the ordinariness of the word tells
    /// them apart.
    private struct Cue {
        let pattern: String
        let kind: Mention.Kind
        let confidence: Double
        var guarded = false
    }

    /// A tell → a kind. Case-insensitivity is scoped to the tell words with
    /// `(?i:…)`; a blanket `(?i)` would make `[A-Z]` match anything.
    private static let cues: [Cue] = [
        // Named things: "it's called X", "they call it X", "X, they call it",
        // "a tool called X", "invented by Amazon called X", "X is a tool".
        Cue(pattern: #"\b(?i:it's|it is|this is|which is|that's|that is|that was|it was|this one is|the tool is|the app is|the site is) (?i:called|named) "# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.75),
        Cue(pattern: #"\b(?i:they call it|we call it|people call it|everyone calls it|you call it) "# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.7),
        Cue(pattern: #"(?<=[.,;!?] |^)([A-Za-z][A-Za-z0-9']*(?: [A-Za-z][A-Za-z0-9']*){0,2}),? (?i:they call it|we call it)\b"#, kind: .thing, confidence: 0.7),
        Cue(pattern: #"\b(?i:a|an|the|this|that) (?i:tool|app|website|site|device|product|technology|company|service|platform|software|library|game|font|typeface|gadget) (?i:called|named) "# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.8),
        Cue(pattern: #"\b(?i:invented|created|made|developed|built|founded|launched) by [A-Za-z][A-Za-z0-9' ]{1,30}? (?i:called|named) "# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.8),
        Cue(pattern: #"(?<=[.,;!?] |^)([A-Za-z][A-Za-z0-9' ]{2,30}?) (?i:is|was) (?i:a|an) (?:[a-z]+ ){0,2}(?i:tool|app|website|site|device|product|technology|company|service|platform|software|library|gadget)\b"#, kind: .thing, confidence: 0.6),
        Cue(pattern: #"\b(?i:i would like to introduce|let me introduce|i want to introduce|introducing)(?: (?i:you to|this|to you))?(?: (?i:chap|guy|tool|app|website|site|thing|one))?[.,]?\s*(?:(?i:um|uh|okay|ok|so|yeah),?\s*)*"# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.65),
        // Words: "the word X", "meaning of X", "what does X mean", "X means".
        Cue(pattern: #"\b(?i:the word) ["“]([A-Za-z][a-z-]{3,30})["”]"#, kind: .word, confidence: 0.75),
        Cue(pattern: #"\b(?i:the word) ([A-Za-z][a-z-]{3,30}) (?i:means|is|comes from)\b"#, kind: .word, confidence: 0.7),
        Cue(pattern: #"\b(?i:meaning of|the meaning of the word|definition of|define) ["“]?([A-Za-z][a-z-]{3,30})["”]?"#, kind: .word, confidence: 0.75),
        Cue(pattern: #"\b(?i:what does) ["“]?([A-Za-z][a-z-]{3,30})["”]? (?i:mean)\b"#, kind: .word, confidence: 0.75),
        // Quotations: the sentence after the one that says "quote" (skipping a
        // bare attribution like "Kennedy." and fillers), taken whole. The
        // phrase itself is the query.
        Cue(pattern: #"\b(?i:quot(?:e|es|ation|ations)|famous (?:line|lines|words|saying)|as (?:he|she|they) (?:said|says|put it))\b[^.?!]*[.?!]\s*(?:[A-Z][A-Za-z.'-]+(?: [A-Z][A-Za-z.'-]+)?[.!]\s*)?(?:(?i:and so|so|um|uh|okay|ok),?\s*)?([^.?!]{25,160})"#, kind: .quote, confidence: 0.7),
        // Books: "the book called X", quoted titles after read/reading.
        Cue(pattern: #"\b(?i:the|a|this|that) (?i:book|story|novel|picture book|storybook) (?i:called|named|titled) "# + span + #"(?=[.,;!?]|$)"#, kind: .book, confidence: 0.8),
        Cue(pattern: #"\b(?i:reading|read|finished|started) (?i:the book |a book |the story )?["“]([^"”]{2,60})["”]"#, kind: .book, confidence: 0.75),
        Cue(pattern: #"\b(?i:book|story|novel) ["“]([^"”]{2,60})["”]"#, kind: .book, confidence: 0.75),
        // Videos and articles: "a video about X", "articles and videos about
        // why X", "I watched a video about X".
        Cue(pattern: #"\b(?i:a|the|this|some) (?i:video|videos|clip|documentary|cartoon|film|movie|talk|ted talk) (?i:about|called|of|on) (?i:why |how |what )?"# + span + #"(?=[.,;!?]|$)"#, kind: .video, confidence: 0.75),
        Cue(pattern: #"\b(?i:i|we) (?i:watched|saw) (?i:a |the )?(?i:video|clip|documentary|cartoon|film|movie)?(?: (?i:on youtube))? (?i:about|called|of) "# + span + #"(?=[.,;!?]|$)"#, kind: .video, confidence: 0.7),
        Cue(pattern: #"\b(?i:articles?|blogs?|posts?|papers?|essays?)(?:[^.?!]{0,30}?(?i:videos?))?[^.?!]{0,12}? (?i:about|on) (?i:why |how |what )?"# + span + #"(?=[.,;!?]|$)"#, kind: .video, confidence: 0.65),
        // Topics: "let's talk about X", "what is X?", "fonts such as X and Y".
        Cue(pattern: #"\b(?i:let's|let us) (?i:talk|learn|read) (?i:about) "# + span + #"(?=[.,;!?]|$)"#, kind: .topic, confidence: 0.6),
        Cue(pattern: #"\b(?i:do you know) (?i:what|about) (?i:a |an |the )?([^.,;!?]{2,40}?) (?i:is|are|means|was)\b"#, kind: .topic, confidence: 0.55, guarded: true),
        Cue(pattern: #"\b(?i:what) (?i:is|are) (?i:a |an |the )?([^.,;!?]{2,40}?)\?"#, kind: .topic, confidence: 0.5, guarded: true),
        Cue(pattern: #"\b(?i:fonts?|typefaces?|font families|families) (?i:such as|like) ([A-Z][a-z]+(?:,? (?:(?i:and|or) )?[A-Z][a-z]+){0,3})"#, kind: .topic, confidence: 0.65),
        // People: "written by X", "the author X". Two words minimum, always.
        Cue(pattern: #"\b(?i:written|book|story|novel|poem|by the author|author) (?i:by) ((?:[A-Z]\. ?)*[A-Z][a-z]+(?: [A-Z]\.)*(?: [A-Z][a-z]+){1,2})"#, kind: .person, confidence: 0.75),
        Cue(pattern: #"\b(?i:the author|the writer|the poet|the scientist|the artist|the president|the king|the queen|the designer) ([A-Z][a-z]+(?: [A-Z][a-z]+){1,2})"#, kind: .person, confidence: 0.7),
        // Places: "the country called X".
        Cue(pattern: #"\b(?i:the country|the city|the river|the mountain|the ocean|the continent|the state|the planet) (?i:of |called )?([A-Z][A-Za-z]+(?: [A-Z][A-Za-z]+){0,2})"#, kind: .place, confidence: 0.7)
    ]

    func detect(newText: String, context: String, excludedNames: [String]) async throws -> [Mention] {
        let text = Self.clean(newText)
        guard text.split(whereSeparator: \.isWhitespace).count >= 3 else { return [] }
        var found: [Mention] = []

        // The tell for a quotation is often the sentence BEFORE the line
        // ("Ask not what quote. Kennedy.") and can fall in the previous batch,
        // so the quote cue alone also sees the last words of the lead-in.
        let lead = Self.clean(context).split(separator: " ").suffix(14).joined(separator: " ")
        let withLead = lead.isEmpty ? text : lead + " " + text

        for cue in Self.cues {
            guard let regex = try? NSRegularExpression(pattern: cue.pattern) else { continue }
            let haystack = cue.kind == .quote ? withLead : text
            let range = NSRange(haystack.startIndex..., in: haystack)
            for match in regex.matches(in: haystack, range: range) where match.numberOfRanges > 1 {
                guard let captured = Range(match.range(at: 1), in: haystack) else { continue }
                let raw = String(haystack[captured])
                if cue.kind == .quote {
                    // Only a line that is (at least partly) new text counts.
                    guard haystack.distance(from: haystack.startIndex, to: captured.upperBound) > (withLead.count - text.count) else { continue }
                    guard let query = Self.acceptableQuote(raw) else { continue }
                    found.append(Mention(kind: .quote, query: query, confidence: cue.confidence))
                    continue
                }
                // "fonts such as Tahoma and Verdana" is two topics.
                let pieces = cue.kind == .topic && raw.contains(where: { $0 == "," }) || raw.range(of: " and ", options: .caseInsensitive) != nil && cue.kind == .topic
                    ? raw.components(separatedBy: CharacterSet(charactersIn: ",")).flatMap { $0.components(separatedBy: " and ") }
                    : [raw]
                for piece in pieces {
                    let phrase = Self.trimToTitle(piece)
                    guard let query = Self.acceptable(phrase, kind: cue.kind) else { continue }
                    // A named thing said next to "book", "story" or "novel" is a book.
                    var kind = cue.kind
                    if kind == .thing, Self.nearby(text, captured, words: ["book", "novel", "story", "storybook"]) { kind = .book }
                    if kind == .thing, Self.nearby(text, captured, words: ["movie", "film", "documentary"]) { kind = .video }
                    let finalQuery = Self.extended(query, in: text)
                    // Only the cues that inferred a subject from a question
                    // have to prove the phrase is not ordinary English. See Cue.
                    if cue.guarded, !Self.worthLookingUp(finalQuery, spokenIn: text) { continue }
                    found.append(Mention(kind: kind, query: finalQuery, confidence: cue.confidence))
                }
            }
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
            // Any mention sharing a token with a roster name is dropped, whatever
            // its kind: the tagger is gone, but a cue can still capture a name.
            if mention.kind != .quote, tokens.contains(where: { excludedTokens.contains($0) }) { continue }
            if let existing = byKey[key] {
                // "It's called apprenticeship patterns ... book": the book wins
                // over the generic thing whatever the confidences say.
                if existing.kind != .thing && mention.kind == .thing { continue }
                if existing.kind == .thing && mention.kind != .thing { byKey[key] = mention; continue }
                if existing.confidence >= mention.confidence { continue }
            }
            byKey[key] = mention
        }
        // Two cues can capture the same thing at different lengths. Keep the
        // tighter one - the multi-word title inside "the book called X" - but
        // when the contained one is a single word ("haiku" inside "haiku
        // deck") keep the longer, which is the real name.
        let keys = Array(byKey.keys)
        for key in keys {
            guard let mention = byKey[key] else { continue }
            for other in keys where other != key && byKey[other] != nil && byKey[other]?.kind == mention.kind {
                let padded = " " + key + " "
                if other.count < key.count, padded.contains(" " + other + " ") {
                    if other.split(separator: " ").count >= 2 { byKey.removeValue(forKey: key) } else { byKey.removeValue(forKey: other) }
                }
            }
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

    /// "Um, haiku. haiku deck." - a single captured word that the text also
    /// says as the first half of a two-word name becomes that name.
    private static func extended(_ query: String, in text: String) -> String {
        guard !query.contains(" ") else { return query }
        let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: query) + " ([A-Za-z][A-Za-z0-9']+)(?=[.,;!?]|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return query }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let next = Range(match.range(at: 1), in: text) else { continue }
            let word = String(text[next])
            if !stopWords.contains(word.lowercased()), !hardStops.contains(word.lowercased()) { return query + " " + word }
        }
        return query
    }

    /// Whether one of `words` appears within 60 characters of a capture.
    private static func nearby(_ text: String, _ range: Range<String.Index>, words: [String]) -> Bool {
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        let window = text[start..<end].lowercased()
        return words.contains { window.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    /// Cuts a capture at the first hard stop after the first word or the first
    /// soft stop after the second, and strips trailing filler.
    private static func trimToTitle(_ raw: String) -> String {
        var words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”',"))
            .replacingOccurrences(of: ",", with: "")
            .split(separator: " ").map(String.init)
        // Fillers the transcriber writes at the start of a phrase.
        while let first = words.first, ["um", "uh", "so", "okay", "ok", "yeah"].contains(first.lowercased()) { words.removeFirst() }
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
        let pronouns = ["i", "you", "we", "they", "he", "she", "it", "me", "us", "them", "him", "her", "my", "your", "our", "their"]
        if pronouns.contains(trimmed.lowercased()) { return nil }
        if let first = words.first?.lowercased(), pronouns.contains(first) || stopWords.contains(first) { return nil }
        // Mostly filler ("a, a, successful") is a transcriber stumble, not a name.
        let fillers = words.filter { stopWords.contains($0.lowercased()) || $0.count == 1 }.count
        if words.count >= 3, fillers * 2 > words.count { return nil }
        return trimmed
    }

    /// A quotation is kept whole; only the wrapping is tidied.
    private static func acceptableQuote(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”',"))
        // The batch may have run on into the teacher's own commentary; keep
        // the first clause group.
        if let cut = text.range(of: #",\s*(?i:no|okay|ok|so|but|because)\b"#, options: .regularExpression) {
            text = String(text[..<cut.lowerBound])
        }
        let words = text.split(separator: " ")
        guard words.count >= 5, words.count <= 30 else { return nil }
        return text
    }
}
