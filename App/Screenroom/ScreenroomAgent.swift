//
//  ScreenroomAgent.swift
//  Greenroom
//
//  Handing the presentation to whatever agent you already run.
//
//  Screenroom' own passes are deliberately small: an on-device model writing
//  feedback from the notes, and arithmetic over rubrics and timestamps.
//  That is the right floor - it works on a Mac with nothing configured and it
//  costs nothing. It is not a ceiling. A teacher who already pays for Claude
//  Code or Codex has a much larger model a keystroke away, and the material
//  Screenroom has assembled is exactly what such a thing is good at reading.
//
//  So: no API keys, no accounts, no model configuration inside Greenroom.
//  Screenroom writes a brief and runs the CLI you already have, in your own shell,
//  with your own credentials. Whatever you have configured is what runs.
//
//  WHAT THE AGENT CAN AND CANNOT SEE, stated plainly because the alternative
//  is a confident answer about a file nothing opened:
//
//   - **It cannot watch the video.** No coding agent takes an .mov. Screenroom
//     extracts stills every twenty seconds instead (ScreenroomFrames) and the
//     brief tells the agent what that does and does not support. Posture,
//     reading off a screen, facing the room, what is on the slide: yes.
//     Gesture and pace from pictures: no, and the brief says not to try.
//   - **It reads the transcript, not the audio.** Tone and volume are gone.
//     The countable things - filler words, words per minute, pauses - are
//     already counted (ScreenroomSpeechMetrics) and handed over as numbers, so
//     the agent spends its attention on what they mean rather than on
//     arithmetic it would get wrong.
//
//  READ-ONLY BY DEFAULT, and the output comes back through stdout rather than
//  the agent writing files. Both CLIs can be told to take a read-only
//  sandbox, and both are, in the default commands below. An agent that cannot
//  write cannot damage a folder holding the only copy of a student's
//  presentation, and Screenroom saving the output itself means there is nothing to
//  negotiate about permissions in a non-interactive shell.
//
//  Verified against the real binaries rather than their documentation:
//  `codex exec` refuses outright without `--skip-git-repo-check` when the
//  folder is not a git repository, which a Documents folder never is.
//
import Foundation

struct ScreenroomAgentSettings: Codable, Equatable {

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case claudeCode
        case codex
        case custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .custom: return "A command of my own"
            }
        }

        /// The command, as it will actually be run. Editable, because a CLI
        /// that changes its flags should cost one field rather than a release.
        ///
        /// Both read the brief from stdin, both are pinned to a read-only
        /// sandbox, and both are pointed at the presentation's folder.
        var defaultCommand: String {
            switch self {
            case .claudeCode:
                return #"claude -p --allowedTools "Read,Glob,Grep" --add-dir "$MARKS_FOLDER""#
            case .codex:
                return #"codex exec -s read-only --skip-git-repo-check -C "$MARKS_FOLDER" -"#
            case .custom:
                return ""
            }
        }
    }

    var kind: Kind = .claudeCode
    var command: String = Kind.claudeCode.defaultCommand
    /// Off until someone turns it on. Everything else in Screenroom runs on this
    /// Mac; this is the one part that may not, so it is never the default.
    var enabled: Bool = false

    static let key = "screenroomAgentSettings"

    static func load(_ defaults: UserDefaults = .standard) -> ScreenroomAgentSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ScreenroomAgentSettings.self, from: data) else {
            return ScreenroomAgentSettings()
        }
        return decoded
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

enum ScreenroomAgent {

    static let briefFileName = "BRIEF.md"
    static let reportFileName = "agent-report.md"

    enum Failure: LocalizedError {
        case noCommand
        case notFound(String)
        case failed(code: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .noCommand:
                return "No agent command is set. Settings \u{2192} Screenroom."
            case .notFound(let name):
                return "\(name) is not on this Mac's PATH. Open a Terminal, run `which \(name)`, and put the full path in Settings \u{2192} Screenroom."
            case .failed(let code, let output):
                let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
                return "The agent exited with code \(code).\n\(tail)"
            }
        }
    }

    // MARK: The brief

    /// What the agent is asked to do, written into the folder as BRIEF.md.
    ///
    /// A file rather than a string held in memory, for three reasons: the
    /// teacher can read exactly what was asked in their student's name, they
    /// can edit it before running, and the folder ends up holding the
    /// question next to the answer.
    static func brief(presenter: String,
                      notes: [ScreenroomNote],
                      metrics: ScreenroomSpeechMetrics?,
                      scoring: ScreenroomScoring?,
                      frameCount: Int,
                      hasTranscript: Bool) -> String {
        var out: [String] = []
        out.append("# Evaluate this presentation")
        out.append("")
        out.append("You are helping a teacher give feedback to a student, \(presenter.isEmpty ? "the speaker" : presenter), on a presentation they gave. Everything you need is in this folder.")
        out.append("")

        out.append("## What is here")
        out.append("")
        if hasTranscript {
            out.append("- `transcript.txt` \u{2014} what was said, with timestamps. Transcribed on the teacher's Mac, so expect recogniser errors, especially on names.")
        }
        out.append("- `notes.jsonl` \u{2014} notes the teacher typed WHILE watching, one JSON object per line. `atMs` is milliseconds into the recording. These are the most valuable thing here: they are a human in the room deciding what mattered, and nothing in the video recovers them.")
        if metrics != nil {
            out.append("- `speech.json` \u{2014} filler words, pace and pauses, already counted. Do not recount them; use them.")
        }
        if scoring != nil {
            out.append("- `rubric.json` \u{2014} the criteria the teacher marked against, and their marks.")
        }
        if frameCount > 0 {
            out.append("- `frames/` \u{2014} \(frameCount) stills, one every twenty seconds, named by where they fall in the recording.")
        }
        out.append("")

        out.append("## What you can and cannot judge")
        out.append("")
        out.append("Be strict about this. A confident sentence about something you could not observe is worse than no sentence, because the teacher will read it to a student.")
        out.append("")
        out.append("- **You cannot watch the video.** There is no video here you can open.")
        if frameCount > 0 {
            out.append("- **From the stills you CAN judge:** posture, whether they are reading off a screen, whether they face the room, what is on the slide behind them, changes in any of that over time.")
            out.append("- **From the stills you CANNOT judge:** gesture, movement, pace, energy, or eye contact in any moment you do not have a frame for. Twenty seconds apart is far too coarse for those. Do not infer them.")
        }
        out.append("- **You cannot hear anything.** Tone, volume, warmth, nerves in the voice: not available. The transcript is words only.")
        if metrics != nil {
            out.append("- **The counted numbers are reliable** and already computed. Interpreting them is your job; recomputing them is not.")
        }
        out.append("")

        out.append("## What to write")
        out.append("")
        out.append("Print ONE JSON object to standard output and nothing else. No prose before it, no code fence around it, no commentary about what you are about to do. Do not create or modify any files; you have read-only access and the teacher's app saves your output.")
        out.append("")
        out.append("```")
        out.append("""
        {
          "summary": "Three or four sentences to the student, second person, specific to this presentation.",
          "strengths": ["One short sentence each, tied to a moment with its time in words.", "..."],
          "workOn": ["One short sentence each, actionable next time, tied to where it showed.", "..."],
          "patterns": ["Things true of the whole talk rather than one moment.", "..."],
          "marks": [{"title": "<a rubric line, copied exactly>", "score": 3, "reason": "One line saying why that score and not the one above or below it."}]
        }
        """.trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("```")
        out.append("")
        out.append("At most four entries in strengths, workOn and patterns, and an empty array is a correct answer when the notes record nothing of that kind. Where the teacher's notes and your own reading disagree, say so and prefer the teacher's. They were in the room.")
        out.append("")
        out.append("**Marking.** Give every rubric line below a score and a reason. Copy each title exactly. The reason is the important half: a number with nothing behind it is an assertion, not feedback, and the student will ask why. Say what would have earned the mark above. Mark what the evidence here supports and nothing more \u{2014} if the material cannot tell you about a line, give it the middle of its range and say that you could not judge it.")
        out.append("")

        if let metrics {
            out.append("## The counted numbers")
            out.append("")
            for sentence in metrics.sentences { out.append("- \(sentence)") }
            out.append("")
        }

        if !notes.isEmpty {
            out.append("## The teacher's notes")
            out.append("")
            for note in notes {
                out.append("- `\(note.offsetLabel)` \(note.text)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    @discardableResult
    static func writeBrief(_ text: String, in folder: URL) -> URL {
        let target = folder.appendingPathComponent(briefFileName)
        try? text.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    // MARK: Running it

    /// Runs the configured command with the brief on stdin, in the
    /// presentation's folder, and returns what it printed.
    ///
    /// Through a LOGIN shell, not by exec'ing the binary directly. A GUI app
    /// inherits almost no PATH from launchd, so `claude` and `codex` - which
    /// live in /usr/local/bin, a Homebrew prefix, or a version manager's
    /// shim - are simply not findable from here. `zsh -lc` reads the user's
    /// own profile, which is the only way to run what they would run.
    static func run(settings: ScreenroomAgentSettings,
                    brief: String,
                    in folder: URL,
                    onOutput: (@MainActor (String) -> Void)? = nil) async throws -> String {
        let command = settings.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw Failure.noCommand }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = folder
        // The command templates refer to it, and a custom command can too.
        var environment = ProcessInfo.processInfo.environment
        environment["MARKS_FOLDER"] = folder.path
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        try process.run()

        // Written and closed before reading: these agents do not begin until
        // stdin is at EOF, so holding it open deadlocks the whole thing.
        input.fileHandleForWriting.write(Data(brief.utf8))
        try? input.fileHandleForWriting.close()

        // Read both pipes concurrently. Draining only stdout deadlocks the
        // moment a chatty agent fills the stderr buffer - which both of these
        // do, since progress goes to stderr.
        async let collected = drain(output.fileHandleForReading, onOutput: onOutput)
        async let problems = drain(errors.fileHandleForReading, onOutput: nil)

        let text = await collected
        let errorText = await problems
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.failed(code: process.terminationStatus,
                                 output: errorText.isEmpty ? text : errorText)
        }
        return text
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
                    if let report = onOutput {
                        Task { @MainActor in report(piece) }
                    }
                }
                continuation.resume(returning: whole)
            }
        }
    }

    @discardableResult
    static func writeReport(_ text: String, in folder: URL) -> URL? {
        let target = folder.appendingPathComponent(reportFileName)
        guard (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil else { return nil }
        return target
    }

    static func existingReport(in folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(reportFileName), encoding: .utf8)
    }
}

extension ScreenroomAgent {

    /// Turns whatever the agent printed into the same shape the on-device
    /// pass produces, so the report renders identically whichever engine ran.
    ///
    /// Tolerant on purpose. Agents wrap JSON in a code fence, or say "Here is
    /// the report:" first, however plainly they are told not to - and a
    /// student's feedback is not worth losing to a stray backtick. So this
    /// takes the outermost {...} it can find and parses that. When even that
    /// fails the whole output becomes the summary, which is worse-looking and
    /// still readable, rather than nothing at all.
    static func analysis(from output: String, engine: String,
                         consistency: [String]) -> ScreenroomAnalysis {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"),
           open < close,
           let data = String(trimmed[open...close]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            let summary = (object["summary"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !summary.isEmpty {
                return ScreenroomAnalysis(
                    engine: engine,
                    summary: summary,
                    strengths: strings(object["strengths"]),
                    workOn: strings(object["workOn"]),
                    patterns: strings(object["patterns"]),
                    marks: marks(object["marks"]),
                    consistency: consistency)
            }
        }
        return ScreenroomAnalysis(engine: engine, summary: trimmed, consistency: consistency)
    }

    /// The marks, defensively. A model asked for an integer will hand back
    /// "4", 4.0 or "4/5" often enough that insisting on Int loses the whole
    /// rubric to one bad line.
    private static func marks(_ value: Any?) -> [ScreenroomAnalysis.Mark] {
        (value as? [Any] ?? []).compactMap { entry in
            guard let row = entry as? [String: Any],
                  let title = (row["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let score: Int?
            switch row["score"] {
            case let n as Int: score = n
            case let d as Double: score = Int(d.rounded())
            case let text as String:
                score = Int(text.prefix(while: { $0.isNumber }))
            default: score = nil
            }
            guard let score else { return nil }
            return ScreenroomAnalysis.Mark(
                title: title, score: score,
                reason: (row["reason"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 2 }
    }
}
