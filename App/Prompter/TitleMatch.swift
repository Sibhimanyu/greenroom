//
//  TitleMatch.swift
//  Greenroom
//
//  Does this result actually answer what the teacher said?
//
//  Phase 3 of docs/prompter-search-improvement-plan.md asks for one shared
//  scoring rule instead of a different hand-written check per source. This is
//  it, and it replaces a rule that was wrong in both directions.
//
//  The old rule: every non-generic word of the page title must have been said.
//  It correctly rejected "Amazon Kindle" for "kindle paperwhite" - Amazon was
//  never said - and that is the case it was written for. But it says nothing
//  about the other direction, so a title that is a SUBSET of what was said
//  sailed through: "haiku deck" matched the Wikipedia page "Haiku", the
//  Japanese poetic form, because every word of "Haiku" had indeed been said.
//  A confident card about poetry for a teacher talking about slide software.
//
//  The rule that survives both: everything SAID has to be answered. Extra
//  words in a title are fine ("Monospaced font" answers "monospace"); missing
//  ones are not ("Haiku" does not answer "haiku deck").
//
//  Matching a single token is deliberately layered, because the transcript is
//  not clean text. It is what an English speech model made of Indian English
//  with Tamil in it, and brand names come out mangled in a specific way: they
//  sound right and are spelled wrong. "Haiku Deck" was transcribed "Hyco
//  deck", "Comic Sans" as "Comic Sons". Edit distance does not reach hyco ->
//  haiku (four edits on a four-letter word); a phonetic key does, because the
//  error was made by something listening.
//
import Foundation

enum TitleMatch {

    /// Words that carry no identity, so their absence from a title is not a
    /// miss and their presence is not evidence.
    private static let filler: Set<String> = [
        "the", "of", "and", "a", "an", "in", "on", "at", "to", "for", "with", "is"
    ]

    /// How many words a title may add beyond what was said before it stops
    /// being the same subject. "Monospaced font" adds one and is right;
    /// a five-word page for a two-word product is a different subject.
    private static let extraWordsAllowed = 2

    /// True when `title` answers `said`.
    ///
    /// - `said` is the phrase as spoken (the mention's query).
    /// - `title` is what the source returned.
    static func answers(title: String, said: String) -> Bool {
        let saidTokens = tokens(said)
        let titleTokens = tokens(title)
        guard !saidTokens.isEmpty, !titleTokens.isEmpty else { return false }
        guard titleTokens.count <= saidTokens.count + extraWordsAllowed else { return false }

        var remaining = titleTokens
        var phoneticUsed = 0
        var spelledMatches = 0
        for token in saidTokens {
            guard let index = remaining.firstIndex(where: { exactOrNear(token, $0) }) else {
                // Nothing spelled close enough. Allow ONE token of the title to
                // match only by sound - enough to rescue a mangled brand, not
                // enough for a phonetic key to carry a whole wrong title.
                guard phoneticUsed == 0,
                      let sounded = remaining.firstIndex(where: { soundex(token) == soundex($0) })
                else { return false }
                phoneticUsed += 1
                remaining.remove(at: sounded)
                continue
            }
            spelledMatches += 1
            remaining.remove(at: index)
        }
        // Sound corroborates spelling; it never makes the case alone.
        //
        // "One phonetic token per title" reads like a bound and is none when
        // the phrase IS one token. A real class proved it within a minute:
        // Tamil speech gave the model "Orukuntu", which keys to O625, and so
        // does "Orkun" - so a Turkish footballer was offered to a reading
        // class. "Hyco deck" still reaches "Haiku Deck" because "deck" is
        // spelled right and carries the match; "orukuntu" has nothing behind it.
        return phoneticUsed == 0 || spelledMatches > 0
    }

    /// Normalised, filler removed.
    static func tokens(_ text: String) -> [String] {
        Mention.normalize(text)
            .split(separator: " ")
            .map(String.init)
            .filter { !filler.contains($0) }
    }

    /// Same word, or close enough to be the same word typed badly. One edit is
    /// allowed only from five letters up, where it cannot turn one short word
    /// into a different one ("sans" -> "sons" is a real distinction at four).
    private static func exactOrNear(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 5, abs(a.count - b.count) <= 1 else { return false }
        return levenshtein(a, b) <= 1
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Soundex. Old, crude, and exactly right for this job: the errors it
    /// forgives are the errors a listener makes, which is what produced them.
    static func soundex(_ word: String) -> String {
        let letters = word.lowercased().filter { $0.isLetter }
        guard let first = letters.first else { return "" }

        func code(_ character: Character) -> Character? {
            switch character {
            case "b", "f", "p", "v": return "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
            case "d", "t": return "3"
            case "l": return "4"
            case "m", "n": return "5"
            case "r": return "6"
            default: return nil                 // vowels, h, w, y
            }
        }

        var result = String(first).uppercased()
        var lastCode = code(first)
        for character in letters.dropFirst() {
            let current = code(character)
            if let current, current != lastCode {
                result.append(current)
                if result.count == 4 { break }
            }
            // h and w are transparent: they do not break a repeat. Vowels do.
            if character != "h" && character != "w" {
                lastCode = current
            }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}
