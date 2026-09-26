//
//  CuesVocabulary.swift
//  Greenroom
//
//  The names this class has already said, so a mishearing of one can be put
//  right before it is searched for.
//
//  A teacher said "Adobe Illustrator" twice and the transcriber got it; the
//  third time it wrote "Adobe O Strader", and the book search for that found
//  nothing, because no book is called that. The speech model has no idea it
//  heard the same name a minute earlier. This does: a phrase that starts
//  with the same word as a name already said, and whose rest SOUNDS like
//  that name's rest, is that name.
//
//  Deliberately narrow. The first word has to match exactly, so this can only
//  ever turn a phrase into a name that was spoken in this class moments
//  before, never invent one. Nothing here leaves the Mac, and nothing is kept
//  after the class ends.
//
import Foundation

struct CuesVocabulary {
    /// Names as they were said, newest last.
    private(set) var terms: [String] = []

    /// Enough for a lesson's worth of named things; the oldest go first.
    static let capacity = 60

    mutating func learn(_ term: String) {
        let words = Mention.normalize(term).split(separator: " ")
        guard words.count >= 2, words.count <= 5 else { return }
        terms.removeAll { Mention.normalize($0) == Mention.normalize(term) }
        terms.append(term)
        if terms.count > Self.capacity { terms.removeFirst(terms.count - Self.capacity) }
    }

    mutating func reset() { terms = [] }

    /// The name `query` is most likely a mishearing of, or nil.
    func repair(_ query: String) -> String? {
        let said = Mention.normalize(query).split(separator: " ").map(String.init)
        guard said.count >= 2, let first = said.first, first.count >= 3 else { return nil }
        let saidRest = Self.skeleton(said.dropFirst().joined())
        guard saidRest.count >= 3 else { return nil }
        for term in terms.reversed() {
            let known = Mention.normalize(term).split(separator: " ").map(String.init)
            guard known.first == first, known != said else { continue }
            let knownRest = Self.skeleton(known.dropFirst().joined())
            guard knownRest.count >= 3 else { continue }
            if knownRest.contains(saidRest) || saidRest.contains(knownRest)
                || TitleMatch.levenshtein(knownRest, saidRest) <= 1 {
                return term
            }
        }
        return nil
    }

    /// How a word sounds, roughly: its consonants, voiced and unvoiced pairs
    /// merged, repeats collapsed. "illustrator" and "o strader" both come to
    /// "…strtr", which is what the ear heard and the transcriber split
    /// differently.
    static func skeleton(_ text: String) -> String {
        let merge: [Character: Character] = ["d": "t", "b": "p", "g": "k", "v": "f", "z": "s",
                                             "c": "k", "q": "k", "x": "k", "j": "k", "w": "v", "y": "i"]
        var out: [Character] = []
        for character in text.lowercased() where character.isLetter {
            guard !"aeiouhy".contains(character) else { continue }
            let sound = merge[character] ?? character
            if out.last != sound { out.append(sound) }
        }
        return String(out)
    }
}
