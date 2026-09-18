//
//  MarksWhisper.swift
//  Greenroom
//
//  Verbatim transcription, through whisper.cpp.
//
//  WHY NOT APPLE'S, which is already here and needs nothing installed:
//  because Apple's recogniser returns a CLEAN transcript. It is built for
//  dictation, where "um, I think, uh, we should" is noise the user did not
//  mean to type, so it smooths disfluencies out and punctuates what is left.
//  That is the correct behaviour for dictation and it is fatal here:
//  MarksSpeechMetrics exists to count exactly the words Apple is removing.
//  A filler count taken from an Apple transcript is not an approximation, it
//  is a measurement of how good Apple is at deleting the evidence, and it
//  would have read as a confident zero.
//
//  Measured rather than assumed. The same sentence, spoken by `say` and
//  handed to both:
//
//    spoken:  "Um, good morning everyone. So today I want to, uh, you know,
//              talk about how tigers are, like, basically disappearing."
//    whisper: "Um, good morning everyone, so today I want to, uh, you know,
//              talk about how tigers are, like, basically disappearing."
//
//  Every filler kept, with a millisecond offset on each word.
//
//  No `--prompt` priming, deliberately. Seeding whisper with a line of
//  fillers is the usual trick for making it keep them, and it was tried: the
//  output was byte-identical with and without. A prompt that changes nothing
//  on clean input is a prompt that can only hurt on messy input, by biasing
//  the model toward hearing fillers that were not said. A false "um" in a
//  student's report is worse than a missed one.
//
import Foundation

enum MarksWhisper {

    enum Failure: LocalizedError {
        case noBinary
        case noModel
        case failed(String)
        case noWords

        var errorDescription: String? {
            switch self {
            case .noBinary:
                return "whisper-cli was not found. Install it with `brew install whisper-cpp`, or point Marks at your own transcriber."
            case .noModel:
                return "No whisper model was found. Download one into ~/Library/Application Support/Greenroom/whisper/ \u{2014} see the Deep tab for the exact command."
            case .noWords:
                return "The transcriber produced no words. The recording may have no speech in it."
            case .failed(let reason):
                return reason
            }
        }
    }

    /// Where a model can live, in the order Marks looks.
    ///
    /// Greenroom's own folder first, so a teacher who followed the
    /// instructions in the window wins over whatever a package manager left
    /// lying about; a stale tiny test model in a Homebrew share directory
    /// would otherwise silently produce a terrible transcript.
    static var modelSearchPaths: [URL] {
        var paths: [URL] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first {
            paths.append(support.appendingPathComponent("Greenroom/whisper", isDirectory: true))
        }
        paths.append(URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp"))
        paths.append(URL(fileURLWithPath: "/usr/local/share/whisper-cpp"))
        paths.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/whisper", isDirectory: true))
        return paths
    }

    static var installFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Greenroom/whisper", isDirectory: true)
    }

    /// The best model on this Mac, or nil.
    ///
    /// Bigger is better and slower, and the sort puts the biggest FILE first
    /// rather than reading names: whisper models are named by a convention
    /// that has changed more than once, and the byte count has not.
    /// Test fixtures are excluded by name because they are deliberately
    /// useless and would otherwise win on a Mac with nothing else.
    static func findModel() -> URL? {
        for folder in modelSearchPaths {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }
            let models = files.filter {
                $0.pathExtension == "bin" && !$0.lastPathComponent.contains("for-tests")
            }
            let best = models.max {
                let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return a < b
            }
            if let best { return best }
        }
        return nil
    }

    /// The model Marks suggests, and the one line that fetches it.
    ///
    /// base.en: 141 MB, and on Apple silicon it transcribes a ten-minute talk
    /// in well under a minute. small.en is noticeably better on accented
    /// speech and four times the size; the window says so rather than
    /// choosing for the teacher.
    static let suggestedModel = "ggml-base.en.bin"
    static var downloadCommand: String {
        "mkdir -p \"\(installFolder.path)\" && curl -L -o \"\(installFolder.path)/\(suggestedModel)\" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(suggestedModel)"
    }

    /// Runs whisper over a WAV and returns one entry per word.
    ///
    /// `-ml 1 -sow` is the documented way to get word-level timings out of
    /// whisper.cpp: maximum segment length of one, split on word rather than
    /// on token, so every segment in the JSON is a single word with its own
    /// offsets. Without `-sow` the split lands on model tokens, which cut
    /// words in half.
    static func transcribe(wav: URL,
                           model: URL,
                           language: String,
                           onOutput: (@MainActor (String) -> Void)? = nil) async throws -> [MarksSpokenWord] {
        let base = wav.deletingPathExtension()
        let jsonURL = base.appendingPathExtension("json")
        try? FileManager.default.removeItem(at: jsonURL)

        let command = [
            shellQuote(try binaryPath()),
            "-m", shellQuote(model.path),
            "-f", shellQuote(wav.path),
            "-l", shellQuote(language),
            "-ml", "1", "-sow",
            "-oj", "-of", shellQuote(base.path),
            "-np",
        ].joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // Both pipes drained, because whisper is chatty on stderr and a full
        // buffer there stops the process dead - the same deadlock MarksAgent
        // has a comment about.
        async let out = drain(output.fileHandleForReading, onOutput: onOutput)
        async let err = drain(errors.fileHandleForReading, onOutput: onOutput)
        _ = await out
        let problems = await err
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.failed(problems.split(separator: "\n").suffix(4).joined(separator: "\n"))
        }
        guard let data = try? Data(contentsOf: jsonURL) else {
            throw Failure.failed("whisper finished but wrote no JSON.")
        }
        let words = parse(data)
        guard !words.isEmpty else { throw Failure.noWords }
        try? FileManager.default.removeItem(at: jsonURL)
        return words
    }

    /// whisper.cpp's JSON: `transcription` is an array of segments, each with
    /// `offsets.from`/`.to` in milliseconds and a `text`. With `-ml 1 -sow`
    /// each one is a word, arriving with its leading space still attached.
    static func parse(_ data: Data) -> [MarksSpokenWord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = root["transcription"] as? [[String: Any]] else { return [] }

        return segments.compactMap { segment in
            guard let raw = segment["text"] as? String,
                  let offsets = segment["offsets"] as? [String: Any],
                  let from = offsets["from"] as? Int else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty segments are real: whisper emits one at the head of every
            // run, and blank entries would count as words and drag the pace
            // down.
            guard !text.isEmpty else { return nil }
            let to = offsets["to"] as? Int ?? from
            return MarksSpokenWord(text: text, atMs: from, durationMs: max(0, to - from))
        }
    }

    // MARK: Finding the binary

    static func binaryPath() throws -> String {
        if let found = resolvedBinary { return found }
        throw Failure.noBinary
    }

    /// Resolved through a LOGIN shell for the reason MarksAgent explains: a
    /// GUI app inherits almost no PATH, so a Homebrew binary is simply not
    /// findable from here without reading the user's own profile.
    static var resolvedBinary: String? {
        for name in ["whisper-cli", "whisper-cpp", "main"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v \(name)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func drain(_ handle: FileHandle,
                              onOutput: (@MainActor (String) -> Void)?) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var whole = ""
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    guard let piece = String(data: chunk, encoding: .utf8) else { continue }
                    whole += piece
                    if let report = onOutput { Task { @MainActor in report(piece) } }
                }
                continuation.resume(returning: whole)
            }
        }
    }
}
