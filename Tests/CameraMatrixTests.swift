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

    // MARK: the videoStopped dimension (R49)

    // Every state x video stopped. Stopped changes only what the button, the menu row, Home's chip, the
    // "You" tile and the own People row say; everything local (the stage, so the recording, the Room
    // screen and the bubble rule) and the shortcut's toast stay the camera state's own.
    func testEveryCellWithVideoStopped() {
        for r in rows {
            for stopped in [false, true] {
                let s = r.state, what = "\(s.name), video stopped \(stopped)"
                // The one camera button (bar, toolbar, You tile hover).
                let cell = StopVideoRules.cell(state: s, videoStopped: stopped)
                XCTAssertEqual(cell.symbol, stopped ? "video.slash.fill" : r.symbol, "button icon, \(what)")
                XCTAssertEqual(cell.symbolBadge, stopped ? nil : r.badge, "button badge, \(what)")
                XCTAssertEqual(cell.tint == .stopped, stopped, "button red only while stopped, \(what)")
                XCTAssertEqual(StopVideoRules.press(state: s, lastOn: .everyoneAndMe, noCameraAllowed: true, videoStopped: stopped),
                               stopped ? .startVideo : .cameraState(s == .off ? .everyoneAndMe : .off), "click, \(what)")
                // The menu: the four states unchanged and still ticked, then a divider and the row, last.
                let menu = M.cameraMenu(current: s, noCameraAllowed: true, videoStopped: stopped, pick: { _ in }, toggleVideo: {})
                XCTAssertEqual(menu.filter(\.checked).map(\.title), [s.name], "menu tick, \(what)")
                XCTAssertEqual(menu.suffix(2).map(\.kind), [.separator, .item], "divider then the row, \(what)")
                XCTAssertEqual(menu.last?.title, stopped ? "Start video" : "Stop video", "menu row, \(what)")
                // The toolbar's menu: the cameras between the states and the row, which stays last.
                let toolbar = M.cameraMenu(current: s, noCameraAllowed: true, videoStopped: stopped,
                                           cameras: [.header("Camera"), .item("FaceTime HD") {}], pick: { _ in }, toggleVideo: {})
                XCTAssertEqual(toolbar.last?.title, menu.last?.title, "toolbar menu row, \(what)")
                XCTAssertTrue(toolbar.flatTitles.contains("FaceTime HD"), what)
                // Home's chip.
                XCTAssertEqual(CameraTileRules.chipValue(state: s, cameraInPicture: inPicture(s), deviceName: "FaceTime HD",
                                                         videoStopped: stopped),
                               stopped ? "Video stopped" : r.homeValue, "Home chip value, \(what)")
                XCTAssertEqual(CameraTileRules.chipMeaning(state: s, noDevice: false, videoStopped: stopped),
                               stopped ? .videoStopped : .camera(s), "Home chip icon, \(what)")
                // The shortcut is unchanged: it still names the camera state.
                XCTAssertEqual(M.cameraShortcutToast(s), r.toast, "shortcut toast, \(what)")
                // Local things keep going: they read the camera state only.
                XCTAssertEqual(inPicture(s), r.stageDrawsCamera, "stage and recording, \(what)")
                XCTAssertEqual(roomDrawsCamera(s, showsMyCamera: true), r.roomOn, "Room screen, \(what)")
                XCTAssertEqual(Visibility.cameraOnMyScreen(state: s).isOn, r.bubble, "bubble rule, \(what)")
                // The You tile: Zoom's video-off look (the name) with a "Video stopped" corner mark.
                let mark = SelfViewRules.mark(state: s, cameraInPicture: inPicture(s), videoStopped: stopped)
                XCTAssertEqual(mark?.symbol.name, stopped ? "video.slash.fill" : r.selfMark, "You tile mark, \(what)")
                if stopped { XCTAssertEqual(mark?.label, "Video stopped") }
                XCTAssertEqual(SelfViewRules.content(cameraInPicture: inPicture(s), videoStopped: stopped),
                               stopped ? .placeholder : .everyoneSees, "You tile content, \(what)")
                // The own People row follows Zoom: struck while stopped.
                XCTAssertEqual(SelfViewRules.ownRowCameraOff(cameraInPicture: inPicture(s), zoomVideoOn: !stopped),
                               stopped || !r.stageDrawsCamera, "own People row, \(what)")
            }
        }
    }

    // A camera-state change while stopped never starts the video, and Start video returns to the state.
    func testACameraStateChangeWhileStoppedKeepsItStopped() {
        var session = CameraStateSession(saved: .everyoneAndMe)
        var stopped = true
        for s in CameraState.allCases {
            session.setLive(s)
            // The session holds no video flag; the only inputs that clear it are Zoom's status and Start/end.
            stopped = StopVideoRules.videoStopped(after: CameraStateSession.Moment.layoutSwitch, was: stopped)
            XCTAssertTrue(stopped, s.name)
        }
        session.setLive(.onlyEveryone)
        XCTAssertEqual(StopVideoRules.press(state: session.current, lastOn: session.lastOn, noCameraAllowed: true,
                                            videoStopped: stopped), .startVideo)
        XCTAssertEqual(session.current, .onlyEveryone, "Start video comes back as the state that was active")
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

    // MARK: the owner in a view window

    // The Self view view window (and any view-window tile that shows the owner) wears the "You"
    // tile's look from the same rule: Off and Only me get the state's mark over what everyone sees,
    // Video stopped gets the name and "Video stopped", the two "on" states get nothing.
    func testAViewWindowTileOfTheOwnerWearsTheYouTilesLook() {
        for r in rows {
            for stopped in [false, true] {
                let s = r.state, what = "\(s.name), video stopped \(stopped)"
                let you = SelfViewRules.look(state: s, cameraInPicture: inPicture(s), videoStopped: stopped)
                XCTAssertEqual(you.mark, SelfViewRules.mark(state: s, cameraInPicture: inPicture(s), videoStopped: stopped),
                               "one source for the mark, \(what)")
                XCTAssertEqual(you.content, SelfViewRules.content(cameraInPicture: inPicture(s), videoStopped: stopped),
                               "one source for the content, \(what)")
                // Zoom's roster may lag the stop by a second: the rule, not the flag, draws the name.
                for zoomVideoOn in [true, false] {
                    let tile = SelfViewRules.tile(isMe: true, zoomVideoOn: zoomVideoOn, you: you)
                    XCTAssertEqual(tile.mark?.symbol.name, stopped ? "video.slash.fill" : r.selfMark, "mark, \(what)")
                    XCTAssertEqual(tile.mark?.label, stopped ? "Video stopped" : r.selfMark.map { _ in "Camera: \(s.name)" },
                                   "label, \(what)")
                    XCTAssertEqual(tile.videoOn, !stopped && zoomVideoOn, "Off and Only me keep the picture, \(what)")
                }
                // Anyone else's tile is left to Zoom's own flag, with no mark.
                let other = SelfViewRules.tile(isMe: false, zoomVideoOn: true, you: you)
                XCTAssertNil(other.mark, what)
                XCTAssertTrue(other.videoOn, what)
            }
        }
        // Before the coordinator has said anything, the owner's tile is drawn as Zoom says.
        XCTAssertEqual(SelfViewRules.tile(isMe: true, zoomVideoOn: true, you: nil),
                       SelfViewRules.TileLook(mark: nil, videoOn: true))
    }

    func testTheOwnRowFollowsZoomWhenZoomSendsNothing() {
        XCTAssertTrue(SelfViewRules.ownRowCameraOff(cameraInPicture: true, zoomVideoOn: false))
    }
}
