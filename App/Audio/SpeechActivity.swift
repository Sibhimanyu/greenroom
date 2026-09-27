//
//  SpeechActivity.swift
//  Greenroom
//
//  Where in a stretch of audio someone is actually talking, measured from the
//  audio rather than from what a recogniser says it heard.
//
//  Built because whisper is not a reliable witness about silence. Given a
//  quiet room it writes "[BLANK_AUDIO]", "(birds chirping)" and, worse, whole
//  sentences nobody said ("Thank you.", "I'll teach you."), and its word
//  timings stretch across a pause instead of stopping at it: in a Screenroom
//  test the first word of a talk was stamped 1.3 s to 13.6 s when the talk
//  began at 15 s, which erased both real three-second pauses from the report
//  and sent its Play buttons into silence. Energy is a blunt measure, but it
//  cannot hallucinate.
//
//  The threshold is relative to the room. A frame counts as voiced when it is
//  15 dB above the quietest tenth of the audio, and never below -50 dBFS. In
//  the rooms measured, a silent class with birds outside sat at -52 to -38
//  dBFS and speech into the laptop mic at -25 to -18, so the gap is wide.
//

import Foundation

enum SpeechActivity {

    /// Analysis frame. Twenty milliseconds is a syllable's worth.
    static let frameMs = 20
    /// Above the room's floor by this much, a frame is someone talking.
    static let marginDB: Float = 15
    /// And never quieter than this, however silent the room.
    static let minimumDB: Float = -50
    /// Voiced stretches closer than this are one stretch: the gaps inside a
    /// word and between words said together.
    static let joinMs = 250
    /// A voiced stretch shorter than this is a click, a cough, a chair.
    static let minimumVoicedMs = 80

    /// One level per frame, in dBFS.
    static func levels(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> [Float] {
        let step = max(1, Int(sampleRate * Double(frameMs) / 1000))
        var out: [Float] = []
        out.reserveCapacity(samples.count / step + 1)
        var index = 0
        while index + step <= samples.count {
            var sum: Float = 0
            for sample in samples[index..<(index + step)] { sum += sample * sample }
            let rms = (sum / Float(step)).squareRoot()
            out.append(20 * log10(max(rms, 1e-9)))
            index += step
        }
        return out
    }

    static func levels(_ samples: [Float], sampleRate: Double) -> [Float] {
        samples.withUnsafeBufferPointer { levels($0, sampleRate: sampleRate) }
    }

    /// The level a frame must beat, given the room's levels.
    static func threshold(floorFrom levels: [Float]) -> Float {
        guard !levels.isEmpty else { return minimumDB }
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        return max(floor + marginDB, minimumDB)
    }

    /// Voiced stretches in milliseconds from the start of `levels`.
    static func voiced(_ levels: [Float], threshold: Float) -> [ClosedRange<Int>] {
        var raw: [ClosedRange<Int>] = []
        var start: Int?
        for (index, level) in levels.enumerated() {
            let t = index * frameMs
            if level > threshold {
                if start == nil { start = t }
            } else if let s = start {
                raw.append(s...t)
                start = nil
            }
        }
        if let s = start { raw.append(s...(levels.count * frameMs)) }

        var joined: [ClosedRange<Int>] = []
        for range in raw {
            if let last = joined.last, range.lowerBound - last.upperBound < joinMs {
                joined[joined.count - 1] = last.lowerBound...range.upperBound
            } else {
                joined.append(range)
            }
        }
        return joined.filter { $0.upperBound - $0.lowerBound >= minimumVoicedMs }
    }

    /// True when any voiced stretch comes within `slackMs` of the span.
    static func overlaps(_ span: ClosedRange<Int>, _ voiced: [ClosedRange<Int>], slackMs: Int) -> Bool {
        let widened = (span.lowerBound - slackMs)...(span.upperBound + slackMs)
        return voiced.contains { $0.overlaps(widened) }
    }

    /// Moves each word onto the audio it was said in, and drops the words
    /// said in silence.
    ///
    /// A word that starts in silence moves forward to the next voiced moment,
    /// if there is one within two seconds of where whisper ended it; one that
    /// ends in silence is pulled back to the end of its voiced stretch. A word
    /// with no voiced audio anywhere near it was not said.
    ///
    /// If that would drop more than a third of the words, the audio is not
    /// the kind this measures (a very quiet speaker, a mic far away) and the
    /// words come back untouched: a report with whisper's timings is better
    /// than one with a third of the talk missing.
    static func align(_ words: [ScreenroomSpokenWord], to voiced: [ClosedRange<Int>]) -> [ScreenroomSpokenWord] {
        guard !words.isEmpty, !voiced.isEmpty else { return words }
        let ordered = words.sorted { $0.atMs < $1.atMs }
        var out: [ScreenroomSpokenWord] = []
        var previousEnd = 0
        // Where whisper ended the last word that was tucked in after the
        // speech, so the rest of the same phrase can follow it.
        var tuckedWhisperEnd: Int?

        for word in ordered {
            var start = max(word.atMs, previousEnd)
            let whisperEnd = max(word.endMs, word.atMs)

            // Into speech, if it starts in silence.
            var region = voiced.first { $0.contains(start) }
            if region == nil {
                if let next = voiced.first(where: { $0.lowerBound >= start }),
                   next.lowerBound <= whisperEnd + 2_000 {
                    start = next.lowerBound
                    region = next
                } else if let before = voiced.last(where: { $0.upperBound <= start }),
                          word.atMs - before.upperBound <= 2_500
                            || tuckedWhisperEnd.map({ word.atMs - $0 <= 600 }) == true {
                    // Stamped just after the speech it belongs to ended - the
                    // end of "thank you for listening" landed past the talk.
                    // Tucked onto the end of that stretch rather than lost.
                    let end = max(previousEnd, before.upperBound)
                    out.append(ScreenroomSpokenWord(text: word.text, atMs: end, durationMs: 40))
                    previousEnd = end + 40
                    tuckedWhisperEnd = whisperEnd
                    continue
                } else {
                    continue
                }
            }
            guard let stretch = region else { continue }
            tuckedWhisperEnd = nil

            // Out of silence, if it ends in it.
            let spoken = min(max(80, whisperEnd - word.atMs), 1_500)
            var end = max(whisperEnd, start + 80)
            if !voiced.contains(where: { $0.contains(end) }) {
                end = min(stretch.upperBound, start + spoken)
            }
            end = max(end, start + 40)

            out.append(ScreenroomSpokenWord(text: word.text, atMs: start, durationMs: end - start))
            previousEnd = end
        }

        return out.count * 3 >= ordered.count * 2 ? out : words
    }
}

/// What whisper writes that nobody said.
///
/// Sound labels come in brackets or parentheses - "[BLANK_AUDIO]", "(birds
/// chirping)", "[MUSIC PLAYING]", "[end]" - and with one word per segment
/// (`-ml 1 -sow`) a two-word label arrives as two words, "[no" and "audio]".
/// Anything from an opening bracket to its closing one goes, and so does a
/// stray half whose other half was in the previous window. Real speech never
/// arrives in brackets from whisper, so nothing said is lost.
enum WhisperNoise {

    static func isMusic(_ text: String) -> Bool {
        text.unicodeScalars.contains { "♪♫♬".unicodeScalars.contains($0) }
    }

    static func drop(_ words: [ScreenroomSpokenWord]) -> [ScreenroomSpokenWord] {
        var out: [ScreenroomSpokenWord] = []
        var closer: Character?
        for word in words {
            let text = word.text
            if let open = closer {
                if text.contains(open) { closer = nil }
                continue
            }
            if let first = text.first, first == "[" || first == "(" || first == "*" {
                let close: Character = first == "[" ? "]" : first == "(" ? ")" : "*"
                if !text.dropFirst().contains(close) { closer = close }
                continue
            }
            // The back half of a label split across two windows.
            if text.contains("]") || text.contains(")") { continue }
            if isMusic(text) { continue }
            // Punctuation on its own ("-", "...") is not a word.
            if text.unicodeScalars.allSatisfy({ !CharacterSet.alphanumerics.contains($0) }) { continue }
            out.append(word)
        }
        return out
    }

    /// For text that is already a line: the same labels, removed in place.
    /// Returns nil when nothing said is left.
    static func clean(_ line: String) -> String? {
        let pattern = #"\[[^\]]*\]?|\([^)]*\)?|\*[^*]*\*|[♪♫♬]"#
        let stripped = line.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
            // The back half of a label whose front half was on the line before.
            .replacingOccurrences(of: #"\S*[\])]\S*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard stripped.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        return stripped
    }
}
