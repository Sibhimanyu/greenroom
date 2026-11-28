//
//  MuteHintRulesTests.swift
//  GreenroomTests
//
//  Zoom's Mute silences the meeting only; a take that is rolling still records the microphone.
//  The Mute control says so, on the bar and in the Meeting window's toolbar.
//
import XCTest

final class MuteHintRulesTests: XCTestCase {
    private typealias R = MuteHintRules

    private func hears(muted: Bool = true, inMeeting: Bool = true, hasAudio: Bool = true,
                       recording: Bool = true, paused: Bool = false, saving: Bool = false) -> Bool {
        R.recordingHearsYou(muted: muted, inMeeting: inMeeting, hasAudio: hasAudio,
                            recording: recording, paused: paused, saving: saving)
    }

    func testMutedWhileRollingHears() {
        XCTAssertTrue(hears())
    }

    func testNotMutedNeverShows() {
        XCTAssertFalse(hears(muted: false))
    }

    func testNoTakeNoHint() {
        XCTAssertFalse(hears(recording: false))
    }

    func testPausedAndSavingAreNotRolling() {
        XCTAssertFalse(hears(paused: true))
        XCTAssertFalse(hears(saving: true))
    }

    func testOutsideMeetingOrWithoutAudioNoHint() {
        XCTAssertFalse(hears(inMeeting: false))
        XCTAssertFalse(hears(hasAudio: false))
    }

    func testWords() {
        XCTAssertEqual(R.hint, "Muted for the meeting. The recording still hears you.")
        XCTAssertEqual(R.tooltip(hearsYou: true, plain: "Unmute: everyone hears you again"), R.hint)
        XCTAssertEqual(R.tooltip(hearsYou: false, plain: "Mute your microphone"), "Mute your microphone")
        XCTAssertEqual(R.spokenValue(hearsYou: true), R.hint)
        XCTAssertNil(R.spokenValue(hearsYou: false))
    }
}
