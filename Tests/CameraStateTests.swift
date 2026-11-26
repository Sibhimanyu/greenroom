import XCTest

final class CameraStateTests: XCTestCase {
    // MARK: mapping, both ways

    func testTheTwoOldSettingsMapOntoAState() {
        XCTAssertEqual(CameraState(noCamera: false, shownOnMyScreen: true), .everyoneAndMe)
        XCTAssertEqual(CameraState(noCamera: false, shownOnMyScreen: false), .onlyEveryone)
        XCTAssertEqual(CameraState(noCamera: true, shownOnMyScreen: true), .onlyMe)
        XCTAssertEqual(CameraState(noCamera: true, shownOnMyScreen: false), .off)
    }

    func testEachStateMapsBackOntoTheTwoOldSettings() {
        for s in CameraState.allCases {
            XCTAssertEqual(CameraState(noCamera: s.noCamera, shownOnMyScreen: s.shownOnMyScreen), s)
        }
        XCTAssertFalse(CameraState.everyoneAndMe.noCamera)
        XCTAssertTrue(CameraState.everyoneAndMe.shownOnMyScreen)
        XCTAssertFalse(CameraState.onlyEveryone.noCamera)
        XCTAssertFalse(CameraState.onlyEveryone.shownOnMyScreen)
        XCTAssertTrue(CameraState.onlyMe.noCamera)
        XCTAssertTrue(CameraState.onlyMe.shownOnMyScreen)
        XCTAssertTrue(CameraState.off.noCamera)
        XCTAssertFalse(CameraState.off.shownOnMyScreen)
    }

    func testOldDefaultsMigrateAndMissingKeysKeepTodaysBehaviour() {
        XCTAssertEqual(CameraState.migrated(noCamera: nil, shownOnMyScreen: nil), .everyoneAndMe)
        XCTAssertEqual(CameraState.migrated(noCamera: true, shownOnMyScreen: nil), .onlyMe)
        XCTAssertEqual(CameraState.migrated(noCamera: nil, shownOnMyScreen: false), .onlyEveryone)
        XCTAssertEqual(CameraState.migrated(noCamera: true, shownOnMyScreen: false), .off)
    }

    func testRawValuesRoundTripAndUnknownIsNil() {
        for s in CameraState.allCases { XCTAssertEqual(CameraState(raw: s.raw), s) }
        XCTAssertEqual(CameraState.everyoneAndMe.raw, "everyoneAndMe")
        XCTAssertNil(CameraState(raw: "nope"))
    }

    func testNamesAreTheFourWordsEverywhere() {
        XCTAssertEqual(CameraState.allCases.map(\.name), ["Everyone & me", "Only the meeting", "Only me", "Off"])
    }

    // R6, R17 (owner, 2026-11-26): each state has its own canvas caption and icon; Off is the only dimmed one.
    // Off's old line ("nothing shows on your screen") read as if the meeting got nothing. Each line
    // now says what the meeting gets; the screen is still shared in Off and Only me, which is what
    // keeps them apart from Stop video, where nothing is sent at all.
    func testEachDetailSaysPlainlyWhatTheMeetingGets() {
        XCTAssertEqual(CameraState.off.detail, "The meeting gets your screen without your camera.")
        for s in CameraState.allCases {
            XCTAssertTrue(s.detail.hasPrefix("The meeting gets your screen"), s.name)
            XCTAssertEqual(s.detail.contains("without your camera"), !s.everyoneSees, s.name)
            XCTAssertFalse(s.detail.lowercased().contains("class"), s.name)
            XCTAssertFalse(s.detail.contains("Nothing is sent"), "kept apart from Stop video, \(s.name)")
            XCTAssertNotEqual(s.detail, StopVideoRules.stopNote, s.name)
            XCTAssertLessThanOrEqual(s.detail.count, 90, "short, \(s.name)")
        }
        XCTAssertTrue(CameraState.onlyMe.detail.contains("mirror"), "Only me still says where the camera shows")
        XCTAssertTrue(StopVideoRules.stopNote.contains("not even your screen"))
        // The menu rows read the one source.
        let menu = MeetingBarModel.cameraStateMenu(current: .off, noCameraAllowed: true) { _ in }
        XCTAssertEqual(menu.compactMap(\.note), CameraState.allCases.map(\.detail))
    }

    func testEachStateHasItsOwnCanvasCaptionAndIcon() {
        let c = CameraState.allCases.map { CameraCaptionRules.caption(for: $0) }
        XCTAssertEqual(c.map(\.text), ["Your camera", "Hidden on your screen", "Only you see this", "Camera off"])
        XCTAssertEqual(c.map(\.symbol), CameraState.allCases.map { VisibilitySymbol.camera($0) }, "icons come from VisibilitySymbols")
        XCTAssertEqual(c.map(\.symbol.name), ["video.fill", "video.fill", "video.fill", "video.slash"])
        XCTAssertEqual(c.map(\.dashed), [false, true, false, false], "only Only the meeting is dashed")
        XCTAssertEqual(c.map(\.dimmed), [false, false, false, true], "only Off dims the whole piece")
        XCTAssertEqual(Set(c.map(\.text)).count, 4, "no two states share words")
        XCTAssertEqual(CameraCaptionRules.caption(for: .onlyMe).symbol.badge, "eye.slash")
    }

    // MARK: saved default vs the running meeting

    func testALiveChangeNeverTouchesTheSavedDefault() {
        var s = CameraStateSession(saved: .everyoneAndMe)
        s.setLive(.onlyMe)
        XCTAssertEqual(s.current, .onlyMe)
        XCTAssertEqual(s.saved, .everyoneAndMe)
        s.setLive(.off)
        XCTAssertEqual(s.saved, .everyoneAndMe)
    }

    func testStartAndSnapBackReturnToTheDefault() {
        var s = CameraStateSession(saved: .onlyEveryone)
        s.setLive(.off)
        s.resetToDefault()
        XCTAssertEqual(s.current, .onlyEveryone)
        XCTAssertNil(s.live)
    }

    func testChangingTheDefaultWhileNothingIsLiveMovesTheCurrentState() {
        var s = CameraStateSession(saved: .everyoneAndMe)
        s.setSaved(.off)
        XCTAssertEqual(s.current, .off)
    }

    func testChangingTheDefaultDoesNotDisturbALiveChange() {
        var s = CameraStateSession(saved: .everyoneAndMe)
        s.setLive(.onlyMe)
        s.setSaved(.off)
        XCTAssertEqual(s.current, .onlyMe)
        XCTAssertEqual(s.saved, .off)
    }

    func testTheBubbleStartsHiddenUnlessTheStateShowsItToYou() {
        XCTAssertFalse(PresenceVisibility.bubbleStartsHidden(state: .everyoneAndMe))
        XCTAssertTrue(PresenceVisibility.bubbleStartsHidden(state: .onlyEveryone))
        XCTAssertFalse(PresenceVisibility.bubbleStartsHidden(state: .onlyMe))
        XCTAssertTrue(PresenceVisibility.bubbleStartsHidden(state: .off))
    }

    func testBadgesReadTheState() {
        for s in CameraState.allCases {
            XCTAssertEqual(Visibility.cameraEveryoneSees(state: s, target: .wholeScreen).isOn, s.everyoneSees)
            XCTAssertEqual(Visibility.cameraEveryoneSees(state: s, target: .window(bundleID: nil)).isOn, s.everyoneSees)
            XCTAssertEqual(Visibility.cameraOnMyScreen(state: s).isOn, s.iSee)
        }
    }
}

// MARK: - The camera button's memory lives with the live state (R6.6, R6.3)

extension CameraStateTests {
    // R6.6: a click turns the camera off for everyone; the next brings back the last "on" state.
    func testTheClickBringsBackOnlyEveryoneAfterOff() {
        var s = CameraStateSession(saved: .everyoneAndMe)
        s.setLive(.onlyEveryone)
        s.setLive(s.clickTarget(noCameraAllowed: true))
        XCTAssertEqual(s.current, .off)
        s.setLive(s.clickTarget(noCameraAllowed: true))
        XCTAssertEqual(s.current, .onlyEveryone)
    }

    // R6.6: Home's camera tile changes the same live state, so the bar still brings it back.
    func testAChangeFromHomeIsRememberedByTheBarsToggle() {
        var s = CameraStateSession(saved: .everyoneAndMe)
        s.setLive(.onlyEveryone)   // Home's four-way row
        s.setLive(.off)            // Home's off row
        XCTAssertEqual(s.clickTarget(noCameraAllowed: true), .onlyEveryone)
    }

    // R6.6: Home's tile turning the camera on from Off follows the same rule as the bar.
    func testHomesTurnOnFromOffBringsBackTheLastOnState() {
        var s = CameraStateSession(saved: .everyoneAndMe)
        s.setLive(.onlyEveryone)
        s.setLive(.off)
        XCTAssertEqual(s.turnOnTarget, .onlyEveryone)
        var me = CameraStateSession(saved: .onlyMe)
        XCTAssertEqual(me.turnOnTarget, .everyoneAndMe, "Only me keeps its eye and turns the camera on")
        me.setLive(.everyoneAndMe)
        XCTAssertNil(me.turnOnTarget, "already on")
    }

    // R6.3, R6.6: Start drops the live change and the memory with it.
    func testStartForgetsTheLastOnState() {
        var s = CameraStateSession(saved: .off)
        s.setLive(.onlyMe)
        s.setLive(.onlyEveryone)
        s.setLive(.off)
        s.resetToDefault()
        XCTAssertEqual(s.current, .off)
        XCTAssertEqual(s.clickTarget(noCameraAllowed: true), .everyoneAndMe, "not the old meeting's Only everyone")
        var t = CameraStateSession(saved: .onlyEveryone)
        t.setLive(.off)
        t.resetToDefault()
        XCTAssertEqual(t.lastOn, .onlyEveryone, "the layout default's on-state")
    }
}
