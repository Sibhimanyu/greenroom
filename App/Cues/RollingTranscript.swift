//
//  RollingTranscript.swift
//  Greenroom
//
//  The last minute and a half of what the teacher said, in memory, and
//  nowhere else.
//
//  There is no file, no UserDefaults key, no log line carrying this text. The
//  transcriber's finalised sentences arrive here, the detector reads the ones
//  it has not seen plus a little lead-in for context, and anything older than
//  the window is dropped. `reset()` at session end releases the lot, and the
//  closing status line reports how many sentences were discarded so the
//  teacher can see that they were.
//
import Foundation

struct RollingTranscript {
    struct Sentence {
        var text: String
        var at: Date
        var processed: Bool
    }

    /// How far back the context can reach. Ninety seconds covers a teacher
    /// finishing a thought about a book they named at the start of it.
    var window: TimeInterval = 90

    private(set) var sentences: [Sentence] = []
    /// The transcriber's in-progress guess at the current sentence. Shown in
    /// the Settings test only; never detected on, never counted.
    private(set) var volatileTail = ""
    /// How many finalised sentences ever arrived, for the closing log line.
    private(set) var totalFinalized = 0

    mutating func appendFinal(_ text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sentences.append(Sentence(text: trimmed, at: date, processed: false))
        totalFinalized += 1
        volatileTail = ""
        trim(now: date)
    }

    mutating func setVolatile(_ text: String) {
        volatileTail = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything the detector has not yet seen, with up to `leadInWords`
    /// words of already-processed text in front for context. Marks the new
    /// sentences processed.
    mutating func unprocessedText(leadInWords: Int = 20) -> (new: String, context: String) {
        trim(now: Date())
        let fresh = sentences.filter { !$0.processed }
        guard !fresh.isEmpty else { return ("", "") }
        let seen = sentences.filter { $0.processed }.map(\.text).joined(separator: " ")
        let words = seen.split(whereSeparator: \.isWhitespace)
        let context = words.suffix(leadInWords).joined(separator: " ")
        for index in sentences.indices { sentences[index].processed = true }
        return (fresh.map(\.text).joined(separator: " "), context)
    }

    /// New words waiting for the detector.
    var unprocessedWordCount: Int {
        sentences.filter { !$0.processed }
            .reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// The last few finalised sentences plus the live tail, for the Settings
    /// "Try it" panel.
    var display: String {
        let recent = sentences.suffix(4).map(\.text).joined(separator: " ")
        return volatileTail.isEmpty ? recent : (recent.isEmpty ? volatileTail : recent + " " + volatileTail)
    }

    mutating func reset() {
        sentences.removeAll()
        volatileTail = ""
        totalFinalized = 0
    }

    private mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        // Keep unprocessed sentences regardless of age; the detector still
        // owes them a pass.
        sentences.removeAll { $0.processed && $0.at < cutoff }
    }
}
