//
//  ScreenroomWhisper.swift
//  Greenroom
//
//  Verbatim transcription, through whisper.cpp.
//
//  WHY NOT APPLE'S, which is already here and needs nothing installed:
//  because Apple's recogniser returns a CLEAN transcript. It is built for
//  dictation, where "um, I think, uh, we should" is noise the user did not
//  mean to type, so it smooths disfluencies out and punctuates what is left.
//  That is the correct behaviour for dictation and it is fatal here:
//  ScreenroomSpeechMetrics exists to count exactly the words Apple is removing.
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

enum ScreenroomWhisper {

    enum Failure: LocalizedError {
        case noBinary
        case noModel
        case failed(String)
        case noWords

        var errorDescription: String? {
            switch self {
            case .noBinary:
                return "whisper-cli was not found. Install it with `brew install whisper-cpp`, or point Screenroom at your own transcriber."
            case .noModel:
                return "No whisper model was found. Download one into ~/Library/Application Support/Greenroom/whisper/ \u{2014} see the Deep tab for the exact command."
            case .noWords:
                return "The transcriber produced no words. The recording may have no speech in it."
            case .failed(let reason):
                return reason
            }
        }
    }

    /// Where a model can live, in the order Screenroom looks.
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

    /// One model file on disk, and what it is good for.
    struct Model: Identifiable, Hashable {
        let url: URL
        let bytes: Int64
        var id: URL { url }

        /// `ggml-small.en.bin` -> `small.en`.
        var name: String {
            url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "ggml-", with: "")
        }

        /// `small.en` -> `small`. Quantisation suffixes come off too, since
        /// `small.en-q5_0` is still a small English-only model.
        var family: String {
            var base = name
            if let dash = base.range(of: "-q", options: .backwards) { base = String(base[..<dash.lowerBound]) }
            return base.replacingOccurrences(of: ".en", with: "")
        }

        /// The `.en` models are trained on English-only data that skews
        /// American. The multilingual ones see far more accented English.
        var isEnglishOnly: Bool { name.contains(".en") }

        var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

        /// What the picker shows. The variant matters more than the bytes and
        /// is invisible in the file size: `small` and `small.en` are both
        /// 465 MB and are not equally good at the same job.
        var label: String {
            "\(family)  \u{00B7}  \(isEnglishOnly ? "English-only" : "multilingual")  \u{00B7}  \(sizeLabel)"
        }

        /// Bigger family wins; within a family, multilingual wins.
        ///
        /// Measured on a real 42-second talk in Indian English: `small.en`
        /// heard the subject of the talk as "All 9 shopping" where the
        /// same-sized multilingual `small` heard "Online shopping". Both are
        /// 465 MB, so ranking by file size picked between them at random.
        /// The family ordering is the conventional one and was not measured
        /// here - a medium English-only model against a small multilingual is
        /// an open question on this voice.
        var rank: Int {
            let families = ["tiny": 0, "base": 1, "small": 2, "medium": 3]
            let tier = families[family] ?? (family.hasPrefix("large") ? 4 : 0)
            return tier * 2 + (isEnglishOnly ? 0 : 1)
        }
    }

    /// Every model on this Mac, worst first, so the last is the best.
    ///
    /// Ordered by capability rather than by bytes - see `Model.rank`. Test
    /// fixtures are excluded by name: they are deliberately useless and would
    /// otherwise appear as a choice.
    static func availableModels() -> [Model] {
        var seen = Set<String>()
        var models: [Model] = []
        for folder in modelSearchPaths {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "bin"
                && !file.lastPathComponent.contains("for-tests") {
                guard seen.insert(file.lastPathComponent).inserted else { continue }
                let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                models.append(Model(url: file, bytes: bytes))
            }
        }
        return models.sorted { $0.rank == $1.rank ? $0.bytes < $1.bytes : $0.rank < $1.rank }
    }

    /// The other sizes, and the one line that fetches each.
    ///
    /// Offered rather than downloaded: the app has no business pulling a
    /// gigabyte over somebody's connection without being asked, and a teacher
    /// who wants the better model can paste a line.
    static let offeredModels: [(name: String, size: String, note: String)] = [
        ("ggml-small.bin", "465 MB", "Multilingual. Best tested here on accented English \u{2014} it heard \u{201C}online shopping\u{201D} where the English-only model of the same size heard \u{201C}All 9 shopping\u{201D}."),
        ("ggml-medium.bin", "1.5 GB", "Multilingual, better again, and about three times slower."),
        ("ggml-base.en.bin", "141 MB", "English-only and fast. Fine for clear American or British English, weak on accents."),
        ("ggml-small.en.bin", "465 MB", "English-only. Same size as the multilingual small and worse on the voice tested here."),
    ]

    static func downloadCommand(for name: String) -> String {
        "mkdir -p \"\(installFolder.path)\" && curl -L -o \"\(installFolder.path)/\(name)\" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)"
    }

    /// The best model on this Mac, or nil.
    ///
    /// Best by `Model.rank`, not by file size. Size was the wrong proxy the
    /// moment two 465 MB files turned out to be very different at the job.
    static func findModel() -> URL? {
        availableModels().last?.url
    }

    /// The model Screenroom suggests, and the one line that fetches it.
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
                           onStart: ((Process) -> Void)? = nil,
                           onOutput: (@MainActor (String) -> Void)? = nil) async throws -> [ScreenroomSpokenWord] {
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
        onStart?(process)

        // Both pipes drained, because whisper is chatty on stderr and a full
        // buffer there stops the process dead - the same deadlock ScreenroomAgent
        // has a comment about.
        // stderr only: whisper's progress goes there, and stdout is the
        // transcript itself.
        async let out = drain(output.fileHandleForReading, onOutput: nil)
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
    static func parse(_ data: Data) -> [ScreenroomSpokenWord] {
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
            return ScreenroomSpokenWord(text: text, atMs: from, durationMs: max(0, to - from))
        }
    }

    // MARK: Finding the binary

    static func binaryPath() throws -> String {
        if let found = resolvedBinary { return found }
        throw Failure.noBinary
    }

    /// Resolved through a LOGIN shell for the reason ScreenroomAgent explains: a
    /// GUI app inherits almost no PATH, so a Homebrew binary is simply not
    /// findable from here without reading the user's own profile.
    ///
    /// Looked up once and remembered. It used to run up to three login shells
    /// on every read, and it is read from SwiftUI - a view's @State initial
    /// value, `isAvailable` in the Cues workbench - so every redraw paid for
    /// them on the main thread. Worse, `waitUntilExit()` spins the run loop,
    /// and a layout pass that ran inside that spin, in the middle of the view
    /// update that asked, tripped SwiftUI's re-entrancy check: opening
    /// Settings → Screenroom aborted the app. `refreshBinary()` asks again,
    /// for "Look again" after an install.
    static var resolvedBinary: String? {
        binaryLock.lock()
        if let cached = cachedBinary {
            binaryLock.unlock()
            return cached
        }
        binaryLock.unlock()
        let found = lookUpBinary()
        binaryLock.lock()
        cachedBinary = .some(found)
        binaryLock.unlock()
        return found
    }

    /// Forgets the answer, so the next read looks again.
    static func refreshBinary() {
        binaryLock.lock()
        cachedBinary = nil
        binaryLock.unlock()
    }

    private static let binaryLock = NSLock()
    /// nil: not looked yet. .some(nil): looked, and there is none.
    private static var cachedBinary: String??

    private static func lookUpBinary() -> String? {
        for name in ["whisper-cli", "whisper-cpp", "main"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v \(name)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Not waitUntilExit(): that runs the run loop, which is how a
            // layout pass got in. The output has ended, so the shell is
            // exiting; poll for it without servicing anything else.
            while process.isRunning { usleep(2_000) }
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
