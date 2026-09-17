//
//  FoundationModelsDetector.swift
//  Greenroom
//
//  The mention detector backed by Apple's on-device language model.
//
//  Same contract as the heuristic: new text, a little context, the names in
//  the room; back come up to five short queries with a kind and a confidence.
//  The model runs on this Mac (FoundationModels, macOS 26, Apple Intelligence
//  on). Nothing it reads or writes leaves the process; the queries it returns
//  go through the same roster filter as the heuristic's before any of them can
//  become a request.
//
//  A fresh session per pass. Cues's passes are independent - the context
//  words carry what matters - and a long-lived session accumulates a
//  transcript in the model's window until it overflows mid-class.
//
import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct GeneratedMentions {
    @Guide(description: "Things the speaker referred to that could be looked up: books, videos, topics, people, places. Leave empty when nothing was named.", .maximumCount(5))
    var mentions: [GeneratedMention]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedMention {
    @Guide(description: "One of: thing (a tool, app, product, company or other named thing), word (a word whose meaning is asked or explained), quote (a quotation), book, video, topic, person, place",
           .anyOf(["thing", "word", "quote", "book", "video", "topic", "person", "place"]))
    var kind: String
    @Guide(description: "For a quote: the quoted line itself, as said. Otherwise the name of the thing as the teacher said it, 1 to 6 words.")
    var query: String
    @Guide(description: "What you would type into a search box to find this exact thing. Include the name plus a word or two saying what kind of thing it is, taken from what the teacher was talking about - for example a font name plus the word font, or a product name plus what it does. For a quote, repeat the quoted line. 2 to 10 words.")
    var searchQuery: String
    @Guide(description: "How sure you are the speaker named a real, findable thing, 0.0 to 1.0", .range(0.0...1.0))
    var confidence: Double
}

@available(macOS 26.0, *)
final class FoundationModelsDetector: MentionDetector {
    let name = "Apple Intelligence (on-device)"
    let analyticsCode = "ai"
    let isCheap = false

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why it is not available, in the model's own words, for Settings.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is off in System Settings"
            case .deviceNotEligible: return "this Mac cannot run Apple Intelligence"
            case .modelNotReady: return "the model is still downloading or preparing"
            @unknown default: return "not available"
            }
        }
    }

    /// Errors in a row that were not the model's judgement. Three swaps the
    /// session to the heuristic; a single guardrail refusal is not counted.
    private(set) var consecutiveErrors = 0

    /// No concrete examples, on purpose.
    ///
    /// The first version of these instructions illustrated the "thing" kind with
    /// two real product names. Scored against a 45-minute class the model then
    /// emitted those two names 26 times between them, mostly in stretches where
    /// neither was mentioned - it was echoing the prompt whenever a batch held
    /// nothing real. Precision was 2%. A small model treats a concrete example
    /// as a candidate answer, so the kinds are described by shape only, and the
    /// rule for an empty batch is stated explicitly instead.
    private static let instructions = """
    You listen to a teacher speaking to a class over a video call, in Indian English with some Tamil mixed in. \
    From the new words, list only things the teacher would open a browser tab for: a named tool, app, \
    product or company; a word whose meaning he asks or explains; a quotation he recites (return the quoted \
    line itself); a book, a video or film, a topic he sets out to explain, a well-known person, or a place. \
    Every item you return must appear in the new words themselves. Never invent an item, never repeat an \
    item from the context, and never return an example from these instructions. \
    Most batches contain nothing worth looking up - returning an empty list is the normal, correct answer. \
    Rules: never list the names of the people in the call - students or the teacher - and never list \
    anything said TO someone; skip greetings, instructions and classroom management; ignore words that \
    are not English unless they are clearly a name. \
    For each item give TWO things: the name as the teacher said it, and a search query that would actually \
    find it. A bare name is often too thin to search - "monospace" finds nothing useful, "monospace font" \
    finds the right page - so read the words immediately around the name, and the context words before \
    them, to work out what kind of thing it is, then put that into the query. If the surrounding talk is \
    about fonts, a name is probably a typeface; if it is about e-readers, a name is probably a device. \
    A quote is the exception: both are the quoted line. \
    The context is there to tell you what the names MEAN - use it for the queries, but never return an \
    item that appears only in the context and not in the new words.
    """

    func prewarm() {
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
    }

    func detect(newText: String, context: String, excludedNames: [String]) async throws -> [Mention] {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(whereSeparator: \.isWhitespace).count >= 3 else { return [] }

        let roster = excludedNames.isEmpty ? "" : "\nPeople in the call (never list these): \(excludedNames.joined(separator: ", "))."
        var prompt = "Context (already handled): \(context.isEmpty ? "none" : context)\nNew words: \(trimmed)\(roster)"

        for attempt in 0..<2 {
            let session = LanguageModelSession(instructions: Self.instructions)
            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: GeneratedMentions.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 256))
                consecutiveErrors = 0
                let mentions = response.content.mentions.compactMap { generated -> Mention? in
                    guard let kind = Mention.Kind(rawValue: generated.kind.lowercased()) else { return nil }
                    let query = generated.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'."))
                    let words = query.split(separator: " ")
                    let maxWords = kind == .quote ? 30 : 7
                    let maxLength = kind == .quote ? 200 : 60
                    guard !words.isEmpty, words.count <= maxWords, query.count >= 3, query.count <= maxLength else { return nil }
                    // A quotation needs somebody to have said one was coming.
                    //
                    // This was a word-count floor, which does not work: the
                    // greeting that reached Wikiquote in a live class ("how is
                    // everyone today?") is five words, and "As a woman like
                    // that was really into me" is nine. Length is not the
                    // difference between talking and quoting. The word-pattern
                    // detector has always required a recitation cue; the model
                    // now answers to the same rule, reading the lead-in too
                    // because the tell usually lands in the sentence before.
                    if kind == .quote,
                       !HeuristicDetector.hasRecitationCue(context + " " + trimmed) { return nil }
                    guard generated.confidence >= 0.45 else { return nil }
                    // The model invents items despite being told not to, and
                    // offers everyday nouns as things to look up. Both are
                    // cheap to reject here, before anything is sent.
                    // Each kind answers to the gate that is actually about it.
                    switch kind {
                    case .quote:
                        // The quoted line itself; the word floor above is its rule.
                        break
                    case .word:
                        // A definition is right exactly when someone asked what
                        // the word means - ordinary word or not. Running these
                        // through worthLookingUp instead was wrong both ways:
                        // it passed "happening" because the model called it a
                        // word, and it would have dropped a real "what does
                        // pabulum mean?" for being in the dictionary, which is
                        // the one place being in the dictionary is the point.
                        guard Mention.normalize(trimmed).contains(Mention.normalize(query)),
                              HeuristicDetector.asksAboutTheWord(query, in: trimmed) else { return nil }
                    case .thing, .topic:
                        // The two kinds the model invents. A book, a video, a
                        // person or a place is a category the talk names out
                        // loud; "thing" and "topic" are where a sliced-up
                        // sentence lands, so they answer to namesAThing too.
                        guard HeuristicDetector.worthLookingUp(query, spokenIn: trimmed),
                              HeuristicDetector.namesAThing(query) else { return nil }
                    default:
                        guard HeuristicDetector.worthLookingUp(query, spokenIn: trimmed) else { return nil }
                    }
                    let mention = Mention(kind: kind, query: query,
                                          searchQuery: generated.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                                          confidence: min(1, max(0, generated.confidence)))
                    // The one-word search is the one that finds nothing. The
                    // model is asked to carry a word or two of what kind of
                    // thing this is, drawn from the surrounding talk; when it
                    // hands back the bare name anyway, the talk did not say
                    // what the thing was, and there is nothing to search for.
                    // Quotes are the line itself, and a definition never
                    // leaves the Mac, so neither needs the context.
                    let enriched = mention.searchQuery.split(whereSeparator: \.isWhitespace).count >= 2
                    guard kind == .quote || kind == .word || enriched else { return nil }
                    return mention
                }
                return HeuristicDetector.filter(mentions, excludedNames: excludedNames)
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .guardrailViolation, .refusal:
                    // The model declined this pass. Not an error of ours; drop it.
                    return []
                case .exceededContextWindowSize where attempt == 0:
                    // Shrink and try once more without the context.
                    prompt = "New words: \(String(trimmed.suffix(600)))\(roster)"
                    continue
                default:
                    consecutiveErrors += 1
                    throw error
                }
            } catch {
                consecutiveErrors += 1
                throw error
            }
        }
        return []
    }
}
