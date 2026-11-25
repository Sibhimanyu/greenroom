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
        XCTAssertEqual(CameraState.allCases.map(\.name), ["Everyone and me", "Only everyone", "Only me", "Off"])
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
