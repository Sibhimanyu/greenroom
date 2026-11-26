//
//  StartFailureTests.swift
//  GreenroomTests
//
//  A start that does not reach a live meeting (2026-11-26, the first Start on
//  another person's Mac): the island must never say it worked, the failure is
//  shown in words with Try again, and everything the start opened goes away,
//  the Meeting window on a second display included.
//
import XCTest

final class StartFailureTests: XCTestCase {

    // MARK: The island tells the truth

    /// The meeting start's six steps, as the coordinator lays them out, with
    /// `upTo` settled and the next one active.
    private func steps(settled upTo: Int) -> [NotchStep] {
        let labels = ["Workspace", "Picture", "Creating meeting", "Meeting", "Recording", "Tiling windows"]
        return labels.enumerated().map { i, label in
            NotchStep(label: label, state: i < upTo ? (i == 0 || i >= 4 ? .skipped : .done) : (i == upTo ? .active : .pending))
        }
    }

    private func run(_ readings: [NotchInput]) -> [NotchPhase] {
        var phase = NotchPhase.hidden
        var seen: [NotchPhase] = []
        for input in readings {
            phase = NotchStatusRules.next(from: phase, input: input)
            seen.append(phase)
        }
        return seen
    }

    private func isLive(_ phase: NotchPhase) -> Bool { if case .live = phase { return true } else { return false } }

    func testStepsThatClearWithoutZoomSayingInMeetingNeverShowLive() {
        // Every step settled, then the reading cleared, but nobody confirmed the meeting.
        let seen = run([NotchInput(steps: steps(settled: 6)), NotchInput()])
        XCTAssertFalse(seen.contains(where: isLive), "the island claimed Live for a meeting nobody confirmed")
        XCTAssertEqual(seen.last, .hidden)
    }

    func testLiveOnlyWithTheConfirmation() {
        let seen = run([NotchInput(steps: steps(settled: 6)), NotchInput(liveConfirmed: true)])
        XCTAssertEqual(seen.last, .live(recording: false))
    }

    private func assertFailsInRed(atStep failing: Int, _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
        var failedSteps = steps(settled: failing)
        failedSteps[failing].state = .failed
        let seen = run([NotchInput(steps: steps(settled: failing)), NotchInput(steps: failedSteps, failure: reason)])
        XCTAssertFalse(seen.contains(where: isLive), file: file, line: line)
        XCTAssertEqual(seen.last, .failed(NotchFailure(message: reason)), file: file, line: line)
        // The pacer passes a failure straight through, whatever it was showing.
        var pacer = StepPacer()
        pacer.feed(.working(NotchProgress(steps: steps(settled: 6))), at: 0)
        XCTAssertEqual(pacer.feed(.failed(NotchFailure(message: reason)), at: 0.1), .failed(NotchFailure(message: reason)),
                       file: file, line: line)
    }

    func testSignInMissingFailsOnTheIslandBeforeAnyStep() {
        // Refused before any step runs: a failure with no steps still shows, with Try again.
        let seen = run([NotchInput(failure: "Sign in with Zoom in Settings")])
        XCTAssertEqual(seen.last, .failed(NotchFailure(message: "Sign in with Zoom in Settings")))
    }

    func testSDKAuthFailedShowsTheMeetingStepInRed() {
        assertFailsInRed(atStep: 3, "Signing Greenroom\u{2019}s meeting client in to Zoom took longer than 30 seconds")
    }

    func testScreenRecordingMissingFailsThePictureStep() {
        let reason = StartChoreography.screenRecordingFailure(wantsScreen: true, screenRecordingGranted: false)
        XCTAssertNotNil(reason, "a start that cannot share the screen must not report its Picture step done")
        XCTAssertTrue(reason?.contains("Screen Recording") ?? false)
        XCTAssertTrue(reason?.contains("quit and reopen") ?? false, "macOS only applies the grant after a relaunch")
        XCTAssertNil(StartChoreography.screenRecordingFailure(wantsScreen: true, screenRecordingGranted: true))
        XCTAssertNil(StartChoreography.screenRecordingFailure(wantsScreen: false, screenRecordingGranted: false),
                     "a camera-only share needs no Screen Recording")
        assertFailsInRed(atStep: 1, reason ?? "")
    }

    func testNoFrameAtAllFailsThePictureStep() {
        let reason = StartChoreography.pictureFailure(gotFrame: false, waitedSeconds: 8)
        XCTAssertNotNil(reason, "the Picture step is done only once a frame exists")
        XCTAssertTrue(reason?.contains("8 seconds") ?? false)
        XCTAssertNil(StartChoreography.pictureFailure(gotFrame: true, waitedSeconds: 8))
    }

    func testJoinTimedOutShowsTheMeetingStepInRed() {
        assertFailsInRed(atStep: 3, "Getting into the meeting took longer than 45 seconds")
    }

    func testACancelledStartFoldsWithoutLive() {
        let seen = run([NotchInput(steps: steps(settled: 3), cancellable: true), NotchInput()])
        XCTAssertEqual(seen.last, .hidden)
        XCTAssertEqual(StartChoreography.islandEnd(.cancelled), .fold)
    }

    func testAMeetingZoomEndedAsTheStartFinishedIsAFailureNotLive() {
        XCTAssertEqual(StartChoreography.islandEnd(.live(inMeeting: false)),
                       .failed(StartChoreography.meetingEndedWhileStarting))
        XCTAssertEqual(StartChoreography.islandEnd(.live(inMeeting: true)), .live)
    }

    func testZoomEndingTheMeetingDuringAStartIsTheStartsFailure() {
        XCTAssertEqual(StartChoreography.meetingEnded(startInFlight: true), .startReportsIt)
        XCTAssertEqual(StartChoreography.meetingEnded(startInFlight: false), .endSession)
    }

    // MARK: The island carries every failure

    func testTheIslandCarriesAFailureEvenWithTheMeetingWindowOpen() {
        // Raj San Mode with a second display: the Meeting window was up. It has no readiness card
        // (removed 2026-11-24), so a failure the island drops is shown nowhere.
        XCTAssertTrue(StartChoreography.islandCarriesReading(failed: true, arranged: true,
                                                             layoutHasMeetingDisplay: true, meetingWindowOpen: true))
        XCTAssertTrue(StartChoreography.islandCarriesReading(failed: true, arranged: false,
                                                             layoutHasMeetingDisplay: false, meetingWindowOpen: true))
    }

    func testTheIslandCarriesTheStepsWhateverTheLayout() {
        for arranged in [true, false] {
            for display in [true, false] {
                for open in [true, false] {
                    XCTAssertTrue(StartChoreography.islandCarriesReading(failed: false, arranged: arranged,
                                                                         layoutHasMeetingDisplay: display, meetingWindowOpen: open),
                                  "arranged \(arranged), display \(display), open \(open)")
                }
            }
        }
    }

    // MARK: A failed start takes down what it opened

    func testAFailedStartClosesTheMeetingWindowAndItsLoopButKeepsTheFailure() {
        let t = StartChoreography.teardown(.failed("Zoom said no"))
        XCTAssertTrue(t.closesMeetingWindow, "the Meeting window stayed up on the second display")
        XCTAssertTrue(t.stopsFollowLoop, "the follow loop would reopen the Meeting window")
        XCTAssertTrue(t.keepsIslandFailure)
    }

    func testACancelledStartClosesEverythingAndFolds() {
        XCTAssertEqual(StartChoreography.teardown(.cancelled),
                       .init(closesMeetingWindow: true, stopsFollowLoop: true, keepsIslandFailure: false))
    }

    func testTheMeetingWindowNeverOpensBeforeTheMeetingIsLive() {
        // StartChoreography.surfaces(.starting): the island alone.
        XCTAssertFalse(StartChoreography.opensMeetingWindowWhileStarting(layoutFillsADisplay: true))
        XCTAssertFalse(StartChoreography.opensMeetingWindowWhileStarting(layoutFillsADisplay: false))
    }
}
