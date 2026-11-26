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
    private func run(_ readings: [NotchInput]) -> [NotchPhase] {
        var phase = NotchPhase.hidden
        var seen: [NotchPhase] = []
        for input in readings {
            phase = NotchStatusRules.next(from: phase, input: input)
            seen.append(phase)
        }
        return seen
    }

    func testSignInMissingFailsOnTheIslandBeforeAnyStep() {
        // Refused before any step runs: a failure with no steps still shows, with Try again.
        let seen = run([NotchInput(failure: "Sign in with Zoom in Settings")])
        XCTAssertEqual(seen.last, .failed(NotchFailure(message: "Sign in with Zoom in Settings")))
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
