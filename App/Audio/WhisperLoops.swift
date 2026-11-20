//
//  WhisperLoops.swift
//  Greenroom
//
//  Pure. On quiet or unclear audio whisper gets stuck and says the same
//  sentence over and over ("I don't know how much this is" ten times in 26
//  seconds). The report then scored that as the speaker's real words.
//
//  This collapses a run of the same phrase to its first occurrence. Matching
//  ignores case and punctuation. A repeat is only a loop when it is long or
//  frequent enough that a person would not say it on purpose:
//    - a unit of 4+ words said twice or more, or
//    - a unit of 2-3 words said 3+ times, or
//    - a single word said 6+ times.
//  So "yes yes" and "no, no, no" survive. Repeats across segment boundaries
//  count, and a segment left with nothing (it was only a repeat of the one
//  before) comes back empty so the caller can drop it.
//
import Foundation

enum WhisperLoops {

    private static let maxUnit = 40

    /// Lowercased letters and digits only; nil for a token with none.
    static func normalised(_ token: String) -> String? {
        let kept = token.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "\u{2019}"
        }
        let s = String(String.UnicodeScalarView(kept)).replacingOccurrences(of: "\u{2019}", with: "'")
        return s.isEmpty ? nil : s
    }

    private static func minimumRepeats(unit: Int) -> Int {
        unit >= 4 ? 2 : unit >= 2 ? 3 : 6
    }

    /// Which tokens stay. `tokens` are raw words as spoken (punctuation and
    /// case allowed). The first occurrence of a loop stays; its repeats go.
    static func keepMask(_ tokens: [String]) -> [Bool] {
        let norm = tokens.map(normalised)
        var keep = [Bool](repeating: true, count: tokens.count)
        var i = 0
        while i < tokens.count {
            guard norm[i] != nil else { i += 1; continue }
            var advanced = false
            for unit in 1...maxUnit where i + unit * 2 <= tokens.count {
                let base = Array(norm[i..<(i + unit)])
                guard !base.contains(where: { $0 == nil }) else { continue }
                var repeats = 1
                while i + (repeats + 1) * unit <= tokens.count,
                      Array(norm[(i + repeats * unit)..<(i + (repeats + 1) * unit)]) == base {
                    repeats += 1
                }
                guard repeats >= minimumRepeats(unit: unit) else { continue }
                var end = i + repeats * unit
                // A loop usually stops mid-sentence: drop the partial tail too.
                var tail = 0
                while tail < unit - 1, end + tail < tokens.count, norm[end + tail] == base[tail] { tail += 1 }
                if tail >= 2 { end += tail }
                for j in (i + unit)..<end { keep[j] = false }
                i = end
                advanced = true
                break
            }
            if !advanced { i += 1 }
        }
        return keep
    }

    /// Text of a segment or line with loops collapsed; consecutive segments
    /// are treated as one stream. A segment that was only a repeat becomes "".
    static func collapse(segments: [String]) -> [String] {
        var tokens: [String] = []
        var owner: [Int] = []
        for (index, segment) in segments.enumerated() {
            for token in segment.split(whereSeparator: { $0.isWhitespace }) {
                tokens.append(String(token))
                owner.append(index)
            }
        }
        let keep = keepMask(tokens)
        var out = [[String]](repeating: [], count: segments.count)
        for (k, token) in tokens.enumerated() where keep[k] { out[owner[k]].append(token) }
        return out.map { $0.joined(separator: " ") }
    }

    /// One line, loops collapsed.
    static func collapse(_ text: String) -> String {
        collapse(segments: [text]).first ?? ""
    }
}
