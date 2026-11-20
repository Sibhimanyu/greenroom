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
        XCTAssertEqual(ScreenroomRunRules.cleanup(inFlight: .transcribe, existedBefore: ["transcript.txt", "words.json"]),
                       ["audio-for-transcription.json", "audio-for-transcription.wav", "speech.json"])
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
                     "analysis.json", "session.json", "report.md", "Take.M4A"] {
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
}
