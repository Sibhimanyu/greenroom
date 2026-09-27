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
    var forceAfterMs: Int = 4_000

    /// Words settled so far, oldest first.
    private(set) var committed: [CuesHypothesisWord] = []
    /// The still-changing tail of the last pass.
    private(set) var volatileWords: [CuesHypothesisWord] = []

    private var previous: [CuesHypothesisWord] = []
    /// Just past the START of the last settled word. Not its end: whisper
    /// often stretches the last word of a window to the window's edge, and
    /// using that end skipped the next words ("everyone", a whole closing
    /// sentence) as if already settled.
    private var committedUntilMs = 0

    /// How close to the window's leading edge a word counts as cut off.
    ///
    /// The first word of a window is often only half in it, and whisper
    /// guesses it from half a syllable. A word that starts this close to the
    /// edge is taken from the PREVIOUS pass, which heard it whole.
    var edgeMs: Int = 500

    /// Where settling a word moves the mark to: a short word past its start,
    /// or its end if that comes sooner. See `committedUntilMs`.
    private func settledMark(_ word: CuesHypothesisWord) -> Int {
        min(max(word.endMs, word.atMs + 1), word.atMs + 400)
    }

    /// Feeds one pass and returns the words that just became settled.
    ///
    /// `now` is how far into the session the audio behind this pass reaches;
    /// `windowStartMs` is where this pass's audio begins.
    ///
    /// The first version compared the two passes word by word from their
    /// fronts. That holds while the window is still filling, and breaks for
    /// good the moment it slides: the previous pass still starts with words
    /// the new window no longer contains, so its first word is set against a
    /// different word, the two never agree again, and nothing is committed
    /// after the first six seconds. Its safety net committed a word after
    /// eight seconds - but a word only stays in a six-second window for six,
    /// so the net fired on words that were already gone. Replayed through
    /// real whisper passes, a fifteen-second passage settled "So for me,
    /// learned computer science practically" and lost everything after it:
    /// "TI 83", "agentic coding", all of it.
    ///
    /// Now: whatever the previous pass heard that is leaving the window is
    /// committed on its reading, because nothing will look at it again; and
    /// agreement is only asked of words both passes can still see.
    mutating func accept(_ hypothesis: [CuesHypothesisWord], now: Int,
                         windowStartMs: Int = 0) -> [CuesHypothesisWord] {
        let edge = windowStartMs + edgeMs
        var settled: [CuesHypothesisWord] = []

        // Leaving: heard by the last pass, not (whole) in this one.
        if windowStartMs > 0 {
            let leaving = previous.filter { $0.atMs >= committedUntilMs && $0.atMs < edge && !repeatsLast($0, committed.last) }
            if let last = leaving.last {
                settled.append(contentsOf: leaving)
                committedUntilMs = max(committedUntilMs, settledMark(last))
            }
        }

        // LocalAgreement-2 over what both passes still see, from the same
        // point in time.
        let floor = max(committedUntilMs, windowStartMs > 0 ? edge : 0)
        let lastSettled = settled.last ?? committed.last
        let fresh = hypothesis.filter { $0.atMs >= floor && !repeatsLast($0, lastSettled) }
        let priorFresh = previous.filter { $0.atMs >= floor && !repeatsLast($0, lastSettled) }
        var agreed: [CuesHypothesisWord] = []
        for (a, b) in zip(priorFresh, fresh) {
            guard a.key == b.key, !a.key.isEmpty else { break }
            // The newer pass's spelling wins: it heard more of the sentence.
            agreed.append(b)
        }

        // The word nobody will ever agree on, while the window is still
        // filling and nothing is leaving yet.
        if agreed.isEmpty, settled.isEmpty, let oldest = fresh.first, now - oldest.atMs >= forceAfterMs {
            agreed = [oldest]
        }

        if let last = agreed.last {
            settled.append(contentsOf: agreed)
            committedUntilMs = max(committedUntilMs, settledMark(last))
        }
        committed.append(contentsOf: settled)
        previous = hypothesis
        volatileWords = hypothesis.filter { $0.atMs >= committedUntilMs }
        return settled
    }

    /// The same word heard again by a later pass, a little earlier or later
    /// than the copy just settled. Passes shift timings by a few hundred
    /// milliseconds, so without this "learned" and "to" were settled twice.
    private func repeatsLast(_ word: CuesHypothesisWord, _ last: CuesHypothesisWord?) -> Bool {
        guard let last else { return false }
        return word.key == last.key && abs(word.atMs - last.atMs) < 1_200
    }

    /// Everything still unsettled, committed because listening stopped.
    mutating func flush() -> [CuesHypothesisWord] {
        let rest = volatileWords
        committed.append(contentsOf: rest)
        if let last = rest.last { committedUntilMs = max(committedUntilMs, settledMark(last)) }
        previous = []
        volatileWords = []
        return rest
    }

    /// Settled words joined into sentences, which is what the mention
    /// detector wants: it works on a finished thought, not on a word.
    ///
    /// Split on terminal punctuation, and on a silence long enough to be a
    /// full stop the speaker made but the model did not write down.
    /// Whole sentences only, and the unfinished words that follow them.
    ///
    /// `sentences(from:)` ends its last sentence wherever the batch ends, and
    /// a batch of settled words ends wherever two passes stopped agreeing -
    /// often mid-sentence. "I watched a video" and "about volcanoes." then
    /// reached the detector as two sentences, neither of which is a mention,
    /// and the card was never made. The tail is held here until its sentence
    /// ends, the speaker pauses, or it has waited `holdMs`.
    static func completeSentences(from words: [CuesHypothesisWord], now: Int,
                                  gapMs: Int = 700, holdMs: Int = 2_500) -> (sentences: [String], rest: [CuesHypothesisWord]) {
        var cut = 0
        for (index, word) in words.enumerated() {
            let endsSentence = word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!")
            let longGap = index + 1 < words.count && words[index + 1].atMs - word.endMs >= gapMs
            if endsSentence || longGap { cut = index + 1 }
        }
        var rest = Array(words[cut...])
        var done = Array(words[..<cut])
        if let last = rest.last, now - last.endMs >= holdMs {
            done += rest
            rest = []
        }
        return (sentences(from: done, gapMs: gapMs), rest)
    }

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
