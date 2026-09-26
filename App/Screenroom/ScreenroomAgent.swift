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
        /// sandbox, and both are pointed at the session's folder.
        ///
        /// Both also stream structured events - `--output-format stream-json`
        /// for Claude Code, `--json` for Codex - so the window can say what
        /// the agent is DOING rather than leaving a spinner up for two
        /// minutes. Without them the only thing on stdout is the answer, and
        /// the only honest thing to show is nothing at all, which is what the
        /// first version did and it read as a hang.
        var defaultCommand: String {
            switch self {
            case .claudeCode:
                return #"claude -p --output-format stream-json --verbose --allowedTools "Read,Glob,Grep" --add-dir "$SCREENROOM_FOLDER""#
            case .codex:
                return #"codex exec -s read-only --skip-git-repo-check --json -C "$SCREENROOM_FOLDER" -"#
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

    /// Commands this app shipped as a default and has since replaced.
    ///
    /// A stored command is upgraded only when it matches one of these
    /// exactly. Anything else is something the teacher wrote or edited, and
    /// overwriting that is the kind of thing that costs somebody an
    /// afternoon.
    ///
    /// This exists because it bit: a command saved before the event-streaming
    /// flags were added kept running without them, so the window showed a
    /// spinner and nothing else while the agent worked - the whole activity
    /// display was dead for anyone who had used the feature once before.
    /// Defaults do not update themselves.
    private static let supersededCommands: Set<String> = [
        #"claude -p --allowedTools "Read,Glob,Grep" --add-dir "$MARKS_FOLDER""#,
        #"claude -p --allowedTools "Read,Glob,Grep" --add-dir "$SCREENROOM_FOLDER""#,
        #"codex exec -s read-only --skip-git-repo-check -C "$MARKS_FOLDER" -"#,
        #"codex exec -s read-only --skip-git-repo-check -C "$SCREENROOM_FOLDER" -"#,
    ]

    static func load(_ defaults: UserDefaults = .standard) -> ScreenroomAgentSettings {
        guard let data = defaults.data(forKey: key),
              var decoded = try? JSONDecoder().decode(ScreenroomAgentSettings.self, from: data) else {
            return ScreenroomAgentSettings()
        }
        let stored = decoded.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if supersededCommands.contains(stored), decoded.kind != .custom {
            decoded.command = decoded.kind.defaultCommand
            decoded.save(defaults)
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
                      presence: ScreenroomPresence?,
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
            out.append("- `speech.json` \u{2014} filler words, hedges, pace, pauses, sentence length, sentence openers and vocabulary variety, already counted. Do not recount them; use them.")
        }
        if presence != nil {
            out.append("- `presence.json` \u{2014} the recording sampled every two seconds by Apple's Vision framework: whether a face was found, which way the head was turned, whether the hands were up, how far the wrists moved. Already counted.")
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
            out.append("- **From the stills you CAN judge:** posture, whether they are reading off a screen, what is on the slide behind them, changes in any of that over time.")
            out.append("- **From the stills you CANNOT judge:** gesture, movement, pace or energy in any moment you do not have a frame for. Twenty seconds apart is far too coarse for those. Do not infer them.")
        }
        if presence != nil {
            out.append("- **Head direction and hand movement ARE measured** for you, every two seconds, and are in the numbers below. Use those figures rather than reading them off the stills.")
            out.append("- **The facing figure is NOT eye contact.** It is the angle of the head. Do not write the phrase \"eye contact\" anywhere; nothing here measured where the eyes were pointed.")
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
          "headline": "The verdict in six to ten words, to the student.",
          "summary": "One or two sentences to the student, second person, specific to this presentation.",
          "strengths": [{"headline": "At most eight words", "detail": "One sentence, second person.", "atSeconds": 17}, "..."],
          "workOn": [{"headline": "At most eight words, what to do", "detail": "One sentence: what showed, and what to do next time.", "atSeconds": 2}, "..."],
          "patterns": ["Things true of the whole talk rather than one moment. One sentence each.", "..."],
          "marks": [{"title": "<a rubric line, copied exactly>", "score": 3, "reason": "One line saying why that score and not the one above or below it."}]
        }
        """.trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("```")
        out.append("")
        out.append("At most four entries in strengths, workOn and patterns, and an empty array is a correct answer when the notes record nothing of that kind. Where the teacher's notes and your own reading disagree, say so and prefer the teacher's. They were in the room.")
        out.append("")
        out.append("**Short, and anchored to a moment.** The report draws every point as a card with the still from its moment and a button that plays from there, so the words only have to say what the picture cannot. The headline is read at a glance: a few words, no numbers spelled out, no times in it. The detail is one sentence. `atSeconds` is where in the recording the point showed, as a number of seconds; for something that ran over a stretch, give where it started; leave it out only when the point is about the whole talk, and then it probably belongs in patterns. Put the most important thing to change first: the report leads with it.")
        out.append("")
        out.append("**Marking.** Give every rubric line below a score and a reason. Copy each title exactly. The reason is the important half: a number with nothing behind it is an assertion, not feedback, and the student will ask why. Say what would have earned the mark above. Mark what the evidence here supports and nothing more \u{2014} if the material cannot tell you about a line, give it the middle of its range and say that you could not judge it.")
        out.append("")

        if metrics != nil || presence != nil {
            out.append("## The counted numbers")
            out.append("")
            for sentence in metrics?.sentences ?? [] { out.append("- \(sentence)") }
            for sentence in presence?.sentences ?? [] { out.append("- \(sentence)") }
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
                    onStart: ((Process) -> Void)? = nil,
                    onOutput: (@MainActor (String) -> Void)? = nil) async throws -> String {
        let command = settings.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw Failure.noCommand }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = folder
        // The command templates refer to it, and a custom command can too.
        var environment = ProcessInfo.processInfo.environment
        // Referred to by the default commands, and available to a custom one.
        environment["SCREENROOM_FOLDER"] = folder.path
        // The old name, for a command written before the rename.
        environment["MARKS_FOLDER"] = folder.path
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        // Handed out so a stop can reach it. A Task cancellation alone would
        // leave the CLI running, still spending tokens, still holding the
        // folder open.
        onStart?(process)

        // Written and closed before reading: these agents do not begin until
        // stdin is at EOF, so holding it open deadlocks the whole thing.
        input.fileHandleForWriting.write(Data(brief.utf8))
        try? input.fileHandleForWriting.close()

        // Read both pipes concurrently. Draining only one deadlocks the
        // moment the other's buffer fills, which a chatty agent does quickly.
        //
        // stdout is now READ rather than shown: it carries the event stream,
        // which says what the agent is doing, and the answer arrives inside
        // it. The first version streamed it straight to the window, which put
        // the report's own sentences on screen a character at a time.
        async let collected = readStream(output.fileHandleForReading, onOutput: onOutput)
        async let problems = drain(errors.fileHandleForReading, onOutput: nil)

        let reader = await collected
        let errorText = await problems
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.failed(code: process.terminationStatus,
                                 output: errorText.isEmpty ? reader.result : errorText)
        }
        return reader.result
    }

    /// Reads stdout a line at a time, showing what each event means.
    ///
    /// Line-buffered because a pipe hands over arbitrary chunks and half a
    /// JSON object parses as nothing. The activity is de-duplicated: an agent
    /// reading four files in a row would otherwise flicker "Thinking…"
    /// between each, which reads as noise rather than as progress.
    private static func readStream(_ handle: FileHandle,
                                   onOutput: (@MainActor (String) -> Void)?) async -> StreamReader {
        await withCheckedContinuation { (continuation: CheckedContinuation<StreamReader, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var reader = StreamReader()
                var pending = ""
                var lastShown = ""

                func flush(_ line: String) {
                    guard let activity = reader.consume(line), activity != lastShown else { return }
                    lastShown = activity
                    if let onOutput {
                        let turns = reader.turns
                        Task { @MainActor in
                            onOutput(turns > 1 ? "\(activity)  (turn \(turns))\n" : "\(activity)\n")
                        }
                    }
                }

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    pending += String(decoding: chunk, as: UTF8.self)
                    while let newline = pending.firstIndex(of: "\n") {
                        let line = String(pending[pending.startIndex..<newline])
                        pending = String(pending[pending.index(after: newline)...])
                        flush(line + "\n")
                    }
                }
                if !pending.isEmpty { flush(pending) }
                continuation.resume(returning: reader)
            }
        }
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
                let worked = points(object["strengths"])
                let change = points(object["workOn"])
                let headline = (object["headline"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var analysis = ScreenroomAnalysis(
                    engine: engine,
                    summary: summary,
                    strengths: worked.map(\.sentence),
                    workOn: change.map(\.sentence),
                    patterns: strings(object["patterns"]),
                    marks: marks(object["marks"]),
                    consistency: consistency)
                analysis.headline = headline.isEmpty ? nil : headline
                // Only kept as points when the agent wrote points. Plain
                // sentences stay sentences, and the report shows them as it
                // always did rather than as cards with no headline.
                if (worked + change).contains(where: { !$0.headline.isEmpty && !$0.detail.isEmpty }) {
                    analysis.worked = worked
                    analysis.change = change
                }
                return analysis
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

    /// Strengths or things to change, as points. Takes the shape the brief
    /// asks for and the shape older briefs asked for: an object becomes a
    /// point, a bare sentence becomes a point with no headline. The time is
    /// read as leniently as a mark is, because "17", 17.0 and "0:17" all
    /// turn up.
    private static func points(_ value: Any?) -> [ScreenroomAnalysis.Point] {
        (value as? [Any] ?? []).compactMap { entry in
            if let text = entry as? String {
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.count > 2 ? ScreenroomAnalysis.Point(headline: "", detail: text) : nil
            }
            guard let row = entry as? [String: Any] else { return nil }
            let headline = (row["headline"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = (row["detail"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard headline.count + detail.count > 2 else { return nil }
            return ScreenroomAnalysis.Point(headline: headline, detail: detail,
                                            atMs: seconds(row["atSeconds"]).map { $0 * 1_000 })
        }
    }

    private static func seconds(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n >= 0 ? n : nil
        case let d as Double: return d >= 0 ? Int(d.rounded()) : nil
        case let text as String:
            let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !parts.isEmpty else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        default: return nil
        }
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 2 }
    }
}

// MARK: - Reading what the agent is doing

extension ScreenroomAgent {

    /// Turns a CLI's event stream into two things: a line saying what it is
    /// doing, and eventually the answer.
    ///
    /// The agent step is the long one - minutes, while everything before it
    /// takes seconds - and it used to show a spinner and nothing else,
    /// because the only thing on stdout was the answer and showing that
    /// meant showing the report being written a character at a time.
    ///
    /// Both CLIs will emit newline-delimited JSON events if asked, and the
    /// events say exactly what a person wants to know: which file it is
    /// reading, what it is running, how many turns in it is. Their shapes are
    /// completely different, so both are handled by looking for what each
    /// actually emits rather than by a shared abstraction that neither fits.
    ///
    /// A command that emits no JSON at all - somebody's own script - falls
    /// back to treating stdout as the answer, which is what always happened.
    struct StreamReader {
        /// The answer, once an event carried it.
        private(set) var answer: String?
        /// Everything stdout said, for a command that does not stream events.
        private(set) var raw = ""
        /// True once anything parsed, so the fallback knows to stay out.
        private(set) var structured = false
        private(set) var turns = 0

        /// Consumes one line and returns something to show, if there is any.
        mutating func consume(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            // An event is a JSON object with a `type`. Anything else - including
            // a perfectly good JSON object without one - is the ANSWER, and
            // belongs in raw.
            //
            // Requiring the type matters: a custom command that prints the
            // report as plain JSON was being recognised as an event with an
            // unknown type and dropped on the floor, so its output vanished.
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else {
                raw += line
                return nil
            }
            structured = true

            switch type {
            // Claude Code
            case "assistant":
                guard let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]]
                else { return nil }
                for block in content where block["type"] as? String == "tool_use" {
                    return describe(tool: block["name"] as? String ?? "a tool",
                                    input: block["input"] as? [String: Any])
                }
                turns += 1
                return "Thinking\u{2026}"
            case "result":
                answer = event["result"] as? String
                return nil

            // Codex
            case "item.started", "item.completed":
                guard let item = event["item"] as? [String: Any] else { return nil }
                switch item["type"] as? String {
                case "command_execution":
                    let command = (item["command"] as? String) ?? ""
                    return "Running " + String(command.prefix(60))
                case "agent_message":
                    // The last one is the answer; each is also a sign of life.
                    if let text = item["text"] as? String, !text.isEmpty {
                        answer = text
                        return nil
                    }
                    return nil
                default: return nil
                }
            case "turn.started":
                turns += 1
                return "Thinking\u{2026}"
            default:
                return nil
            }
        }

        /// Whatever the answer turned out to be.
        var result: String { answer ?? raw }

        /// "Reading transcript.txt" rather than "Read" - the file is the
        /// interesting half, and it is what tells a watcher the agent has
        /// found the material rather than flailing.
        private func describe(tool: String, input: [String: Any]?) -> String {
            // A PATH is shortened to its last component, because the folder
            // is the same every time and the file name is the news. A PATTERN
            // is not: "frames/*.jpg" shortened the same way becomes "*.jpg",
            // which throws away the only part that says what was being looked
            // for.
            let file = ((input?["file_path"] as? String) ?? (input?["path"] as? String))
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            let pattern = input?["pattern"] as? String

            switch tool {
            case "Read": return file.map { "Reading \($0)" } ?? "Reading the folder"
            case "Glob", "Grep":
                guard let what = pattern ?? file else { return "Looking through the folder" }
                return "Looking for \(what)"
            case "Bash": return "Running a command"
            default: return (file ?? pattern).map { "\(tool): \($0)" } ?? tool
            }
        }
    }
}
