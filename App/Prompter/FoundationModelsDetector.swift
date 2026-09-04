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
    @Guide(description: "One of: book, video, topic, person, place", .anyOf(["book", "video", "topic", "person", "place"]))
    var kind: String
    @Guide(description: "A short search phrase, 1 to 6 words, the title or name as said. No sentences.")
    var query: String
    @Guide(description: "How sure you are the speaker named a real, findable thing, 0.0 to 1.0", .range(0.0...1.0))
    var confidence: Double
}

@available(macOS 26.0, *)
final class FoundationModelsDetector: MentionDetector {
    let name = "Apple Intelligence (on-device)"
    let analyticsCode = "ai"

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

    private static let instructions = """
    You listen to a teacher speaking to a class of children over a video call. From the new words, list only \
    things that could be looked up on the web: the title of a book or story, a video or film, a topic being \
    explained, a well-known person (an author, a historical figure), or a place. \
    Rules: never list the names of the people in the call - students or the teacher - and never list \
    anything said TO someone; skip greetings, instructions and classroom management; return a short \
    search phrase for each item, the title or name as said, not a sentence; return nothing when nothing \
    was named. The context words are for understanding only - do not list things from them again.
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
                    guard !words.isEmpty, words.count <= 7, query.count >= 3, query.count <= 60 else { return nil }
                    guard generated.confidence >= 0.45 else { return nil }
                    return Mention(kind: kind, query: query, confidence: min(1, max(0, generated.confidence)))
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
