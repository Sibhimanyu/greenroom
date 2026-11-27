import XCTest

/// The words under Home's and Layouts' rows (docs/specs/meeting-setup.md R3.2, R3.3, R4.3, R4.4).
final class MeetingSetupLineTests: XCTestCase {

    // Spec: meeting-setup R3.2
    func testNoMeetingNamesTheLayoutItSavesTo() {
        XCTAssertEqual(MeetingSetupLine.home(layoutName: "Raj San Mode", sessionUp: false, forThisMeeting: false),
                       "Saved to Raj San Mode")
    }

    // Spec: meeting-setup R3.2
    func testNoMeetingNeverSaysOnlyForThisMeeting() {
        // A change cannot be in effect with no meeting up, but even if asked, the line says where it is saved.
        let line = MeetingSetupLine.home(layoutName: "A", sessionUp: false, forThisMeeting: true)
        XCTAssertEqual(line, "Saved to A")
    }

    // Spec: meeting-setup R4.3
    func testMeetingWithAChangeSaysForThisMeeting() {
        XCTAssertEqual(MeetingSetupLine.home(layoutName: "A", sessionUp: true, forThisMeeting: true), "For this meeting")
        XCTAssertEqual(MeetingSetupLine.home(layoutName: nil, sessionUp: true, forThisMeeting: true), "For this meeting")
    }

    // Spec: meeting-setup R4.3: a Record session says recording; a meeting keeps its wording.
    func testARecordSessionSaysForThisRecording() {
        XCTAssertEqual(MeetingSetupLine.home(layoutName: "A", sessionUp: true, forThisMeeting: true, recording: true),
                       "For this recording")
        XCTAssertEqual(MeetingSetupLine.home(layoutName: "A", sessionUp: true, forThisMeeting: false, recording: true), "From A")
        XCTAssertEqual(MeetingSetupLine.home(layoutName: "A", sessionUp: false, forThisMeeting: true, recording: true), "Saved to A")
        XCTAssertEqual(MeetingSetupLine.home(layoutName: "A", sessionUp: true, forThisMeeting: true, recording: false), "For this meeting")
    }

    // Spec: meeting-setup R4.3
    func testMeetingWithNoChangeSaysWhereTheValueComesFrom() {
        XCTAssertEqual(MeetingSetupLine.home(layoutName: "A", sessionUp: true, forThisMeeting: false), "From A")
    }

    func testNoLayoutAndNoChangeSaysNothing() {
        XCTAssertNil(MeetingSetupLine.home(layoutName: nil, sessionUp: false, forThisMeeting: false))
        XCTAssertNil(MeetingSetupLine.home(layoutName: "", sessionUp: true, forThisMeeting: false))
    }

    func testNeverSaysClass() {
        for up in [false, true] {
            for changed in [false, true] {
                XCTAssertFalse((MeetingSetupLine.home(layoutName: "A", sessionUp: up, forThisMeeting: changed) ?? "")
                    .lowercased().contains("class"))
            }
        }
    }

    // Spec: meeting-setup R4.4
    func testLayoutsLineOnlyWhileAChangeIsInEffect() {
        XCTAssertEqual(MeetingSetupLine.layouts(forThisMeeting: true, valueName: "Only me"), "For this meeting: Only me")
        XCTAssertNil(MeetingSetupLine.layouts(forThisMeeting: false, valueName: "Only me"))
    }

    // Spec: meeting-setup R4.4
    func testPieceChangeNamesTheShapeOrSaysMoved() {
        var saved = LayoutCamera(); saved.shape = .circle
        var shaped = saved; shaped.shape = .roundedRectangle
        var moved = saved; moved.widthFraction = 0.4
        XCTAssertEqual(MeetingSetupLine.pieceName(saved: saved, inUse: shaped), WebcamShape.roundedRectangle.label)
        XCTAssertEqual(MeetingSetupLine.pieceName(saved: saved, inUse: moved), "Moved or resized")
    }

    // Spec: meeting-setup R3.3
    func testWithNoMeetingTheValueInUseIsTheSavedValueForEverySetting() {
        var setup = MeetingSetup(saved: .init(cameraState: .everyoneAndMe, cameraPiece: LayoutCamera(), share: ShareTarget()))
        var piece = LayoutCamera(); piece.shape = .roundedRectangle
        var share = ShareTarget(); share.kind = .whiteboard
        // From Home (change) and from Layouts (savedEdit), with no meeting live: one value, everywhere.
        setup.change(.cameraState(.onlyMe), meetingLive: false)
        setup.change(.cameraPiece(piece), meetingLive: false)
        setup.savedEdit(.share(share), meetingLive: false)
        XCTAssertEqual(setup.cameraState, setup.saved.cameraState)
        XCTAssertEqual(setup.cameraPiece, setup.saved.cameraPiece)
        XCTAssertEqual(setup.share, setup.saved.share)
        for s in MeetingSetup.Setting.allCases { XCTAssertFalse(setup.isForThisMeeting(s)) }
    }
}
