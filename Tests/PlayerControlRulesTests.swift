import XCTest

final class PlayerControlRulesTests: XCTestCase {
    func testSkipClampsToWholeRecording() {
        XCTAssertEqual(PlayerControlRules.skipTarget(from: 4, by: -10, duration: 60), 0)
        XCTAssertEqual(PlayerControlRules.skipTarget(from: 55, by: 10, duration: 60), 60)
        XCTAssertEqual(PlayerControlRules.skipTarget(from: 20, by: 10, duration: 60), 30)
        XCTAssertEqual(PlayerControlRules.skipTarget(from: 20, by: -10, duration: 60), 10)
    }

    func testSkipClampsToTrimmedRange() {
        let range = 5.0...40.0
        XCTAssertEqual(PlayerControlRules.skipTarget(from: 8, by: -10, duration: 60, range: range), 5)
        XCTAssertEqual(PlayerControlRules.skipTarget(from: 35, by: 10, duration: 60, range: range), 40)
        XCTAssertEqual(PlayerControlRules.skipTarget(from: 20, by: 10, duration: 60, range: range), 30)
    }

    func testSkipSurvivesBadNumbers() {
        XCTAssertEqual(PlayerControlRules.skipTarget(from: .nan, by: 10, duration: 60), 10)
        XCTAssertEqual(PlayerControlRules.skipTarget(from: 3, by: 10, duration: 0), 0)
        XCTAssertEqual(PlayerControlRules.skipTarget(from: 3, by: 10, duration: .infinity), 0)
    }

    func testVolumeDefaultsAndClamps() {
        XCTAssertEqual(PlayerControlRules.clampedVolume(nil), 1)
        XCTAssertEqual(PlayerControlRules.clampedVolume(-3), 0)
        XCTAssertEqual(PlayerControlRules.clampedVolume(7), 1)
        XCTAssertEqual(PlayerControlRules.clampedVolume(0.4), 0.4)
        XCTAssertEqual(PlayerControlRules.clampedVolume(.nan), 1)
    }

    func testVolumeSymbols() {
        XCTAssertEqual(PlayerControlRules.volumeSymbol(volume: 1, muted: true), "speaker.slash.fill")
        XCTAssertEqual(PlayerControlRules.volumeSymbol(volume: 0, muted: false), "speaker.slash.fill")
        XCTAssertEqual(PlayerControlRules.volumeSymbol(volume: 0.2, muted: false), "speaker.fill")
        XCTAssertEqual(PlayerControlRules.volumeSymbol(volume: 0.5, muted: false), "speaker.wave.1.fill")
        XCTAssertEqual(PlayerControlRules.volumeSymbol(volume: 0.9, muted: false), "speaker.wave.2.fill")
    }

    func testRaisingVolumeUnmutes() {
        XCTAssertFalse(PlayerControlRules.mutedAfterSetting(volume: 0.3, muted: true))
        XCTAssertTrue(PlayerControlRules.mutedAfterSetting(volume: 0, muted: true))
        XCTAssertFalse(PlayerControlRules.mutedAfterSetting(volume: 0, muted: false))
    }

    func testKeys() {
        let a = PlayerControlRules.action
        XCTAssertEqual(a(49, false, false), .playPause)
        XCTAssertEqual(a(123, false, false), .skipBack)
        XCTAssertEqual(a(124, false, false), .skipForward)
        XCTAssertEqual(a(46, false, false), .toggleMute)
        XCTAssertEqual(a(3, false, false), .toggleFullScreen)
        XCTAssertNil(a(53, false, false))
        XCTAssertEqual(a(53, false, true), .exitFullScreen)
        XCTAssertNil(a(124, true, false))
        XCTAssertNil(a(0, false, false))
    }

    func testAutoHide() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(PlayerControlRules.controlsVisible(now: t0.addingTimeInterval(2.4), lastActivity: t0, holding: false))
        XCTAssertFalse(PlayerControlRules.controlsVisible(now: t0.addingTimeInterval(2.5), lastActivity: t0, holding: false))
        XCTAssertTrue(PlayerControlRules.controlsVisible(now: t0.addingTimeInterval(30), lastActivity: t0, holding: true))
    }
}
