//
//  StopVideoRulesTests.swift
//  GreenroomTests
//
//  R49 Stop video (owner, 2026-11-26, option A): Zoom's own video mute for the owner, apart from the
//  four camera states. One table: every camera state x video stopped, and what the one camera button
//  shows, says and does in each cell.
//
import XCTest

final class StopVideoRulesTests: XCTestCase {
    private typealias R = StopVideoRules

    private struct Cell {
        let state: CameraState
        let stopped: Bool
        let symbol: String
        let badge: String?
        let tint: VisibilitySymbol.Tint
        let lit: Bool
        let caption: String
        let press: CameraButtonPress
        let menuRow: String
    }

    /// lastOn is Everyone & me and a whole screen is shared (Off allowed).
    private let table: [Cell] = [
        Cell(state: .everyoneAndMe, stopped: false, symbol: "video.fill", badge: nil, tint: .primary, lit: false,
             caption: "Everyone & me", press: .cameraState(.off), menuRow: "Stop video"),
        Cell(state: .onlyEveryone, stopped: false, symbol: "video.fill", badge: nil, tint: .primary, lit: true,
             caption: "Only the meeting", press: .cameraState(.off), menuRow: "Stop video"),
        Cell(state: .onlyMe, stopped: false, symbol: "video.fill", badge: "eye.slash", tint: .primary, lit: true,
             caption: "Only me", press: .cameraState(.off), menuRow: "Stop video"),
        Cell(state: .off, stopped: false, symbol: "video.slash", badge: nil, tint: .neutral, lit: false,
             caption: "Off", press: .cameraState(.everyoneAndMe), menuRow: "Stop video"),
        Cell(state: .everyoneAndMe, stopped: true, symbol: "video.slash.fill", badge: nil, tint: .stopped, lit: false,
             caption: "Start video", press: .startVideo, menuRow: "Start video"),
        Cell(state: .onlyEveryone, stopped: true, symbol: "video.slash.fill", badge: nil, tint: .stopped, lit: false,
             caption: "Start video", press: .startVideo, menuRow: "Start video"),
        Cell(state: .onlyMe, stopped: true, symbol: "video.slash.fill", badge: nil, tint: .stopped, lit: false,
             caption: "Start video", press: .startVideo, menuRow: "Start video"),
        Cell(state: .off, stopped: true, symbol: "video.slash.fill", badge: nil, tint: .stopped, lit: false,
             caption: "Start video", press: .startVideo, menuRow: "Start video"),
    ]

    func testEveryCellOfStateTimesVideoStopped() {
        XCTAssertEqual(table.count, CameraState.allCases.count * 2, "every state, stopped and not")
        for c in table {
            let what = "\(c.state.name), stopped \(c.stopped)"
            let cell = R.cell(state: c.state, videoStopped: c.stopped)
            XCTAssertEqual(cell.symbol, c.symbol, "icon, \(what)")
            XCTAssertEqual(cell.symbolBadge, c.badge, "badge, \(what)")
            XCTAssertEqual(cell.tint, c.tint, "tint, \(what)")
            XCTAssertEqual(cell.on, c.lit, "lit, \(what)")
            XCTAssertEqual(R.caption(state: c.state, videoStopped: c.stopped), c.caption, "toolbar caption, \(what)")
            XCTAssertEqual(R.press(state: c.state, lastOn: .everyoneAndMe, noCameraAllowed: true, videoStopped: c.stopped),
                           c.press, "click, \(what)")
            let row = R.menuRow(videoStopped: c.stopped) {}
            XCTAssertEqual(row.map(\.kind), [.separator, .item], "a divider, then the row, \(what)")
            XCTAssertEqual(row.last?.title, c.menuRow, "menu row, \(what)")
            XCTAssertFalse(cell.help.localizedCaseInsensitiveContains("class"), what)
            XCTAssertFalse(cell.spoken.localizedCaseInsensitiveContains("class"), what)
            if c.stopped {
                XCTAssertTrue(cell.help.contains("Video stopped") && cell.spoken.contains("Video stopped"), what)
                XCTAssertTrue(cell.help.contains(c.state.name), "the help names the state video comes back as, \(what)")
            } else {
                XCTAssertEqual(cell, MeetingBarModel.cameraStateCell(c.state), "not stopped, the camera state's own cell")
            }
        }
    }

    // The owner: the stopped mark must not read as camera state Off.
    func testStoppedLooksDifferentFromOff() {
        let off = R.cell(state: .off, videoStopped: false), stopped = R.cell(state: .off, videoStopped: true)
        XCTAssertNotEqual(off.symbol, stopped.symbol)
        XCTAssertNotEqual(off.tint, stopped.tint)
        XCTAssertEqual(stopped.tint, .stopped, "Zoom's red for stopped video")
        XCTAssertNotEqual(off.tint, .stopped, "Off sends the shared picture, so it is not the stopped red")
    }

    // The menu row's words: a one-line note, and never "class".
    func testTheMenuRowSaysWhatStopVideoDoes() {
        let stop = R.menuRow(videoStopped: false) {}.last!, start = R.menuRow(videoStopped: true) {}.last!
        XCTAssertEqual(stop.note, "Everyone sees your name. Nothing is sent, not even your screen.")
        XCTAssertNotNil(start.note)
        var ran = 0
        R.menuRow(videoStopped: false) { ran += 1 }.last?.action?()
        XCTAssertEqual(ran, 1)
        for e in [stop, start] { XCTAssertFalse((e.title + (e.note ?? "")).localizedCaseInsensitiveContains("class")) }
    }

    // Not stopped, the click keeps today's rule (CameraStateSession.clickTarget) in every case.
    func testNotStoppedTheClickIsTheCameraStatesOwn() {
        for s in CameraState.allCases {
            for last in CameraState.allCases {
                for allowed in [true, false] {
                    XCTAssertEqual(R.press(state: s, lastOn: last, noCameraAllowed: allowed, videoStopped: false),
                                   .cameraState(CameraStateSession.clickTarget(current: s, lastOn: last, noCameraAllowed: allowed)))
                    XCTAssertEqual(R.press(state: s, lastOn: last, noCameraAllowed: allowed, videoStopped: true), .startVideo)
                }
            }
        }
    }

    // Zoom's word is the truth: its callback, a co-host's stop included. An unknown status changes nothing.
    func testZoomsVideoStatusIsTheTruth() {
        for was in [false, true] {
            XCTAssertFalse(R.videoStopped(after: OwnVideoStatus.on, was: was))
            XCTAssertTrue(R.videoStopped(after: OwnVideoStatus.off, was: was))
            XCTAssertTrue(R.videoStopped(after: OwnVideoStatus.stoppedByHost, was: was))
            XCTAssertEqual(R.videoStopped(after: OwnVideoStatus.unknown, was: was), was)
        }
    }

    // A layout switch or Snap Back never starts the video. Start begins with video on; the end clears it.
    func testOnlyStartAndTheEndClearIt() {
        XCTAssertTrue(R.videoStopped(after: CameraStateSession.Moment.layoutSwitch, was: true))
        XCTAssertTrue(R.videoStopped(after: CameraStateSession.Moment.snapBack, was: true))
        XCTAssertFalse(R.videoStopped(after: CameraStateSession.Moment.start, was: true))
        XCTAssertFalse(R.videoStopped(after: CameraStateSession.Moment.end, was: true))
        for m: CameraStateSession.Moment in [.start, .snapBack, .end, .layoutSwitch] {
            XCTAssertFalse(R.videoStopped(after: m, was: false), "nothing stops the video by itself")
        }
    }

    // What asking Zoom means: Stop asks for video off, Start for on; a refusal leaves the UI as it was.
    func testARefusalLeavesTheStateAndLogsALine() {
        XCTAssertEqual(R.request(videoStopped: false), .stop)
        XCTAssertEqual(R.request(videoStopped: true), .start)
        XCTAssertNil(R.refusalLine(.stop, accepted: true))
        XCTAssertEqual(R.refusalLine(.stop, accepted: false), "Stop video: Zoom refused. Nothing changed.")
        XCTAssertEqual(R.refusalLine(.start, accepted: false), "Start video: Zoom refused. Nothing changed.")
    }
}
