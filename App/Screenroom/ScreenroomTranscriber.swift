//
//  ScreenroomTranscriber.swift
//  Greenroom
//
//  Turning presentation.mov into words, with the time each one was said.
//
//  Everything downstream needs this. Filler counts, pace, pauses and any
//  agent pass worth running all start from a transcript with timings.
//
//  **Two engines, and the default is not Apple's.**
//
//  Apple's SFSpeechRecognizer is already here and needs nothing installed,
//  which made it the obvious first choice and the wrong one. It is built for
//  dictation: "um, I think, uh, we should" is noise a person did not mean to
//  type, so it smooths disfluencies away and punctuates what is left. Correct
//  for dictation, fatal here - ScreenroomSpeechMetrics exists to count exactly the
//  words Apple removes, so a filler count taken from an Apple transcript
//  measures how well Apple deleted the evidence and reads as a confident
//  zero. whisper.cpp returns what was actually said (see ScreenroomWhisper for the
//  measurement) and is the default.
//
//  Apple's is kept as a fallback rather than deleted, because a Mac with no
//  whisper installed should still get a transcript and an agent pass - just
//  not a filler count. When it is used, `speech.json` records the engine and
//  sets `verbatim` to false, and every surface that prints a filler number
//  says plainly that it did not count them and why.
//
//  **Whichever engine runs, nothing leaves the Mac.** whisper.cpp is a local
//  binary over a local file. Apple's path is pinned to on-device recognition
//  and REFUSES rather than falling back: SFSpeechRecognizer will silently
//  send audio to Apple's servers when the local model is missing, returning
//  results either way with no indication which happened, and a recording of a
//  named student should not leave because a download had not finished.
//
import AVFoundation
import Foundation
import Speech

/// Which transcriber to use, and where its model is.
///
/// Named for Screenroom because that is where it was written, and it is no
/// longer only Screenroom's: Cues listens through the same whisper model, and
/// nobody wants two on one Mac. Both settings tabs show the same picker
/// (WhisperModelPicker) rather than one owning it and the other inheriting it
/// invisibly. The name is a leftover, not a scope.
struct ScreenroomTranscriberSettings: Codable, Equatable {

    enum Engine: String, Codable, CaseIterable, Identifiable {
        /// whisper.cpp. Verbatim; needs a binary and a model.
        case whisper
        /// Apple's. Built in, needs nothing, removes the fillers.
        case apple
        var id: String { rawValue }

        var label: String {
            switch self {
            case .whisper: return "Whisper (verbatim)"
            case .apple: return "Apple (cleaned up)"
            }
        }

        var isVerbatim: Bool { self == .whisper }
    }

    /// Stored, but not obeyed: `resolved()` sets it from what this Mac has.
    ///
    /// Kept in the file rather than removed so a settings export written by
    /// an older build still decodes, and so the last value is visible when
    /// debugging. Reading it directly is a bug - it said "apple" on a Mac
    /// that had been running whisper for a day.
    var engine: Engine = .whisper
    /// Empty means "find the best one on this Mac".
    var modelPath: String = ""
    /// `en_IN` for Apple, `en` for whisper - the two name languages
    /// differently, and the engines convert as needed.
    var language: String = "en_IN"

    static let key = "screenroomTranscriberSettings"

    /// What the pipeline actually uses. There is no picker any more.
    ///
    /// Whisper when this Mac has it, Apple's when it does not. That is not a
    /// preference, it is a fact about the Mac: Apple's recogniser deletes the
    /// disfluencies the whole speech analysis exists to count, so nobody would
    /// choose it, and offering the choice only invited somebody to get it
    /// wrong. A Mac without whisper still gets a transcript and a report - it
    /// just gets no filler count, and the report says so in a sentence.
    static func resolved(_ defaults: UserDefaults = .standard) -> ScreenroomTranscriberSettings {
        var settings = load(defaults)
        settings.engine = whisperIsReady ? .whisper : .apple
        return settings
    }

    static var whisperIsReady: Bool {
        ScreenroomWhisper.resolvedBinary != nil && resolvedModel() != nil
    }

    /// The model to run: the one chosen, when it is still on disk, and
    /// otherwise the best one there is.
    ///
    /// Falling back rather than failing, because a model can be deleted or a
    /// folder moved between one session and the next, and a teacher should
    /// not meet that as an error on the morning they needed a transcript.
    static func resolvedModel(_ defaults: UserDefaults = .standard) -> URL? {
        let chosen = load(defaults).modelPath
        if !chosen.isEmpty, FileManager.default.fileExists(atPath: chosen) {
            return URL(fileURLWithPath: chosen)
        }
        return ScreenroomWhisper.findModel()
    }

    static func load(_ defaults: UserDefaults = .standard) -> ScreenroomTranscriberSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ScreenroomTranscriberSettings.self, from: data) else {
            return ScreenroomTranscriberSettings()
        }
        return decoded
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

enum ScreenroomTranscriber {

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
                return "This Mac cannot transcribe \(locale) without sending audio to Apple, so Screenroom will not transcribe at all. Add the language in System Settings \u{2192} General \u{2192} Language & Region and try again."
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
            return (false, "this Mac has no on-device model for \(identifier), and Screenroom will not send audio to Apple")
        }
        return (true, nil)
    }

    /// Transcribes the recording and writes both files into the folder.
    ///
    /// `transcript.txt` is for a person and for an agent to read; `words.json`
    /// carries the timings that ScreenroomSpeechMetrics needs. Two files rather
    /// than one because the readable one should stay readable - a text file
    /// full of millisecond offsets is neither.
    /// Transcribes with whichever engine is configured.
    static func transcribe(recording: URL,
                           into folder: URL,
                           settings: ScreenroomTranscriberSettings,
                           onProgress: (@MainActor (Double) -> Void)? = nil,
                           onStart: ((Process) -> Void)? = nil,
                           onOutput: (@MainActor (String) -> Void)? = nil) async throws -> [ScreenroomSpokenWord] {
        let durationMs = Int(((try? await AVURLAsset(url: recording).load(.duration))?.seconds ?? 0) * 1000)

        switch settings.engine {
        case .whisper:
            guard let model = ScreenroomTranscriberSettings.resolvedModel() else {
                throw ScreenroomWhisper.Failure.noModel
            }
            // The WAV lives beside the recording only while whisper reads it.
            let wav = folder.appendingPathComponent("audio-for-transcription.wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            _ = try await ScreenroomAudio.extractWAV(from: recording, to: wav)
            // whisper names languages without a region.
            let language = String(settings.language.prefix(2))
            let words = try await ScreenroomWhisper.transcribe(
                wav: wav, model: model, language: language,
                onStart: onStart, onOutput: onOutput)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            write(words, in: folder, durationMs: durationMs,
                  engine: "whisper.cpp (\(model.lastPathComponent))", verbatim: true)
            return words

        case .apple:
            return try await transcribeWithApple(
                recording: recording, into: folder,
                locale: settings.language, durationMs: durationMs, onProgress: onProgress)
        }
    }

    private static func transcribeWithApple(recording: URL,
                                            into folder: URL,
                                            locale identifier: String,
                                            durationMs: Int,
                                            onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> [ScreenroomSpokenWord] {
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
        // Off. Punctuation is invented by a language model reading the words
        // back, and this path's whole problem is already that too much has
        // been decided about the text before Screenroom sees it.
        if #available(macOS 13.0, *) { request.addsPunctuation = false }

        let total = (try? await AVURLAsset(url: recording).load(.duration))?.seconds ?? 0

        let words: [ScreenroomSpokenWord] = try await withCheckedThrowingContinuation { continuation in
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
                    ScreenroomSpokenWord(text: $0.substring,
                                    atMs: Int($0.timestamp * 1000),
                                    durationMs: Int($0.duration * 1000))
                })
            }
        }

        guard !words.isEmpty else { throw Failure.noSpeech }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        write(words, in: folder, durationMs: durationMs > 0 ? durationMs : Int(total * 1000),
              engine: "Apple Speech", verbatim: false)
        return words
    }

    /// The readable transcript, broken into lines every so often.
    ///
    /// One line per sentence would be better and the recogniser does not
    /// reliably give sentences, so this breaks on a long pause instead -
    /// which is usually where a sentence ended anyway, and is at least a
    /// break the speaker actually made.
    static func write(_ words: [ScreenroomSpokenWord], in folder: URL, durationMs: Int,
                      engine: String, verbatim: Bool) {
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

        ScreenroomSpeechMetrics.measure(words: words, durationMs: durationMs,
                                   engine: engine, verbatim: verbatim).save(in: folder)
    }

    static func loadWords(in folder: URL) -> [ScreenroomSpokenWord] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(wordsFileName)) else { return [] }
        return (try? JSONDecoder().decode([ScreenroomSpokenWord].self, from: data)) ?? []
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
