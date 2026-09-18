//
//  MarksTranscriber.swift
//  Greenroom
//
//  Turning presentation.mov into words, with the time each one was said.
//
//  Everything downstream needs this. Filler counts, pace, pauses and any
//  agent pass worth running all start from a transcript with timings; without
//  it Marks can only report what the teacher typed, which is the half it
//  already had.
//
//  **On-device only, and it refuses rather than falling back.**
//  SFSpeechRecognizer will happily send audio to Apple's servers when the
//  on-device model is missing, and it does it silently - the API returns
//  results either way. That would make a recording of a named student leave
//  this Mac because a model had not downloaded, which is not a trade anybody
//  agreed to. So `requiresOnDeviceRecognition` is set, `supportsOnDeviceRecognition`
//  is checked first, and a Mac that cannot do it locally is told so.
//
//  This is different from Cues, which uses SpeechAnalyzer (macOS 26) on a
//  live microphone stream. A finished file on macOS 14 is a different problem
//  with a different API, and SFSpeechRecognizer is the one that has existed
//  since 10.15. It costs an Info.plist key that this app deliberately did not
//  have - NSSpeechRecognitionUsageDescription - and the comment there was
//  updated to say why it now does.
//
import AVFoundation
import Foundation
import Speech

enum MarksTranscriber {

    enum Failure: LocalizedError {
        case denied
        case noLocalModel(String)
        case noSpeech
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Speech recognition is not allowed. Turn it on in System Settings \u{2192} Privacy & Security \u{2192} Speech Recognition."
            case .noLocalModel(let locale):
                return "This Mac cannot transcribe \(locale) without sending audio to Apple, so Marks will not transcribe at all. Add the language in System Settings \u{2192} General \u{2192} Language & Region and try again."
            case .noSpeech:
                return "No speech was found in that recording."
            case .failed(let reason):
                return reason
            }
        }
    }

    static let transcriptFileName = "transcript.txt"
    static let wordsFileName = "words.json"

    /// Which language the presentations are in. `en_IN` is supported and is
    /// the default here for the same reason Cues offers it: this was built
    /// for a classroom in India, and `en_US` mis-hears it constantly.
    static let defaultLocale = "en_IN"

    static func isAvailable(locale identifier: String = defaultLocale) -> (ok: Bool, reason: String?) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else {
            return (false, "\(identifier) is not a language this Mac can transcribe")
        }
        guard recognizer.isAvailable else { return (false, "the recogniser is not available right now") }
        guard recognizer.supportsOnDeviceRecognition else {
            return (false, "this Mac has no on-device model for \(identifier), and Marks will not send audio to Apple")
        }
        return (true, nil)
    }

    /// Transcribes the recording and writes both files into the folder.
    ///
    /// `transcript.txt` is for a person and for an agent to read; `words.json`
    /// carries the timings that MarksSpeechMetrics needs. Two files rather
    /// than one because the readable one should stay readable - a text file
    /// full of millisecond offsets is neither.
    static func transcribe(recording: URL,
                           into folder: URL,
                           locale identifier: String = defaultLocale,
                           onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> [MarksSpokenWord] {
        let status = await authorize()
        guard status == .authorized else { throw Failure.denied }

        let availability = isAvailable(locale: identifier)
        guard availability.ok, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else {
            throw Failure.noLocalModel(identifier)
        }

        let request = SFSpeechURLRecognitionRequest(url: recording)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        // Timings are the entire point; without this the segments come back
        // with no useful offsets and the metrics have nothing to measure.
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = true }

        let total = (try? await AVURLAsset(url: recording).load(.duration))?.seconds ?? 0

        let words: [MarksSpokenWord] = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: Failure.failed(error.localizedDescription))
                    return
                }
                guard let result else { return }

                if let report = onProgress, total > 0,
                   let last = result.bestTranscription.segments.last {
                    let fraction = min(1, (last.timestamp + last.duration) / total)
                    Task { @MainActor in report(fraction) }
                }

                guard result.isFinal else { return }
                resumed = true
                continuation.resume(returning: result.bestTranscription.segments.map {
                    MarksSpokenWord(text: $0.substring,
                                    atMs: Int($0.timestamp * 1000),
                                    durationMs: Int($0.duration * 1000))
                })
            }
        }

        guard !words.isEmpty else { throw Failure.noSpeech }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        write(words, in: folder, durationMs: Int(total * 1000))
        return words
    }

    /// The readable transcript, broken into lines every so often.
    ///
    /// One line per sentence would be better and the recogniser does not
    /// reliably give sentences, so this breaks on a long pause instead -
    /// which is usually where a sentence ended anyway, and is at least a
    /// break the speaker actually made.
    static func write(_ words: [MarksSpokenWord], in folder: URL, durationMs: Int) {
        var lines: [String] = []
        var current: [String] = []
        var lineStart = words.first?.atMs ?? 0

        for (index, word) in words.enumerated() {
            current.append(word.text)
            let gapAhead = index + 1 < words.count ? words[index + 1].atMs - word.endMs : Int.max
            if gapAhead >= 1_200 || current.count >= 40 {
                lines.append("[\(stamp(lineStart))] " + current.joined(separator: " "))
                current = []
                lineStart = index + 1 < words.count ? words[index + 1].atMs : word.endMs
            }
        }
        if !current.isEmpty { lines.append("[\(stamp(lineStart))] " + current.joined(separator: " ")) }

        try? (lines.joined(separator: "\n") + "\n")
            .write(to: folder.appendingPathComponent(transcriptFileName),
                   atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(words) {
            try? data.write(to: folder.appendingPathComponent(wordsFileName), options: .atomic)
        }

        MarksSpeechMetrics.measure(words: words, durationMs: durationMs).save(in: folder)
    }

    static func loadWords(in folder: URL) -> [MarksSpokenWord] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(wordsFileName)) else { return [] }
        return (try? JSONDecoder().decode([MarksSpokenWord].self, from: data)) ?? []
    }

    private static func stamp(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}
