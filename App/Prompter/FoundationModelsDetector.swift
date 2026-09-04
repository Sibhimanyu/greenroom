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
//  A fresh session per pass. Prompter's passes are independent - the context
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

    /// What this class is about ("design and typography"), from the class
    /// name the teacher set. One line of subject matter is what separates a
    /// font called Tahoma from a place called Tahoma.
    private let subject: String

    init(subject: String = "") {
        self.subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
    private var instructions: String { Self.baseInstructions + subjectRule }

    /// The subject belongs in the standing rules, never in the turn.
    ///
    /// Passed alongside the new words it was read as content: with "design,
    /// typography and reading" as the subject the model returned "design",
    /// "typography" and "reading" as things to look up. Stated as a rule, with
    /// an explicit prohibition, it informs the queries instead of seeding them.
    private var subjectRule: String {
        subject.isEmpty ? "" : " This class is about \(subject). Use that only to judge what a name means and to write better search queries - never return the subject words themselves as an item."
    }

    private static let baseInstructions = """
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
    finds the right page - so the query should carry a word or two about what kind of thing it is, taken \
    from what the teacher was saying. A quote is the exception: both are the quoted line. \
    The context words are for understanding only - do not list things from them again.
    """

    func prewarm() {
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
    }

    func detect(newText: String, context: String, excludedNames: [String]) async throws -> [Mention] {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(whereSeparator: \.isWhitespace).count >= 3 else { return [] }

        let roster = excludedNames.isEmpty ? "" : "\nPeople in the call (never list these): \(excludedNames.joined(separator: ", "))."
        var prompt = "Context (already handled): \(context.isEmpty ? "none" : context)\nNew words: \(trimmed)\(roster)"

        for attempt in 0..<2 {
            let session = LanguageModelSession(instructions: instructions)
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
                    guard generated.confidence >= 0.45 else { return nil }
                    return Mention(kind: kind, query: query,
                                   searchQuery: generated.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                                   confidence: min(1, max(0, generated.confidence)))
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
