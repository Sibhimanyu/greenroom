//
//  CuesStabiliser.swift
//  Greenroom
//
//  Turning a sliding window of guesses into text that will not change.
//
//  Apple's SpeechAnalyzer hands Cues finalised sentences: once you have them,
//  they are settled. whisper does not work that way. Run over a live
//  microphone it re-transcribes an overlapping window every step, so the same
//  words arrive several times and get REVISED on the way - "tacoma" becomes
//  "Tahoma" once the next two syllables are in the window. Feeding that
//  straight to the mention detector would fire three or four times on one
//  phrase and look up the wrong spelling twice.
//
//  The policy is LocalAgreement-2, which is the standard answer and is
//  simpler than it sounds: a word is settled when TWO CONSECUTIVE windows
//  agree on it. One window is a guess; two windows that say the same thing
//  with different surrounding audio is a fact. Anything after the agreed
//  prefix is still in play and goes out as volatile.
//
//  The part that is easy to get wrong is the word nobody ever agrees on.
//  A name the model hears differently every single pass would sit at the head
//  of the queue forever and stop the whole stream behind it. So a word that
//  has aged out of the window is committed anyway, on the current guess:
//  there will never be another opinion on it, and a slightly wrong word is
//  worth more than a transcript that stopped.
//
import Foundation

/// One word from one pass, with the absolute time it was spoken.
struct CuesHypothesisWord: Hashable {
    var text: String
    /// Milliseconds from the start of listening, NOT from the start of the
    /// window - windows slide, so a window-relative offset means nothing once
    /// two passes are compared.
    var atMs: Int
    var endMs: Int

    /// What two passes are compared on. Case and trailing punctuation change
    /// between passes on the same audio and are not disagreements.
    var key: String {
        text.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
}

struct CuesStabiliser {

    /// How long a word may stay disputed before it is committed anyway.
    ///
    /// Measured from when it was spoken. Once a word has left the window it
    /// cannot be re-examined, so holding it back only loses it.
    var forceAfterMs: Int = 8_000

    /// Words settled so far, oldest first.
    private(set) var committed: [CuesHypothesisWord] = []
    /// The still-changing tail of the last pass.
    private(set) var volatileWords: [CuesHypothesisWord] = []

    private var previous: [CuesHypothesisWord] = []
    private var committedUntilMs = 0

    /// Feeds one pass and returns the words that just became settled.
    ///
    /// `now` is how far into the session the audio behind this pass reaches,
    /// so the ageing rule has something to measure against.
    mutating func accept(_ hypothesis: [CuesHypothesisWord], now: Int) -> [CuesHypothesisWord] {
        // Anything already settled is not up for discussion.
        let fresh = hypothesis.filter { $0.atMs >= committedUntilMs }
        let priorFresh = previous.filter { $0.atMs >= committedUntilMs }

        // LocalAgreement-2: the prefix both passes say.
        var agreed: [CuesHypothesisWord] = []
        for (a, b) in zip(priorFresh, fresh) {
            guard a.key == b.key, !a.key.isEmpty else { break }
            // The newer pass's spelling wins: it heard more of the sentence.
            agreed.append(b)
        }

        // The word nobody will ever agree on. Committed on the current guess
        // rather than left to block everything behind it.
        if agreed.isEmpty, let oldest = fresh.first, now - oldest.atMs >= forceAfterMs {
            agreed = [oldest]
        }

        if let last = agreed.last {
            committed.append(contentsOf: agreed)
            committedUntilMs = max(committedUntilMs, last.endMs)
        }
        previous = hypothesis
        volatileWords = fresh.filter { $0.atMs >= committedUntilMs }
        return agreed
    }

    /// Everything still unsettled, committed because listening stopped.
    mutating func flush() -> [CuesHypothesisWord] {
        let rest = volatileWords
        committed.append(contentsOf: rest)
        if let last = rest.last { committedUntilMs = max(committedUntilMs, last.endMs) }
        previous = []
        volatileWords = []
        return rest
    }

    /// Settled words joined into sentences, which is what the mention
    /// detector wants: it works on a finished thought, not on a word.
    ///
    /// Split on terminal punctuation, and on a silence long enough to be a
    /// full stop the speaker made but the model did not write down.
    static func sentences(from words: [CuesHypothesisWord], gapMs: Int = 700) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for (index, word) in words.enumerated() {
            current.append(word.text)
            let endsSentence = word.text.hasSuffix(".") || word.text.hasSuffix("?")
                || word.text.hasSuffix("!")
            let longGap = index + 1 < words.count && words[index + 1].atMs - word.endMs >= gapMs
            if endsSentence || longGap {
                out.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
