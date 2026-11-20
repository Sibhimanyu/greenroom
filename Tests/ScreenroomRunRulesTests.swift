import XCTest

final class ScreenroomRunRulesTests: XCTestCase {

    func testStepsWithRecordingAndAgent() {
        let steps = ScreenroomRunRules.steps(hasRecording: true, whisper: true, agent: true)
        XCTAssertEqual(steps.map(\.kind), [.transcribe, .stills, .watch, .cohort, .write])
        XCTAssertEqual(steps.first?.title, "Transcribing with whisper")
        XCTAssertEqual(steps.last?.title, "Your agent is reading it")
        XCTAssertEqual(steps.map(\.reportsFraction), [true, true, true, true, false])
    }

    func testAppleTranscriptionCannotReportAFraction() {
        let steps = ScreenroomRunRules.steps(hasRecording: true, whisper: false, agent: false)
        XCTAssertEqual(steps.first?.title, "Transcribing")
        XCTAssertEqual(steps.first?.reportsFraction, false)
        XCTAssertEqual(steps.last?.title, "Reading the notes")
    }

    func testNotesOnlyFolderSkipsTheRecordingSteps() {
        let steps = ScreenroomRunRules.steps(hasRecording: false, whisper: true, agent: false)
        XCTAssertEqual(steps.map(\.kind), [.cohort, .write])
    }

    func testOverallFraction() {
        XCTAssertEqual(ScreenroomRunRules.overall(stepIndex: 0, stepCount: 5, stepFraction: 0.5), 0)
        XCTAssertEqual(ScreenroomRunRules.overall(stepIndex: 1, stepCount: 5, stepFraction: nil), 0)
        XCTAssertEqual(ScreenroomRunRules.overall(stepIndex: 1, stepCount: 4, stepFraction: 0.5), 0.125, accuracy: 1e-9)
        XCTAssertEqual(ScreenroomRunRules.overall(stepIndex: 3, stepCount: 4, stepFraction: nil), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ScreenroomRunRules.overall(stepIndex: 4, stepCount: 4, stepFraction: 9), 1, accuracy: 1e-9)
        XCTAssertEqual(ScreenroomRunRules.overall(stepIndex: 9, stepCount: 4, stepFraction: -1), 0.75, accuracy: 1e-9)
        XCTAssertEqual(ScreenroomRunRules.overall(stepIndex: 2, stepCount: 0, stepFraction: 0.5), 0)
    }

    func testStepLineAndPercent() {
        XCTAssertNil(ScreenroomRunRules.stepLine(index: 0, count: 5))
        XCTAssertEqual(ScreenroomRunRules.stepLine(index: 2, count: 5), "Step 2 of 5")
        XCTAssertEqual(ScreenroomRunRules.stepLine(index: 7, count: 5), "Step 5 of 5")
        XCTAssertEqual(ScreenroomRunRules.percent(0.426), "43%")
        XCTAssertEqual(ScreenroomRunRules.percent(3), "100%")
    }

    func testRowStates() {
        XCTAssertEqual(ScreenroomRunRules.rowState(row: 0, stepIndex: 2), .done)
        XCTAssertEqual(ScreenroomRunRules.rowState(row: 1, stepIndex: 2), .running)
        XCTAssertEqual(ScreenroomRunRules.rowState(row: 2, stepIndex: 2), .waiting)
        XCTAssertEqual(ScreenroomRunRules.rowState(row: 0, stepIndex: 0), .waiting)
    }

    func testCleanupTakesOnlyThisRunsFilesFromTheRunningStep() {
        XCTAssertEqual(ScreenroomRunRules.cleanup(inFlight: .write, existedBefore: []),
                       ["BRIEF.md", "agent-report.md"])
        // An earlier run's brief stays.
        XCTAssertEqual(ScreenroomRunRules.cleanup(inFlight: .write, existedBefore: ["BRIEF.md"]),
                       ["agent-report.md"])
        XCTAssertEqual(ScreenroomRunRules.cleanup(inFlight: .stills, existedBefore: ["frames"]),
                       ["frames.partial"])
        XCTAssertEqual(ScreenroomRunRules.cleanup(inFlight: .transcribe, existedBefore: ["analysis-transcript.txt", "words.json"]),
                       ["audio-for-transcription.json", "audio-for-transcription.wav", "speech.json"])
        // Cues' transcript is never on the list, even when it is new.
        XCTAssertFalse(ScreenroomRunRules.cleanup(inFlight: .transcribe, existedBefore: []).contains("transcript.txt"))
        XCTAssertTrue(ScreenroomRunRules.cleanup(inFlight: .transcribe, existedBefore: []).contains("analysis-transcript.txt"))
        XCTAssertTrue(ScreenroomRunRules.cleanup(inFlight: .cohort, existedBefore: []).isEmpty)
        XCTAssertTrue(ScreenroomRunRules.cleanup(inFlight: nil, existedBefore: []).isEmpty)
    }

    func testCleanupNeverNamesTheRecordingOrTheNotes() {
        let kinds: [ScreenroomRunStep.Kind?] = [.transcribe, .stills, .watch, .cohort, .write, nil]
        for kind in kinds {
            for name in ScreenroomRunRules.cleanup(inFlight: kind, existedBefore: []) {
                XCTAssertFalse(ScreenroomRunRules.isProtected(name), name)
                XCTAssertNotEqual(name, "notes.jsonl")
                XCTAssertNotEqual(name, "rubric.json")
                XCTAssertFalse(name.hasSuffix(".mp4") || name.hasSuffix(".mov"), name)
            }
        }
    }

    func testProtectedNames() {
        for name in ["2026-11-20 14-06-41.mp4", "presentation.mov", "notes.jsonl", "rubric.json",
                     "analysis.json", "session.json", "report.md", "Take.M4A", "transcript.txt", "cues.txt"] {
            XCTAssertTrue(ScreenroomRunRules.isProtected(name), name)
        }
        XCTAssertFalse(ScreenroomRunRules.isProtected("BRIEF.md"))
        XCTAssertFalse(ScreenroomRunRules.isProtected("audio-for-transcription.wav"))
    }

    func testTimeLimits() {
        XCTAssertEqual(ScreenroomRunRules.whisperTimeout(recordingSeconds: 26), 300)
        XCTAssertEqual(ScreenroomRunRules.whisperTimeout(recordingSeconds: 3_600), 7_320)
        XCTAssertFalse(ScreenroomRunRules.isOverdue(elapsed: 899, limit: ScreenroomRunRules.agentTimeout))
        XCTAssertTrue(ScreenroomRunRules.isOverdue(elapsed: 900, limit: ScreenroomRunRules.agentTimeout))
        XCTAssertFalse(ScreenroomRunRules.isOverdue(elapsed: 10, limit: 0))
        XCTAssertEqual(ScreenroomRunRules.limitLabel(900), "15 min")
    }

    func testTranscriptFormats() {
        XCTAssertTrue(ScreenroomTranscriptFile.isAnalyseFormat("[0:07] hello there\n"))
        XCTAssertFalse(ScreenroomTranscriptFile.isAnalyseFormat("# Cues\n0:00:07\thello there\n"))
        XCTAssertFalse(ScreenroomTranscriptFile.isAnalyseFormat(""))
    }

    func testTranscriptFileFallbackAndPrecedence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("transcript.txt")
        try "[0:01] old analysed\n".write(to: old, atomically: true, encoding: .utf8)
        XCTAssertEqual(ScreenroomTranscriptFile.url(in: dir)?.lastPathComponent, "transcript.txt")
        // Cues' tab format is not Analyse's: no fallback, but the tab shows it.
        try "0:00:01\tcues line\n".write(to: old, atomically: true, encoding: .utf8)
        XCTAssertNil(ScreenroomTranscriptFile.url(in: dir))
        XCTAssertEqual(ScreenroomTranscriptFile.displayURL(in: dir)?.lastPathComponent, "transcript.txt")
        let new = dir.appendingPathComponent("analysis-transcript.txt")
        try "[0:01] new\n".write(to: new, atomically: true, encoding: .utf8)
        XCTAssertEqual(ScreenroomTranscriptFile.url(in: dir)?.lastPathComponent, "analysis-transcript.txt")
        XCTAssertEqual(ScreenroomTranscriptFile.displayURL(in: dir)?.lastPathComponent, "transcript.txt")
        try FileManager.default.removeItem(at: old)
        XCTAssertEqual(ScreenroomTranscriptFile.displayURL(in: dir)?.lastPathComponent, "analysis-transcript.txt")
    }

    func testTranscribeOnlyIsJustTheTranscriptionStep() {
        let whisper = ScreenroomRunRules.transcribeOnlySteps(whisper: true)
        XCTAssertEqual(whisper.map(\.kind), [.transcribe])
        XCTAssertEqual(whisper.first?.title, "Transcribing with whisper")
        XCTAssertEqual(whisper.first?.reportsFraction, true)
        let apple = ScreenroomRunRules.transcribeOnlySteps(whisper: false)
        XCTAssertEqual(apple.first?.title, "Transcribing")
        XCTAssertEqual(apple.first?.reportsFraction, false)
    }

    func testReusedTranscriptDropsOnlyTheTranscribeStep() {
        let full = ScreenroomRunRules.steps(hasRecording: true, whisper: true, agent: false)
        let reused = ScreenroomRunRules.steps(hasRecording: true, whisper: true, agent: false,
                                              reuseTranscript: true)
        XCTAssertEqual(full.map(\.kind), [.transcribe, .stills, .watch, .cohort, .write])
        XCTAssertEqual(reused.map(\.kind), [.stills, .watch, .cohort, .write])
    }

    func testTranscriptIsReusedOnlyWhenAllThreeOutputsExist() {
        XCTAssertTrue(ScreenroomRunRules.canReuseTranscript(
            existing: ["analysis-transcript.txt", "words.json", "speech.json", "notes.jsonl"]))
        XCTAssertFalse(ScreenroomRunRules.canReuseTranscript(existing: ["analysis-transcript.txt", "words.json"]))
        XCTAssertFalse(ScreenroomRunRules.canReuseTranscript(existing: ["transcript.txt", "words.json", "speech.json"]))
        XCTAssertFalse(ScreenroomRunRules.canReuseTranscript(existing: []))
    }

    func testRunTitleSaysGettingFeedbackTranscribingOrStopping() {
        XCTAssertEqual(ScreenroomRunRules.runTitle(transcribeOnly: false, stopping: false), "Getting feedback")
        XCTAssertEqual(ScreenroomRunRules.runTitle(transcribeOnly: true, stopping: false), "Transcribing")
        XCTAssertEqual(ScreenroomRunRules.runTitle(transcribeOnly: true, stopping: true), "Stopping")
        XCTAssertEqual(ScreenroomRunRules.runTitle(transcribeOnly: false, stopping: true), "Stopping")
    }

    func testStopDuringTranscribeOnlyRemovesOnlyNewTranscriptFiles() {
        let removed = ScreenroomRunRules.cleanup(inFlight: .transcribe, existedBefore: ["words.json"])
        XCTAssertFalse(removed.contains("words.json"))
        XCTAssertTrue(removed.contains("analysis-transcript.txt"))
        XCTAssertFalse(removed.contains("analysis.json"))
    }

    // MARK: Ready popover

    func testPlanMarksExistingTranscriptReused() {
        let existing = Set(ScreenroomRunRules.transcriptOutputs)
        let rows = ScreenroomRunRules.plan(transcribeOnly: false, hasRecording: true, whisper: true,
                                           agent: true, existing: existing)
        XCTAssertEqual(rows.map(\.step.kind), [.transcribe, .stills, .watch, .cohort, .write])
        XCTAssertEqual(rows.map(\.reused), [true, false, false, false, false])
    }

    func testPlanWithoutTranscriptReusesNothing() {
        let partial: Set<String> = [ScreenroomTranscriptFile.name]
        let rows = ScreenroomRunRules.plan(transcribeOnly: false, hasRecording: true, whisper: false,
                                           agent: false, existing: partial)
        XCTAssertTrue(rows.allSatisfy { !$0.reused })
        XCTAssertEqual(rows.count, 5)
    }

    func testPlanTranscribeOnlyIsOneStepNeverReused() {
        let rows = ScreenroomRunRules.plan(transcribeOnly: true, hasRecording: true, whisper: true,
                                           agent: true, existing: Set(ScreenroomRunRules.transcriptOutputs))
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].reused)
    }

    func testPlanNotesOnlyFolderHasNoTranscribeRow() {
        let rows = ScreenroomRunRules.plan(transcribeOnly: false, hasRecording: false, whisper: true,
                                           agent: true, existing: Set(ScreenroomRunRules.transcriptOutputs))
        XCTAssertEqual(rows.map(\.step.kind), [.cohort, .write])
    }

    func testPopoverStateAndInlineChoices() {
        XCTAssertEqual(ScreenroomRunRules.popoverState(isAnalysing: false), .ready)
        XCTAssertEqual(ScreenroomRunRules.popoverState(isAnalysing: true), .running)
        XCTAssertTrue(ScreenroomRunRules.showsChoicesInline(setupSeen: false))
        XCTAssertFalse(ScreenroomRunRules.showsChoicesInline(setupSeen: true))
    }

    func testChoiceSummaries() {
        XCTAssertEqual(ScreenroomRunRules.writerSummary(agentOn: true, command: "claude -p", agentName: "Claude Code"), "Claude Code")
        XCTAssertEqual(ScreenroomRunRules.writerSummary(agentOn: true, command: "  ", agentName: "Codex"), "This Mac")
        XCTAssertEqual(ScreenroomRunRules.writerSummary(agentOn: false, command: "x", agentName: "Codex"), "This Mac")
        XCTAssertEqual(ScreenroomRunRules.transcriberSummary(whisper: false, modelName: "base"), "Apple Speech")
        XCTAssertEqual(ScreenroomRunRules.transcriberSummary(whisper: true, modelName: "ggml-base.en"), "Whisper \u{00B7} ggml-base.en")
        XCTAssertEqual(ScreenroomRunRules.transcriberSummary(whisper: true, modelName: nil), "Whisper")
    }
}
