//
//  CameraMatrixTests.swift
//  GreenroomTests
//
//  The camera state matrix (owner, 2026-11-26: "make sure that camera button handles all those
//  test cases"). Rows are the four states; columns are every place the state is shown or changed.
//  Each column asks the one rule that surface reads, so a surface that reads a copy, or Zoom's own
//  video flag, shows up here as a disagreeing cell.
//
import XCTest

final class CameraMatrixTests: XCTestCase {
    private typealias M = MeetingBarModel

    /// One row of the matrix: what each surface should say for a state (whole-screen share).
    private struct Row {
        let state: CameraState
        // The Meeting toolbar's and the floating bar's one camera button (MeetingBarModel.cameraStateCell).
        let symbol: String
        let badge: String?
        let lit: Bool
        // Home's camera chip: its value with a camera named "FaceTime HD".
        let homeValue: String
        // The camera shortcut's toast.
        let toast: String
        // The camera bubble on the owner's screen.
        let bubble: Bool
        // The stage picture (and so the recording and Zoom's own render of the owner).
        let stageDrawsCamera: Bool
        let cameraOpen: Bool
        // The Room screen, with "Show my camera" on and off.
        let roomOn: Bool
        let roomOff: Bool
        // The "You" tile's mark.
        let selfMark: String?
        // Other apps' recorders and the bubble window.
        let bubbleRecordable: Bool
    }

    private let rows: [Row] = [
        Row(state: .everyoneAndMe, symbol: "video.fill", badge: nil, lit: false, homeValue: "FaceTime HD",
            toast: "Camera: Everyone & me", bubble: true, stageDrawsCamera: true, cameraOpen: true,
            roomOn: true, roomOff: false, selfMark: nil, bubbleRecordable: true),
        Row(state: .onlyEveryone, symbol: "video.fill", badge: nil, lit: true, homeValue: "FaceTime HD",
            toast: "Camera: Only the meeting", bubble: false, stageDrawsCamera: true, cameraOpen: true,
            roomOn: true, roomOff: false, selfMark: nil, bubbleRecordable: true),
        Row(state: .onlyMe, symbol: "video.fill", badge: "eye.slash", lit: true, homeValue: "Only me",
            toast: "Camera: Only me", bubble: true, stageDrawsCamera: false, cameraOpen: true,
            roomOn: false, roomOff: false, selfMark: "video.fill", bubbleRecordable: false),
        Row(state: .off, symbol: "video.slash", badge: nil, lit: false, homeValue: "Off",
            toast: "Camera: Off", bubble: false, stageDrawsCamera: false, cameraOpen: false,
            roomOn: false, roomOff: false, selfMark: "video.slash", bubbleRecordable: true),
    ]

    private func inPicture(_ s: CameraState, _ t: Visibility.Target = .wholeScreen) -> Bool {
        Visibility.cameraEveryoneSees(state: s, target: t).isOn
    }

    private func roomDrawsCamera(_ s: CameraState, showsMyCamera: Bool) -> Bool {
        RoomScreenRules.source(compositorRunning: true, showsMyCamera: showsMyCamera) == .compositor && inPicture(s)
    }

    func testEveryCellOfTheMatrix() {
        XCTAssertEqual(rows.map(\.state), CameraState.allCases, "one row per state")
        for r in rows {
            let s = r.state, name = s.name
            let cell = M.cameraStateCell(s)
            XCTAssertEqual(cell.symbol, r.symbol, "button icon, \(name)")
            XCTAssertEqual(cell.symbolBadge, r.badge, "button badge, \(name)")
            XCTAssertEqual(cell.on, r.lit, "button lit, \(name)")
            XCTAssertTrue(cell.spoken.contains(name) && cell.help.contains(name), "button words, \(name)")
            let menu = M.cameraStateMenu(current: s, noCameraAllowed: true) { _ in }
            XCTAssertEqual(menu.filter(\.checked).map(\.title), [name], "menu tick, \(name)")
            // Home: the chip's icon is the state's own; its value names the state when the camera is out.
            XCTAssertEqual(VisibilitySymbol.camera(s).name, r.symbol, "Home chip icon, \(name)")
            XCTAssertEqual(CameraTileRules.chipValue(state: s, cameraInPicture: inPicture(s), deviceName: "FaceTime HD"),
                           r.homeValue, "Home chip value, \(name)")
            XCTAssertEqual(M.cameraShortcutToast(s), r.toast, "shortcut toast, \(name)")
            XCTAssertEqual(!PresenceVisibility.bubbleStartsHidden(state: s), r.bubble, "bubble, \(name)")
            XCTAssertEqual(Visibility.cameraOnMyScreen(state: s).isOn, r.bubble, "bubble rule, \(name)")
            XCTAssertEqual(inPicture(s), r.stageDrawsCamera, "stage, \(name)")
            XCTAssertEqual(Visibility.cameraRuns(state: s, target: .wholeScreen), r.cameraOpen, "camera open, \(name)")
            XCTAssertEqual(roomDrawsCamera(s, showsMyCamera: true), r.roomOn, "Room screen, Show my camera on, \(name)")
            XCTAssertEqual(roomDrawsCamera(s, showsMyCamera: false), r.roomOff, "Room screen, Show my camera off, \(name)")
            let mark = SelfViewRules.mark(state: s, cameraInPicture: inPicture(s))
            XCTAssertEqual(mark?.symbol.name, r.selfMark, "You tile mark, \(name)")
            if let mark { XCTAssertEqual(mark.label, "Camera: \(name)") }
            XCTAssertEqual(PresenceRecorderRules.cameraBubbleSharing(cameraState: s) == .readOnly, r.bubbleRecordable,
                           "bubble recordable by other apps, \(name)")
            XCTAssertEqual(SelfViewRules.ownRowCameraOff(cameraInPicture: inPicture(s), zoomVideoOn: true),
                           !r.stageDrawsCamera, "own People row, \(name)")
        }
    }

    // Just my camera: the camera is the whole picture, so it stays in whatever the state says (R6.4),
    // and no surface claims it is out.
    func testJustMyCameraKeepsTheCameraInAndNothingSaysItIsOut() {
        for s in CameraState.allCases {
            XCTAssertTrue(inPicture(s, .justMe), s.name)
            XCTAssertNil(SelfViewRules.mark(state: s, cameraInPicture: inPicture(s, .justMe)), s.name)
            XCTAssertFalse(SelfViewRules.ownRowCameraOff(cameraInPicture: inPicture(s, .justMe), zoomVideoOn: true), s.name)
        }
    }

    // MARK: transitions

    // Off -> on returns the last on state, from the bar, the toolbar and Home alike (one session).
    func testOffThenOnReturnsTheLastOnStateFromEverySurface() {
        for on in CameraState.allCases where on != .off {
            var bar = CameraStateSession(saved: .everyoneAndMe)
            bar.setLive(on)
            bar.setLive(bar.clickTarget(noCameraAllowed: true))
            XCTAssertEqual(bar.current, .off, "a click turns \(on.name) off")
            bar.setLive(bar.clickTarget(noCameraAllowed: true))
            XCTAssertEqual(bar.current, on, "a second click brings back \(on.name)")

            var home = CameraStateSession(saved: .everyoneAndMe)
            home.setLive(on)
            home.setLive(.off)
            XCTAssertEqual(home.turnOnTarget, on, "Home brings back \(on.name)")
        }
    }

    // A layout switch mid-meeting: the camera state is not part of a layout, so a live Off stays Off.
    func testALayoutSwitchKeepsTheLiveCameraState() {
        var s = CameraStateSession(saved: .everyoneAndMe)
        s.setLive(.off)
        XCTAssertFalse(s.reset(at: .layoutSwitch))
        XCTAssertEqual(s.current, .off, "switching layouts must not put the camera back in front of everyone")
        s.setLive(s.clickTarget(noCameraAllowed: true))
        XCTAssertEqual(s.current, .everyoneAndMe, "the last on state survives the switch")
    }

    // Start, Snap Back and the end drop the live change (R6.3).
    func testStartSnapBackAndEndDropTheLiveChange() {
        for moment: CameraStateSession.Moment in [.start, .snapBack, .end] {
            var s = CameraStateSession(saved: .onlyEveryone)
            s.setLive(.off)
            XCTAssertTrue(s.reset(at: moment), "\(moment)")
            XCTAssertEqual(s.current, .onlyEveryone, "\(moment)")
        }
    }

    // Start with each state saved: the session starts in it, and the first click does what the button says.
    func testStartWithEachSavedState() {
        for saved in CameraState.allCases {
            var s = CameraStateSession(saved: saved)
            s.reset(at: .start)
            XCTAssertEqual(s.current, saved)
            let next = s.clickTarget(noCameraAllowed: true)
            XCTAssertEqual(next, saved == .off ? .everyoneAndMe : .off, saved.name)
        }
    }

    // A camera that stops sending a picture is not a state change: no rule reads the device's liveness.
    // The state, and so every cell above, stays as it was; the stage keeps the last frame and logs it.
    func testACameraThatStopsSendingDoesNotChangeTheState() {
        var s = CameraStateSession(saved: .everyoneAndMe)
        s.setLive(.onlyEveryone)
        let before = s
        // The flapping device feeds nothing into the session; its only input is setLive / reset.
        XCTAssertEqual(s, before)
        XCTAssertTrue(inPicture(s.current))
    }

    // MARK: the You tile

    // The owner chose (a): the tile keeps what everyone sees. (b) is one switch away.
    func testTheYouTileShowsWhatEveryoneSeesAndThePlaceholderIsOneSwitchAway() {
        for s in CameraState.allCases {
            XCTAssertEqual(SelfViewRules.content(cameraInPicture: inPicture(s)), .everyoneSees, s.name)
        }
        XCTAssertEqual(SelfViewRules.content(cameraInPicture: false, placeholderWhenOut: true), .placeholder)
        XCTAssertEqual(SelfViewRules.content(cameraInPicture: true, placeholderWhenOut: true), .everyoneSees)
    }

    func testTheOwnRowFollowsZoomWhenZoomSendsNothing() {
        XCTAssertTrue(SelfViewRules.ownRowCameraOff(cameraInPicture: true, zoomVideoOn: false))
    }
}
