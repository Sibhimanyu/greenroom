//
//  ScreenroomRunRules.swift
//  Greenroom
//
//  The pure parts of an analysis run: which steps it has, how far through it
//  is, what a Stop may delete, and how long a child process may take. No UI
//  and no I/O, so each is pinned by a test (Tests/ScreenroomRunRulesTests).
//
import Foundation

/// One step of the run, as the person sees it.
struct ScreenroomRunStep: Equatable, Identifiable {
    enum Kind: String {
        case transcribe, stills, watch, cohort, write
    }

    let kind: Kind
    var title: String
    /// True when the step can say "40 per cent". Whisper, stills and the
    /// camera pass can; Apple's recogniser and an agent cannot, and a bar
    /// pinned at zero for two minutes reads as a hang.
    var reportsFraction: Bool

    var id: String { kind.rawValue }
}

enum ScreenroomRunRules {

    // MARK: The steps

    /// The steps a run over this meeting has, in order. A notes-only folder
    /// has no recording, so it skips the first three.
    static func steps(hasRecording: Bool, whisper: Bool, agent: Bool) -> [ScreenroomRunStep] {
        var out: [ScreenroomRunStep] = []
        if hasRecording {
            out.append(.init(kind: .transcribe,
                             title: whisper ? "Transcribing with whisper" : "Transcribing",
                             reportsFraction: whisper))
            out.append(.init(kind: .stills, title: "Taking stills", reportsFraction: true))
            out.append(.init(kind: .watch, title: "Watching the recording", reportsFraction: true))
        }
        out.append(.init(kind: .cohort, title: "Comparing against the group", reportsFraction: true))
        out.append(writeStep(agent: agent))
        return out
    }

    /// The last step: the agent when one is set up, otherwise the notes pass.
    static func writeStep(agent: Bool) -> ScreenroomRunStep {
        .init(kind: .write,
              title: agent ? "Your agent is reading it" : "Reading the notes",
              reportsFraction: false)
    }

    // MARK: How far

    /// The whole run as 0...1: finished steps plus the running step's own
    /// fraction (zero when it cannot report one). `stepIndex` counts from 1;
    /// 0 means nothing has begun.
    static func overall(stepIndex: Int, stepCount: Int, stepFraction: Double?) -> Double {
        guard stepCount > 0, stepIndex > 0 else { return 0 }
        let done = Double(min(stepIndex, stepCount) - 1)
        let inStep = min(max(stepFraction ?? 0, 0), 1)
        return min(1, (done + inStep) / Double(stepCount))
    }

    /// "Step 2 of 5", or nil before the first step begins.
    static func stepLine(index: Int, count: Int) -> String? {
        guard count > 0, index > 0 else { return nil }
        return "Step \(min(index, count)) of \(count)"
    }

    /// "42%", for a step that reports a fraction.
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    enum RowState: Equatable { case done, running, waiting }

    /// The state of the row at `row` (counted from 0) while step `stepIndex`
    /// (counted from 1) runs.
    static func rowState(row: Int, stepIndex: Int) -> RowState {
        if row + 1 < stepIndex { return .done }
        if row + 1 == stepIndex { return .running }
        return .waiting
    }

    // MARK: Stop

    /// Names in a meeting's folder that Stop must never remove, whatever else
    /// it decides: the recording itself, the notes and marks, and the result
    /// of an earlier run.
    static func isProtected(_ name: String) -> Bool {
        let lower = name.lowercased()
        let media = ["mp4", "mov", "m4a", "wav", "m4v", "mp3"]
        if let dot = lower.lastIndex(of: "."), media.contains(String(lower[lower.index(after: dot)...])),
           lower != "audio-for-transcription.wav" {
            return true
        }
        return ["notes.jsonl", "rubric.json", "analysis.json", "session.json", "report.md"].contains(lower)
    }

    /// What a Stop removes: files the running step writes, only when this run
    /// created them (they were not in the folder before it began). Steps that
    /// already finished keep their files, and the earlier run's files are left
    /// alone. A finished step is never undone.
    static func cleanup(inFlight kind: ScreenroomRunStep.Kind?, existedBefore: Set<String>) -> [String] {
        let candidates: [String]
        switch kind {
        case .transcribe:
            candidates = ["audio-for-transcription.wav", "audio-for-transcription.json",
                          "transcript.txt", "words.json", "speech.json"]
        case .stills:
            // Stills are cut into a scratch folder and swapped in at the end,
            // so a stop leaves the earlier stills untouched.
            candidates = ["frames.partial"]
        case .watch:
            candidates = ["presence.json"]
        case .write:
            candidates = ["BRIEF.md", "agent-report.md"]
        case .cohort, .none:
            candidates = []
        }
        return candidates
            .filter { !isProtected($0) }
            .filter { name in
                // Scratch names are always this run's; the rest only if new.
                name == "audio-for-transcription.wav" || name == "audio-for-transcription.json"
                    || name == "frames.partial" || !existedBefore.contains(name)
            }
            .sorted()
    }

    // MARK: Time limits

    /// An agent that has said nothing for this long is hung, not thinking.
    /// The 26-second clip took about half a minute, so a quarter of an hour
    /// is generous for a long meeting.
    static let agentTimeout: TimeInterval = 15 * 60

    /// whisper runs faster than real time on a recent Mac; twice the
    /// recording plus two minutes for loading the model, never under five
    /// minutes.
    static func whisperTimeout(recordingSeconds: TimeInterval) -> TimeInterval {
        max(5 * 60, recordingSeconds * 2 + 120)
    }

    static func isOverdue(elapsed: TimeInterval, limit: TimeInterval) -> Bool {
        limit > 0 && elapsed >= limit
    }

    /// "a quarter of an hour" is for code comments; the person reads "15 min".
    static func limitLabel(_ limit: TimeInterval) -> String {
        "\(max(1, Int((limit / 60).rounded()))) min"
    }
}
