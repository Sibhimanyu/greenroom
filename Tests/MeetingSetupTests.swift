import XCTest

/// MeetingSetup through its one change call and its events (docs/specs/meeting-setup.md).
final class MeetingSetupTests: XCTestCase {

    private func piece(_ shape: WebcamShape, width: Double = 0.24) -> LayoutCamera {
        var c = LayoutCamera()
        c.shape = shape
        c.widthFraction = width
        return c
    }

    private func share(_ kind: ShareTarget.Kind) -> ShareTarget {
        var s = ShareTarget()
        s.kind = kind
        return s
    }

    private func values(_ state: CameraState = .everyoneAndMe, _ shape: WebcamShape = .circle,
                        _ kind: ShareTarget.Kind = .display) -> MeetingSetup.Values {
        MeetingSetup.Values(cameraState: state, cameraPiece: piece(shape), share: share(kind))
    }

    private func setup() -> MeetingSetup { MeetingSetup(saved: values()) }

    // Spec: meeting-setup R2.1
    func testHoldsTheSavedValuesAndNoChange() {
        let s = setup()
        XCTAssertEqual(s.saved, values())
        for setting in MeetingSetup.Setting.allCases { XCTAssertFalse(s.isForThisMeeting(setting)) }
    }

    // Spec: meeting-setup R2.2
    func testValueInUseIsTheChangeElseTheSavedValue() {
        var s = setup()
        XCTAssertEqual(s.cameraState, .everyoneAndMe)
        s.change(.cameraState(.onlyMe), meetingLive: true)
        s.change(.share(share(.nothing)), meetingLive: true)
        XCTAssertEqual(s.cameraState, .onlyMe)
        XCTAssertEqual(s.share, share(.nothing))
        XCTAssertEqual(s.cameraPiece, piece(.circle), "untouched setting still reads the saved value")
        XCTAssertTrue(s.isForThisMeeting(.cameraState))
        XCTAssertTrue(s.isForThisMeeting(.share))
        XCTAssertFalse(s.isForThisMeeting(.cameraPiece))
    }

    // Spec: meeting-setup R2.2
    func testAChangeEqualToTheSavedValueIsNotAForThisMeetingChange() {
        var s = setup()
        s.change(.share(share(.nothing)), meetingLive: true)
        s.change(.share(share(.display)), meetingLive: true)
        XCTAssertFalse(s.isForThisMeeting(.share))
        XCTAssertEqual(s.share, share(.display))
    }

    // Spec: meeting-setup R3.1
    func testBeforeAMeetingAChangeIsSavedAndNoChangeExists() {
        for change: MeetingSetup.Change in [.cameraState(.off), .cameraPiece(piece(.cutout)), .share(share(.window))] {
            var s = setup()
            let effect = s.change(change, meetingLive: false)
            XCTAssertEqual(effect.saved, [change.setting])
            XCTAssertEqual(effect.inUse, [change.setting])
            XCTAssertFalse(s.isForThisMeeting(change.setting))
        }
        var s = setup()
        s.change(.cameraPiece(piece(.cutout)), meetingLive: false)
        s.change(.cameraState(.onlyEveryone), meetingLive: false)
        s.change(.share(share(.window)), meetingLive: false)
        XCTAssertEqual(s.saved, values(.onlyEveryone, .cutout, .window))
        XCTAssertEqual(s.cameraPiece, piece(.cutout))
    }

    // Spec: meeting-setup R2.3
    func testAChangeReportsOnlyWhatChanged() {
        var s = setup()
        XCTAssertEqual(s.change(.cameraState(.everyoneAndMe), meetingLive: false), MeetingSetup.Effect())
        XCTAssertEqual(s.change(.cameraState(.onlyMe), meetingLive: true),
                       MeetingSetup.Effect(saved: [], inUse: [.cameraState]))
    }

    // Spec: meeting-setup R4.1
    func testALiveChangeIsForThisMeetingAndLeavesSavedAlone() {
        for change: MeetingSetup.Change in [.cameraState(.off), .cameraPiece(piece(.cutout)), .share(share(.window))] {
            var s = setup()
            let effect = s.change(change, meetingLive: true)
            XCTAssertEqual(effect.saved, [])
            XCTAssertEqual(effect.inUse, [change.setting])
            XCTAssertEqual(s.saved, values())
            XCTAssertTrue(s.isForThisMeeting(change.setting))
        }
    }

    // Spec: meeting-setup R4.2
    func testLayoutsEditWhileLiveSavesAndTheMeetingGetsItWhenNoChangeExists() {
        var s = setup()
        let effect = s.savedEdit(.share(share(.whiteboard)), meetingLive: true)
        XCTAssertEqual(effect.saved, [.share])
        XCTAssertEqual(effect.inUse, [.share])
        XCTAssertEqual(s.share, share(.whiteboard))
        XCTAssertFalse(s.isForThisMeeting(.share))
    }

    // Spec: meeting-setup R4.2
    func testLayoutsEditWhileLiveDoesNotOverrideAForThisMeetingChange() {
        var s = setup()
        s.change(.cameraPiece(piece(.cutout)), meetingLive: true)
        let effect = s.savedEdit(.cameraPiece(piece(.square)), meetingLive: true)
        XCTAssertEqual(effect.saved, [.cameraPiece])
        XCTAssertEqual(effect.inUse, [])
        XCTAssertEqual(s.saved.cameraPiece, piece(.square))
        XCTAssertEqual(s.cameraPiece, piece(.cutout))
        XCTAssertTrue(s.isForThisMeeting(.cameraPiece))
    }

    // Spec: meeting-setup R4.2
    func testLayoutsEditWhileNotLiveIsJustASavedChange() {
        var s = setup()
        let effect = s.savedEdit(.cameraState(.off), meetingLive: false)
        XCTAssertEqual(effect, MeetingSetup.Effect(saved: [.cameraState], inUse: [.cameraState]))
        XCTAssertEqual(s.cameraState, .off)
    }

    // Spec: meeting-setup R5.1
    func testEveryEndEventDropsEveryChange() {
        for event: MeetingSetup.Event in [.start, .snapBack, .meetingEnded] {
            var s = setup()
            s.change(.cameraState(.onlyMe), meetingLive: true)
            s.change(.cameraPiece(piece(.cutout)), meetingLive: true)
            s.change(.share(share(.nothing)), meetingLive: true)
            let effect = s.apply(event)
            XCTAssertEqual(effect.saved, [])
            XCTAssertEqual(effect.inUse, [.cameraState, .cameraPiece, .share])
            XCTAssertEqual(s.saved, values())
            XCTAssertEqual(s.cameraState, .everyoneAndMe)
            XCTAssertEqual(s.cameraPiece, piece(.circle))
            XCTAssertEqual(s.share, share(.display))
            for setting in MeetingSetup.Setting.allCases { XCTAssertFalse(s.isForThisMeeting(setting)) }
        }
    }

    // Spec: meeting-setup R5.1
    func testAnEndEventWithNothingToDropChangesNothing() {
        var s = setup()
        XCTAssertEqual(s.apply(.start), MeetingSetup.Effect())
    }

    // Spec: meeting-setup R5.1, R5.2
    func testALayoutSwitchBringsInTheNewSavedValuesAndDropsChanges() {
        var s = setup()
        s.change(.cameraState(.onlyMe), meetingLive: true)
        s.change(.share(share(.nothing)), meetingLive: true)
        let next = values(.onlyEveryone, .cutout, .window)
        let effect = s.apply(.layoutSwitched(to: next))
        XCTAssertEqual(s.saved, next)
        XCTAssertEqual(s.cameraState, .onlyEveryone, "a for-this-meeting camera state other than Off does not survive a layout switch")
        XCTAssertEqual(s.cameraPiece, piece(.cutout))
        XCTAssertEqual(s.share, share(.window))
        XCTAssertEqual(effect.saved, [.cameraState, .cameraPiece, .share])
        XCTAssertEqual(effect.inUse, [.cameraState, .cameraPiece, .share])
        for setting in MeetingSetup.Setting.allCases { XCTAssertFalse(s.isForThisMeeting(setting)) }
    }

    // Spec: meeting-setup R5.2
    func testALayoutSwitchToSimilarValuesReportsOnlyTheDifferences() {
        var s = setup()
        let effect = s.apply(.layoutSwitched(to: values(.everyoneAndMe, .square, .display)))
        XCTAssertEqual(effect, MeetingSetup.Effect(saved: [.cameraPiece], inUse: [.cameraPiece]))
    }

    // Spec: meeting-setup R4.4
    func testKeepSavesTheChangeAndClearsIt() {
        var s = setup()
        s.change(.cameraPiece(piece(.cutout)), meetingLive: true)
        let effect = s.apply(.keep(.cameraPiece))
        XCTAssertEqual(effect, MeetingSetup.Effect(saved: [.cameraPiece], inUse: []))
        XCTAssertEqual(s.saved.cameraPiece, piece(.cutout))
        XCTAssertEqual(s.cameraPiece, piece(.cutout))
        XCTAssertFalse(s.isForThisMeeting(.cameraPiece))
    }

    // Spec: meeting-setup R4.4
    func testKeepWithNoChangeDoesNothing() {
        var s = setup()
        XCTAssertEqual(s.apply(.keep(.share)), MeetingSetup.Effect())
    }

    // Spec: meeting-setup R4.4
    func testKeepOnlyTouchesItsOwnSetting() {
        var s = setup()
        s.change(.share(share(.nothing)), meetingLive: true)
        s.change(.cameraState(.onlyMe), meetingLive: true)
        s.apply(.keep(.share))
        XCTAssertEqual(s.saved.share, share(.nothing))
        XCTAssertEqual(s.saved.cameraState, .everyoneAndMe)
        XCTAssertTrue(s.isForThisMeeting(.cameraState))
    }

    // Spec: meeting-setup R4.4
    func testResetClearsTheChangeSoTheMeetingGetsTheSavedValue() {
        var s = setup()
        s.change(.cameraState(.onlyMe), meetingLive: true)
        let effect = s.apply(.reset(.cameraState))
        XCTAssertEqual(effect, MeetingSetup.Effect(saved: [], inUse: [.cameraState]))
        XCTAssertEqual(s.cameraState, .everyoneAndMe)
        XCTAssertEqual(s.saved.cameraState, .everyoneAndMe)
        XCTAssertFalse(s.isForThisMeeting(.cameraState))
    }

    // Spec: meeting-setup R5.3
    func testLastOnFollowsLiveChangesAndComesBackAfterOff() {
        var s = MeetingSetup(saved: values(.onlyEveryone))
        s.change(.cameraState(.off), meetingLive: true)
        XCTAssertEqual(s.cameraClickTarget(noCameraAllowed: true), .onlyEveryone, "Off comes back as the last on state")
        s.change(.cameraState(.onlyMe), meetingLive: true)
        s.change(.cameraState(.off), meetingLive: true)
        XCTAssertEqual(s.cameraClickTarget(noCameraAllowed: true), .onlyMe)
    }

    // Spec: meeting-setup R5.3
    func testLastOnResetsToTheSavedOnStateAtEveryDropMoment() {
        for event: MeetingSetup.Event in [.start, .snapBack, .meetingEnded, .reset(.cameraState)] {
            var s = MeetingSetup(saved: values(.onlyEveryone))
            s.change(.cameraState(.onlyMe), meetingLive: true)
            s.change(.cameraState(.off), meetingLive: true)
            s.apply(event)
            s.change(.cameraState(.off), meetingLive: true)
            XCTAssertEqual(s.cameraClickTarget(noCameraAllowed: true), .onlyEveryone)
        }
    }

    // Spec: meeting-setup R5.3
    func testLastOnResetsToTheNewLayoutsOnStateOnASwitch() {
        var s = MeetingSetup(saved: values(.onlyEveryone))
        s.change(.cameraState(.onlyMe), meetingLive: true)
        s.apply(.layoutSwitched(to: values(.off)))
        XCTAssertEqual(s.cameraState, .off)
        XCTAssertEqual(s.cameraClickTarget(noCameraAllowed: true), .everyoneAndMe, "an Off layout comes on as Everyone & me")
    }

    // Spec: meeting-setup R5.3
    func testKeepKeepsTheLastOnMemory() {
        var s = MeetingSetup(saved: values(.onlyEveryone))
        s.change(.cameraState(.onlyMe), meetingLive: true)
        s.change(.cameraState(.off), meetingLive: true)
        s.apply(.keep(.cameraState))
        XCTAssertEqual(s.saved.cameraState, .off)
        XCTAssertEqual(s.cameraClickTarget(noCameraAllowed: true), .onlyMe)
    }

    // Spec: meeting-setup R5.3
    func testASavedChangeBeforeAMeetingSetsLastOn() {
        var s = setup()
        s.change(.cameraState(.onlyMe), meetingLive: false)
        s.change(.cameraState(.off), meetingLive: false)
        XCTAssertEqual(s.cameraClickTarget(noCameraAllowed: true), .everyoneAndMe)
        s.change(.cameraState(.onlyMe), meetingLive: false)
        XCTAssertEqual(s.cameraTurnOnTarget, .everyoneAndMe, "Only me turns on as Everyone & me")
    }

    func testTurnOnTargetIsNilWhenTheMeetingAlreadySeesTheCamera() {
        XCTAssertNil(setup().cameraTurnOnTarget)
    }

    // Spec: meeting-setup R5.4
    func testACameraTurnedOffForThisMeetingStaysOffAcrossALayoutSwitch() {
        var s = setup()
        s.change(.cameraState(.off), meetingLive: true)
        s.change(.share(share(.nothing)), meetingLive: true)
        s.change(.cameraPiece(piece(.square)), meetingLive: true)
        let next = values(.onlyEveryone, .cutout, .window)
        let effect = s.apply(.layoutSwitched(to: next))
        XCTAssertEqual(s.cameraState, .off, "Off stays Off")
        XCTAssertEqual(s.saved, next, "the new layout's saved values come in")
        XCTAssertTrue(s.isForThisMeeting(.cameraState))
        XCTAssertEqual(s.share, share(.window), "every other change is dropped")
        XCTAssertEqual(s.cameraPiece, piece(.cutout))
        XCTAssertFalse(s.isForThisMeeting(.share))
        XCTAssertFalse(s.isForThisMeeting(.cameraPiece))
        XCTAssertEqual(effect.inUse, [.cameraPiece, .share], "the camera state in use did not change")
        XCTAssertEqual(effect.saved, [.cameraState, .cameraPiece, .share])
    }

    // Spec: meeting-setup R5.4
    func testAnOffThatTheNewLayoutAlsoHasIsNotAForThisMeetingChange() {
        var s = setup()
        s.change(.cameraState(.off), meetingLive: true)
        s.apply(.layoutSwitched(to: values(.off)))
        XCTAssertEqual(s.cameraState, .off)
        XCTAssertFalse(s.isForThisMeeting(.cameraState))
    }

    // Spec: meeting-setup R5.4
    func testTheCameraComesBackAsTheNewLayoutsOnStateAfterASwitchHeldItOff() {
        var s = MeetingSetup(saved: values(.onlyEveryone))
        s.change(.cameraState(.off), meetingLive: true)
        s.apply(.layoutSwitched(to: values(.onlyMe)))
        XCTAssertEqual(s.cameraClickTarget(noCameraAllowed: true), .onlyMe)
    }

    // Spec: meeting-setup R5.4
    func testStartSnapBackAndTheMeetingEndingStillDropAnOff() {
        for event: MeetingSetup.Event in [.start, .snapBack, .meetingEnded] {
            var s = setup()
            s.change(.cameraState(.off), meetingLive: true)
            s.apply(event)
            XCTAssertEqual(s.cameraState, .everyoneAndMe, "\(event)")
        }
    }

    // Spec: meeting-setup R5.4
    func testAnOffNeverCarriesAcrossASwitchBeforeAMeeting() {
        var s = setup()
        s.change(.cameraState(.off), meetingLive: false)
        s.apply(.layoutSwitched(to: values(.onlyEveryone)))
        XCTAssertEqual(s.cameraState, .onlyEveryone, "before a meeting Off was saved into the old layout, not for this meeting")
    }
}
