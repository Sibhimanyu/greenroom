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
//  behind those numbers are kept OUTSIDE this repo (~/CuesBench-evidence)
//  because they are a real class with children's names in them.
//
import Foundation
import NaturalLanguage

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
/// Phase 3 of docs/cues-search-improvement-plan.md: the model is a
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
        // The speaker's own name joins the roster before either detector runs:
        // the model is told the names to avoid, so it has to be told this one too.
        let excludedNames = excludedNames + HeuristicDetector.selfIntroducedNames(in: context + " " + newText)
        let byPattern = try await patterns.detect(newText: newText, context: context,
                                                  excludedNames: excludedNames)
        guard byPattern.isEmpty else { return byPattern }
        // A batch that is not English is not a batch to mine for named things.
        //
        // The patterns are safe here on their own - they need English tell words
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
    /// Where the Debug workbench hears why a captured phrase was thrown away.
    /// Nil in a class, so nothing is built or sent.
    static var traceDrop: ((String) -> Void)?

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
        "tonight", "before", "after", "during", "until", "now",
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

    /// Words that mean this phrase is a scrap of talk, not the name of a thing.
    ///
    /// Pronouns, auxiliaries, demonstratives and interrogatives. A named thing
    /// does not contain them; a sentence the model sliced out of the class
    /// almost always does.
    private static let conversationalWords: Set<String> = [
        "i", "me", "my", "mine", "myself", "you", "your", "yours", "he", "him", "his",
        "she", "her", "hers", "it", "its", "we", "us", "our", "ours", "they", "them",
        "their", "theirs",
        "am", "is", "are", "was", "were", "be", "been", "being", "do", "does", "did",
        "dont", "doesnt", "didnt", "have", "has", "had", "will", "would", "shall",
        "should", "can", "could", "may", "might", "must", "need", "needs", "needed",
        "not", "cant", "wont", "thats", "im", "like", "just",
        "what", "how", "why", "when", "where", "who", "whom", "which",
        "this", "that", "these", "those", "other", "another", "such", "every", "most",
        "imagine", "meant", "heard", "think", "thought", "know", "want", "happens",
        "happen", "happening", "impacts", "submitted"
    ]

    /// True when a query reads as the name of a thing.
    ///
    /// The model is asked for named things and mostly obliges, but on 43
    /// minutes of real class it also returned "you don't need to care", "this
    /// is what I heard me", "Other number" and "how people with them" - talk it
    /// had sliced into noun-shaped pieces. `worthLookingUp` never saw them: it
    /// only judges SINGLE words, so every multi-word fragment passed
    /// unconditionally. Two properties separate the 82 links that class
    /// produced into the 11 worth having and the rest: a named thing is short,
    /// and it does not contain the words people use to talk about things.
    static func namesAThing(_ query: String) -> Bool {
        let words = Mention.normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return false }
        return !words.contains(where: { conversationalWords.contains($0) })
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
    /// The word-pattern detector has always required this: its quote tell is
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
    /// `guarded` sends what the tell captured through `worthLookingUp` before it
    /// counts. Almost no tell wants that: when the teacher says "the word
    /// pabulum" or "a video about volcanoes", the tell IS the evidence, and the
    /// phrase being an ordinary English word is not a reason to ignore a direct
    /// request. Measured - applying the guard everywhere held precision at 100%
    /// and dropped recall from 100% to 80%, losing photosynthesis, volcanoes
    /// and all three definition cases.
    ///
    /// The exception is the tells that INFER a subject from a question instead
    /// of being handed one. "What is monospace?" and "What is happening right
    /// now?" are the same shape, and only the ordinariness of the word tells
    /// them apart.
    private struct Tell {
        let pattern: String
        let kind: Mention.Kind
        let confidence: Double
        var guarded = false
        /// The tell is a way of TALKING about something ("talk about X",
        /// "heard of X") rather than a way of naming it, so the captured phrase
        /// must itself read as a name. See `readsAsAName`.
        var nameShaped = false
        /// One of the category tells, so the noun it matched is worth keeping.
        var namesCategory = false
    }

    /// A tell → a kind. Case-insensitivity is scoped to the tell words with
    /// `(?i:…)`; a blanket `(?i)` would make `[A-Z]` match anything.
    private static let tells: [Tell] = baseTells + categoryTells + discourseTells

    private static let baseTells: [Tell] = [
        // Named things: "it's called X", "they call it X", "X, they call it",
        // "a tool called X", "invented by Amazon called X", "X is a tool".
        Tell(pattern: #"\b(?i:it's|it is|this is|which is|that's|that is|that was|it was|this one is|the tool is|the app is|the site is) (?i:called|named) "# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.75),
        Tell(pattern: #"\b(?i:they call it|we call it|people call it|everyone calls it|you call it) "# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.7),
        Tell(pattern: #"(?<=[.,;!?] |^)([A-Za-z][A-Za-z0-9']*(?: [A-Za-z][A-Za-z0-9']*){0,2}),? (?i:they call it|we call it)\b"#, kind: .thing, confidence: 0.7),
        Tell(pattern: #"\b(?i:a|an|the|this|that) (?i:tool|app|website|site|device|product|technology|company|service|platform|software|library|game|font|typeface|gadget) (?i:called|named) "# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.8),
        Tell(pattern: #"\b(?i:invented|created|made|developed|built|founded|launched) by [A-Za-z][A-Za-z0-9' ]{1,30}? (?i:called|named) "# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.8),
        Tell(pattern: #"(?<=[.,;!?] |^)([A-Za-z][A-Za-z0-9' ]{2,30}?) (?i:is|was) (?i:a|an) (?:[a-z]+ ){0,2}(?i:tool|app|website|site|device|product|technology|company|service|platform|software|library|gadget)\b"#, kind: .thing, confidence: 0.6),
        Tell(pattern: #"\b(?i:i would like to introduce|let me introduce|i want to introduce|introducing)(?: (?i:you to|this|to you))?(?: (?i:chap|guy|tool|app|website|site|thing|one))?[.,]?\s*(?:(?i:um|uh|okay|ok|so|yeah),?\s*)*"# + span + #"(?=[.,;!?]|$)"#, kind: .thing, confidence: 0.65),
        // Words: "the word X", "meaning of X", "what does X mean", "X means".
        Tell(pattern: #"\b(?i:the word) ["“]([A-Za-z][a-z-]{3,30})["”]"#, kind: .word, confidence: 0.75),
        Tell(pattern: #"\b(?i:the word) ([A-Za-z][a-z-]{3,30}) (?i:means|is|comes from)\b"#, kind: .word, confidence: 0.7),
        Tell(pattern: #"\b(?i:meaning of|the meaning of the word|definition of|define) ["“]?([A-Za-z][a-z-]{3,30})["”]?"#, kind: .word, confidence: 0.75),
        Tell(pattern: #"\b(?i:what does) ["“]?([A-Za-z][a-z-]{3,30})["”]? (?i:mean)\b"#, kind: .word, confidence: 0.75),
        // Quotations: the sentence after the one that says "quote" (skipping a
        // bare attribution like "Kennedy." and fillers), taken whole. The
        // phrase itself is the query.
        Tell(pattern: #"\b(?i:quot(?:e|es|ation|ations)|famous (?:line|lines|words|saying)|as (?:he|she|they) (?:said|says|put it))\b[^.?!]*[.?!]\s*(?:[A-Z][A-Za-z.'-]+(?: [A-Z][A-Za-z.'-]+)?[.!]\s*)?(?:(?i:and so|so|um|uh|okay|ok),?\s*)?([^.?!]{25,160})"#, kind: .quote, confidence: 0.7),
        // Books: "the book called X", quoted titles after read/reading.
        Tell(pattern: #"\b(?i:the|a|this|that) (?i:book|story|novel|picture book|storybook) (?i:called|named|titled) "# + span + #"(?=[.,;!?]|$)"#, kind: .book, confidence: 0.8),
        Tell(pattern: #"\b(?i:reading|read|finished|started) (?i:the book |a book |the story )?["“]([^"”]{2,60})["”]"#, kind: .book, confidence: 0.75),
        Tell(pattern: #"\b(?i:book|story|novel) ["“]([^"”]{2,60})["”]"#, kind: .book, confidence: 0.75),
        // Videos and articles: "a video about X", "articles and videos about
        // why X", "I watched a video about X".
        Tell(pattern: #"\b(?i:a|the|this|some) (?i:video|videos|clip|documentary|cartoon|film|movie|talk|ted talk) (?i:about|called|of|on) (?i:why |how |what )?"# + span + #"(?=[.,;!?]|$)"#, kind: .video, confidence: 0.75),
        Tell(pattern: #"\b(?i:i|we) (?i:watched|saw) (?i:a |the )?(?i:video|clip|documentary|cartoon|film|movie)?(?: (?i:on youtube))? (?i:about|called|of) "# + span + #"(?=[.,;!?]|$)"#, kind: .video, confidence: 0.7),
        Tell(pattern: #"\b(?i:articles?|blogs?|posts?|papers?|essays?)(?:[^.?!]{0,30}?(?i:videos?))?[^.?!]{0,12}? (?i:about|on) (?i:why |how |what )?"# + span + #"(?=[.,;!?]|$)"#, kind: .video, confidence: 0.65),
        // Topics: "let's talk about X", "what is X?", "fonts such as X and Y".
        Tell(pattern: #"\b(?i:let's|let us) (?i:talk|learn|read) (?i:about) "# + span + #"(?=[.,;!?]|$)"#, kind: .topic, confidence: 0.6),
        Tell(pattern: #"\b(?i:do you know) (?i:what|about) (?i:a |an |the )?([^.,;!?]{2,40}?) (?i:is|are|means|was)\b"#, kind: .topic, confidence: 0.55, guarded: true),
        Tell(pattern: #"\b(?i:what) (?i:is|are) (?i:a |an |the )?([^.,;!?]{2,40}?)\?"#, kind: .topic, confidence: 0.5, guarded: true),
        Tell(pattern: #"\b(?i:fonts?|typefaces?|font families|families) (?i:such as|like) ([A-Z][a-z]+(?:,? (?:(?i:and|or) )?[A-Z][a-z]+){0,3})"#, kind: .topic, confidence: 0.65),
        // People: "written by X", "the author X". Two words minimum, always.
        Tell(pattern: #"\b(?i:written|book|story|novel|poem|by the author|author) (?i:by) ((?:[A-Z]\. ?)*[A-Z][a-z]+(?: [A-Z]\.)*(?: [A-Z][a-z]+){1,2})"#, kind: .person, confidence: 0.75),
        Tell(pattern: #"\b(?i:the author|the writer|the poet|the scientist|the artist|the president|the king|the queen|the designer) ([A-Z][a-z]+(?: [A-Z][a-z]+){1,2})"#, kind: .person, confidence: 0.7),
        // Places: "the country called X".
        Tell(pattern: #"\b(?i:the country|the city|the river|the mountain|the ocean|the continent|the state|the planet) (?i:of |called )?([A-Z][A-Za-z]+(?: [A-Z][A-Za-z]+){0,2})"#, kind: .place, confidence: 0.7)
    ]


    // MARK: Categories and discourse

    /// What a speaker calls a kind of thing, and the card kind it becomes.
    ///
    /// The tells above were each written for one sentence heard in one class,
    /// so each knows five or six nouns. A teacher testing Cues said "the brand
    /// called imago" and got nothing, because "brand" was not one of them. The
    /// grammar is the same whatever the noun, so the nouns are one list and
    /// the grammar is written once.
    static let categories: [(nouns: [String], kind: Mention.Kind)] = [
        (["book", "novel", "story", "storybook", "picture book", "textbook", "comic", "comic book",
          "graphic novel", "manga", "poem", "biography", "autobiography"], .book),
        (["movie", "film", "documentary", "video", "cartoon", "anime", "tv show", "show", "series",
          "song", "album", "podcast", "channel", "trailer", "ted talk"], .video),
        (["brand", "company", "startup", "app", "application", "tool", "software", "program", "programme",
          "website", "site", "platform", "product", "device", "gadget", "game", "service", "font",
          "typeface", "language", "framework", "library", "magazine", "newspaper", "blog", "band",
          "robot", "phone", "laptop", "camera", "car", "extension", "plugin", "plug-in", "chatbot", "model"], .thing),
        (["author", "writer", "poet", "artist", "scientist", "singer", "actor", "actress", "designer",
          "inventor", "youtuber", "painter", "musician", "athlete", "director", "entrepreneur"], .person),
        (["city", "town", "country", "village", "river", "mountain", "lake", "island", "planet",
          "museum", "place", "state"], .place)
    ]

    private static func alternation(_ nouns: [String]) -> String {
        // Longest first, so "comic book" is tried before "comic".
        nouns.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s") }
            .joined(separator: "|")
    }

    /// Verbs that introduce a thing the speaker is about to name.
    private static let introducers = "heard of|hear of|heard about|know|knows|read|reading|recommend|recommended|tried|try|use|using|used|love|loved|like|liked|check out|checked out|look at|looked at|watch|watched|about|introduce|introducing|found|discovered|download|downloaded|install|installed"

    /// One grammar, every category:
    ///   "a brand called imago", "the new app named Notion"      (called/named)
    ///   "heard of the book, Adobe Illustrator?"                  (appositive)
    ///   "have you read the book Wonder"                           (bare, capitalised)
    private static let categoryTells: [Tell] = categories.flatMap { group -> [Tell] in
        let nouns = alternation(group.nouns)
        let determiner = #"(?i:the|a|an|this|that|one|my|our|his|her|their|another)"#
        let adjectives = #"(?: [a-z][a-z-]+){0,2}"#
        return [
            Tell(pattern: #"\b"# + determiner + adjectives + #" (?i:"# + nouns + #") (?i:called|named|titled|known as|by the name of|by the name)\s*,?\s*"# + span + #"(?=[.,;!?]|$)"#,
                 kind: group.kind, confidence: 0.8, namesCategory: true),
            // The appositive only after "the", "this" or "that" and straight
            // onto the noun: "heard of the book, Wonder?". With an article
            // and adjectives it is ordinary talk that happens to reach a
            // comma - "use a large enough font, create enough contrast"
            // came out of a real class as a thing to look up.
            Tell(pattern: #"\b(?i:"# + introducers + #") (?i:the|this|that) (?i:"# + nouns + #"),\s*"# + span + #"(?=[.,;!?]|$)"#,
                 kind: group.kind, confidence: 0.75, namesCategory: true),
            Tell(pattern: #"\b(?i:"# + introducers + #") "# + determiner + adjectives + #" (?i:"# + nouns + #") ["“]?([A-Z][A-Za-z0-9'&-]*(?: (?:[A-Z][A-Za-z0-9'&-]*|of|the|and|a|in|to)){0,5})["”]?(?=[.,;!?]|$| (?i:by|which|that|and|is|was|about))"#,
                 kind: group.kind, confidence: 0.75, namesCategory: true),
            // The name first, then what it is: "Adobe Photoshop, that is more
            // of an image editing software", "Canva, which is a design tool".
            // Capitalised, because nothing before it says a name is coming.
            Tell(pattern: #"\b([A-Z][A-Za-z0-9'&-]*(?: [A-Z][A-Za-z0-9'&-]*){0,3}),? (?i:that|which|it|this) (?i:is|was|'s) (?i:more of |kind of |sort of |basically |also |just |really |actually )?(?i:a|an) (?:[a-z-]+ ){0,3}(?i:"# + nouns + #")\b"#,
                 kind: group.kind, confidence: 0.7, namesCategory: true)
        ]
    }

    /// The last category noun said before a capture: "a new brand called X"
    /// gives "brand".
    private static func category(before capture: Range<String.Index>, from start: String.Index, in text: String) -> String? {
        let lead = String(text[start..<capture.lowerBound]).lowercased()
        var best: (noun: String, at: String.Index)?
        for noun in categories.flatMap(\.nouns) {
            guard let found = lead.range(of: "\\b" + NSRegularExpression.escapedPattern(for: noun) + "\\b",
                                         options: [.regularExpression, .backwards]) else { continue }
            if best == nil || found.lowerBound > best!.at || (found.lowerBound == best!.at && noun.count > best!.noun.count) {
                best = (noun, found.lowerBound)
            }
        }
        return best?.noun
    }

    /// Ways of talking about something that do not say what kind it is:
    /// "I'm going to talk about Adobe Illustrator", "have you heard of
    /// Canva?". Nothing in the tell says a name follows, so the phrase has to
    /// look like one on its own - see `readsAsAName`.
    private static let discourseTells: [Tell] = [
        Tell(pattern: #"\b(?i:talk|talking|talked|speak|speaking|present|presenting|tell you|telling you) (?i:about|on) "# + span + #"(?=[.,;!?]|$)"#,
             kind: .topic, confidence: 0.6, nameShaped: true),
        Tell(pattern: #"\b(?i:heard of|hear of|heard about|check out|checking out|look up|looking up|search for|searching for|google|googled|introduce you to|try out|trying out|download|downloaded|install|installed|signed up for|sign up for) "# + span + #"(?=[.,;!?]|$)"#,
             kind: .thing, confidence: 0.6, nameShaped: true)
    ]

    /// Words that start a capitalised phrase that is still not a subject:
    /// the parts of a lesson, and the calendar.
    private static let notASubject: Set<String> = [
        "chapter", "page", "lesson", "unit", "part", "section", "slide", "question", "exercise",
        "number", "step", "class", "grade", "table", "figure", "activity", "homework", "task",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", "mr", "mrs", "ms", "miss", "sir", "madam"
    ]

    /// True when a phrase captured by a discourse tell reads as the name of
    /// something, not as talk.
    ///
    /// Capitals, but not capitals alone. Every word has to start with one
    /// where it was said (small joining words aside), the phrase must pass
    /// `namesAThing`, and it must not be a lesson part, a day or a month. A
    /// single word also has to not be a person's first name by the tagger's
    /// reckoning: "I heard of Rahul" is about a person nobody can look up.
    /// The class this was all learned from is Indian English with Tamil
    /// mixed in and capitalises Tamil freely, so these tells only run on a
    /// batch that is mostly English at all.
    static func readsAsAName(_ query: String, in text: String) -> Bool {
        guard namesAThing(query) else { return false }
        let joiners: Set<String> = ["of", "the", "and", "a", "an", "in", "to", "for", "on", "de"]
        let words = query.split(separator: " ").map(String.init)
        guard let first = words.first, !notASubject.contains(first.lowercased()) else { return false }
        let capitalised = words.allSatisfy { word in
            joiners.contains(word.lowercased()) || word.first.map { $0.isUppercase || $0.isNumber } == true
        }
        guard capitalised, words.first?.first?.isUppercase == true else { return false }
        if words.count == 1 {
            if blocklist.contains(first.lowercased()) || genericWords.contains(first.lowercased()) { return false }
            if isPersonalName(first, in: text) { return false }
        }
        return true
    }

    /// The Mac's name tagger, asked about one word in its sentence.
    static func isPersonalName(_ word: String, in text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, text[range].split(separator: " ").contains(where: { $0 == word }) {
                found = true
                return false
            }
            return true
        }
        return found
    }

    /// True when the text names `query` with an explicit tell right before it:
    /// "the brand called imago", "an app named Notion", "the book, Wonder".
    ///
    /// For the model's output. Its single-word finds go through
    /// `worthLookingUp`, which drops an ordinary dictionary word said in lower
    /// case - correct for "happening", wrong for "the brand called imago",
    /// where the speaker said outright that the word is a name.
    static func namedByATell(_ query: String, in text: String) -> Bool {
        let name = NSRegularExpression.escapedPattern(for: query)
        let nouns = alternation(categories.flatMap(\.nouns))
        let pattern = #"(?i)\b(?:called|named|titled|known as|(?:"# + nouns + #"),?)\s+["“]?"# + name + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: The speaker's own name

    /// Names people give for themselves: "my name is Sibi", "I'm Sibi and…".
    ///
    /// The roster keeps everyone in the meeting out of every query, but a
    /// teacher introducing themselves is not in their own roster, and a
    /// Try-it run has no roster at all. The model turned "my name is Sibi"
    /// into a TOPIC card for a Wikipedia page about a different Sibi. A name
    /// said this way is a person in the room, and joins the exclusions.
    static func selfIntroducedNames(in text: String) -> [String] {
        let patterns = [
            #"\b(?i:my name is|my name's|i am called|call me|this is) ([A-Z][a-z]+(?: [A-Z][a-z]+)?)(?! (?i:is|was|app|tool|book))"#,
            #"\b(?i:i'm|i am|it's|it is) ([A-Z][a-z]+)(?=[,.!?]| (?i:and|from|here|speaking|your|the)\b)"#
        ]
        var names: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[range])
                // "I'm Happy", "call me Crazy": a dictionary word is a mood, not a name.
                if name.split(separator: " ").count == 1, isEverydayWord(name) { continue }
                names.append(name)
            }
        }
        return names
    }

    func detect(newText: String, context: String, excludedNames: [String]) async throws -> [Mention] {
        let text = Self.clean(newText)
        let excludedNames = excludedNames + Self.selfIntroducedNames(in: Self.clean(context) + " " + text)
        let mostlyEnglish = Self.englishRatio(text) > 0.5
        guard text.split(whereSeparator: \.isWhitespace).count >= 3 else { return [] }
        var found: [Mention] = []

        // The tell for a quotation is often the sentence BEFORE the line
        // ("Ask not what quote. Kennedy.") and can fall in the previous batch,
        // so the quote tell alone also sees the last words of the lead-in.
        let lead = Self.clean(context).split(separator: " ").suffix(14).joined(separator: " ")
        let withLead = lead.isEmpty ? text : lead + " " + text

        for tell in Self.tells {
            guard let regex = try? NSRegularExpression(pattern: tell.pattern) else { continue }
            let haystack = tell.kind == .quote ? withLead : text
            let range = NSRange(haystack.startIndex..., in: haystack)
            for match in regex.matches(in: haystack, range: range) where match.numberOfRanges > 1 {
                guard let captured = Range(match.range(at: 1), in: haystack) else { continue }
                let raw = String(haystack[captured])
                if tell.kind == .quote {
                    // Only a line that is (at least partly) new text counts.
                    guard haystack.distance(from: haystack.startIndex, to: captured.upperBound) > (withLead.count - text.count) else { continue }
                    guard let query = Self.acceptableQuote(raw) else { continue }
                    found.append(Mention(kind: .quote, query: query, confidence: tell.confidence))
                    continue
                }
                // "fonts such as Tahoma and Verdana" is two topics.
                let pieces = tell.kind == .topic && raw.contains(where: { $0 == "," }) || raw.range(of: " and ", options: .caseInsensitive) != nil && tell.kind == .topic
                    ? raw.components(separatedBy: CharacterSet(charactersIn: ",")).flatMap { $0.components(separatedBy: " and ") }
                    : [raw]
                for piece in pieces {
                    let phrase = Self.trimToTitle(piece)
                    guard let query = Self.acceptable(phrase, kind: tell.kind) else {
                        Self.traceDrop?("patterns: \u{201C}\(piece.trimmingCharacters(in: .whitespaces))\u{201D} (\(tell.kind.rawValue)) is not a name: a pronoun, filler or lesson part")
                        continue
                    }
                    // A named thing said next to "book", "story" or "novel" is a book.
                    // Not when the speaker said what it is: "the brand called
                    // imago" a sentence after "the book, Wonder" is a brand.
                    var kind = tell.kind
                    if kind == .thing, !tell.namesCategory, Self.nearby(text, captured, words: ["book", "novel", "story", "storybook"]) { kind = .book }
                    if kind == .thing, !tell.namesCategory, Self.nearby(text, captured, words: ["movie", "film", "documentary"]) { kind = .video }
                    let finalQuery = Self.extended(query, in: text)
                    // Only the tells that inferred a subject from a question
                    // have to prove the phrase is not ordinary English. See Tell.
                    if tell.guarded, !Self.worthLookingUp(finalQuery, spokenIn: text) {
                        Self.traceDrop?("patterns: \u{201C}\(finalQuery)\u{201D} is an ordinary word, asked about in passing")
                        continue
                    }
                    if tell.nameShaped, !mostlyEnglish || !Self.readsAsAName(finalQuery, in: text) {
                        Self.traceDrop?("patterns: \u{201C}\(finalQuery)\u{201D} after a \u{201C}talk about / heard of\u{201D} does not read as a name\(mostlyEnglish ? "" : " (batch is not mostly English)")")
                        continue
                    }
                    var mention = Mention(kind: kind, query: finalQuery, confidence: tell.confidence)
                    if tell.namesCategory, let start = Range(match.range, in: haystack)?.lowerBound {
                        mention.category = Self.category(before: captured, from: start, in: haystack)
                    }
                    found.append(mention)
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
            // its kind: the tagger is gone, but a tell can still capture a name.
            if mention.kind != .quote, tokens.contains(where: { excludedTokens.contains($0) }) {
                traceDrop?("\u{201C}\(mention.query)\u{201D} shares a name with someone in the meeting")
                continue
            }
            if let existing = byKey[key] {
                // "It's called apprenticeship patterns ... book": the book wins
                // over the generic thing whatever the confidences say.
                if existing.kind != .thing && mention.kind == .thing { continue }
                if existing.kind == .thing && mention.kind != .thing { byKey[key] = mention; continue }
                if existing.confidence >= mention.confidence { continue }
            }
            byKey[key] = mention
        }
        // Two tells can capture the same thing at different lengths. Keep the
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
        // "a museum called the Louvre": the article is not part of what to search.
        if words.count > 1, let first = words.first, ["the", "a", "an"].contains(first.lowercased()) { words.removeFirst() }
        if let cut = words.indices.dropFirst(1).first(where: { hardStops.contains(words[$0].lowercased()) }) {
            words = Array(words[..<cut])
        }
        if let cut = words.indices.dropFirst(2).first(where: { stopWords.contains(words[$0].lowercased()) }) {
            words = Array(words[..<cut])
        }
        while let last = words.last, stopWords.contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Length and shape checks so a tell that swallowed half a sentence does
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
        // "talk about Chapter Four": a part of the lesson, not a subject.
        if kind == .topic || kind == .thing, let first = words.first?.lowercased(), notASubject.contains(first) { return nil }
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
