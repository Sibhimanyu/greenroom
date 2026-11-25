import XCTest
import Carbon.HIToolbox

final class MeetingBarModelTests: XCTestCase {
    private typealias M = MeetingBarModel
    private let none = ShortcutBindings()

    private func titles(_ e: [MenuEntry]) -> [String] { e.flatMap { $0.kind == .separator ? [] : [$0.title] } }

    // The REC pill: one timer

    func testRecordingPillShowsTheClassTimeAndHoversTheRecordingLength() {
        let p = M.recordPill(.recording, classSeconds: 98, recordingSeconds: 89)
        XCTAssertEqual(p.label, "REC")
        XCTAssertEqual(p.time, "1:38")
        XCTAssertEqual(p.help, "Recording 1:29 \u{00B7} meeting 1:38")
        XCTAssertTrue(p.showsDot && p.dotIsLive && p.hasMenu)
    }

    func testPausedPillStopsPulsingAndSaysPaused() {
        let p = M.recordPill(.paused, classSeconds: 98, recordingSeconds: 89)
        XCTAssertEqual(p.label, "Paused")
        XCTAssertEqual(p.time, "1:38")
        XCTAssertTrue(p.showsDot)
        XCTAssertFalse(p.dotIsLive)
        XCTAssertTrue(p.help.contains("1:29") && p.help.contains("1:38"))
    }

    func testIdlePillIsAOneClickRecordButton() {
        let p = M.recordPill(.idle, classSeconds: 98, recordingSeconds: 0)
        XCTAssertEqual(p.label, "Record")
        XCTAssertEqual(p.spoken, "Start recording")
        XCTAssertNil(p.time)
        XCTAssertTrue(p.isButton)
        XCTAssertTrue(p.showsDot)
        XCTAssertFalse(p.dotIsLive)
        XCTAssertFalse(p.hasMenu)
        XCTAssertFalse(p.label.contains("Not recording"))
        for phase in [MeetingBarRecordPhase.recording, .paused, .countdown, .saving] {
            XCTAssertFalse(M.recordPill(phase, classSeconds: 1, recordingSeconds: 1).isButton)
        }
    }

    func testSavingPillHasNoMenu() {
        XCTAssertFalse(M.recordPill(.saving, classSeconds: 5, recordingSeconds: 5).hasMenu)
    }

    func testClockText() {
        XCTAssertEqual(M.clock(0), "0:00")
        XCTAssertEqual(M.clock(89), "1:29")
        XCTAssertEqual(M.clock(3599), "59:59")
        XCTAssertEqual(M.clock(3661), "1:01:01")
        XCTAssertEqual(M.clock(-5), "0:00")
    }

    func testPhaseFromFlags() {
        func p(_ r: Bool, _ pa: Bool, _ s: Bool, _ c: Bool) -> MeetingBarRecordPhase {
            MeetingBarRecordPhase(recording: r, paused: pa, saving: s, countdown: c)
        }
        XCTAssertEqual(p(false, false, false, false), .idle)
        XCTAssertEqual(p(true, false, false, false), .recording)
        XCTAssertEqual(p(true, true, false, false), .paused)
        XCTAssertEqual(p(false, false, false, true), .countdown)
        XCTAssertEqual(p(true, false, true, false), .saving)
    }

    // The REC menu, per state

    func testRecordMenuPerState() {
        XCTAssertEqual(titles(M.recordMenu(.idle, none, .init())), ["Start Recording"])
        XCTAssertEqual(titles(M.recordMenu(.recording, none, .init())), ["Pause Recording", "Stop Recording"])
        XCTAssertEqual(titles(M.recordMenu(.paused, none, .init())), ["Resume Recording", "Stop Recording"])
        XCTAssertEqual(titles(M.recordMenu(.countdown, none, .init())), ["Cancel Countdown"])
        let saving = M.recordMenu(.saving, none, .init())
        XCTAssertEqual(titles(saving), ["Saving\u{2026}"])
        XCTAssertFalse(saving[0].enabled)
    }

    func testRecordMenuItemsRunTheirActions() {
        var log: [String] = []
        var a = M.RecordActions()
        a.start = { log.append("start") }
        a.stop = { log.append("stop") }
        a.togglePause = { log.append("pause") }
        M.recordMenu(.recording, none, a).forEach { $0.action?() }
        M.recordMenu(.idle, none, a).forEach { $0.action?() }
        XCTAssertEqual(log, ["pause", "stop", "start"])
    }

    func testRecordMenuCarriesTheCustomisedShortcut() {
        var b = ShortcutBindings()
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: KeyCombo.control | KeyCombo.shift)
        b.set(combo, for: .action(.toggleRecording))
        let menu = M.recordMenu(.recording, b, .init())
        XCTAssertEqual(menu.entry(titled: "Stop Recording")?.shortcut, combo)
        XCTAssertEqual(menu.entry(titled: "Pause Recording")?.shortcut,
                       ShortcutAction.togglePause.defaultCombo)
    }

    // Notes, Views and Collapse: icons where the ellipsis menu was

    func testNotesIconIsLitWhileTheNotesBarIsOpen() {
        let closed = M.notesCell(open: false, none), open = M.notesCell(open: true, none)
        XCTAssertEqual(closed.symbol, "note.text")
        XCTAssertFalse(closed.on)
        XCTAssertTrue(closed.help.hasPrefix("Show your notes bar"))
        XCTAssertTrue(open.on)
        XCTAssertEqual(open.help, "Hide your notes bar")
        XCTAssertEqual(open.spoken, "Hide notes")
    }

    func testIconCellsHelpNameTheBoundKey() {
        var b = ShortcutBindings()
        b.set(KeyCombo.controlOptionCommand(kVK_ANSI_M), for: .action(.toggleMeetingBar))
        XCTAssertEqual(M.collapseCell(b).help, "Collapse the bar to a small round button (\u{2303}\u{2325}\u{2318}M)")
        XCTAssertEqual(M.collapseCell(none).spoken, "Collapse to the small button")
        XCTAssertNotEqual(M.collapseCell(none).symbol, "arrow.up.left.and.arrow.down.right")
        XCTAssertTrue(M.viewsCell(none).help.hasPrefix("Meeting views"))
    }

    func testTheCameraCellNamesTheStateAndIsAMenuOfFour() {
        for state in CameraState.allCases {
            let cell = M.cameraStateCell(state)
            XCTAssertTrue(cell.spoken.contains(state.name))
            XCTAssertTrue(cell.help.contains(state.name))
            // Never the eye: that is "Show on my share".
            XCTAssertFalse(cell.symbol.hasPrefix("eye"))
        }
        var picked: [CameraState] = []
        let menu = M.cameraStateMenu(current: .onlyMe, noCameraAllowed: true) { picked.append($0) }
        XCTAssertEqual(menu.filter { $0.kind == .item }.map(\.title), ["Everyone & me", "Only the meeting", "Only me", "Off"])
        XCTAssertEqual(menu.filter(\.checked).map(\.title), ["Only me"])
        menu.filter { $0.kind == .item }[3].action?()
        XCTAssertEqual(picked, [.off])
    }

    // R6, R17 (owner, 2026-11-25): one camera button. A click toggles Everyone and me <-> Off and
    // brings back the last "on" state; the arrow opens the four states. Meeting only, never the saved default.
    func testTheCameraButtonClickTogglesOnAndOffAndKeepsTheLastOnState() {
        XCTAssertEqual(M.cameraClickTarget(current: .everyoneAndMe, lastOn: .everyoneAndMe, noCameraAllowed: true), .off)
        XCTAssertEqual(M.cameraClickTarget(current: .off, lastOn: .everyoneAndMe, noCameraAllowed: true), .everyoneAndMe)
        XCTAssertEqual(M.cameraClickTarget(current: .off, lastOn: .onlyEveryone, noCameraAllowed: true), .onlyEveryone,
                       "Only everyone comes back as Only everyone")
        XCTAssertEqual(M.cameraClickTarget(current: .onlyMe, lastOn: .onlyMe, noCameraAllowed: true), .off)
        // Nothing shared: Off would leave an empty picture, so a click does not turn it off.
        XCTAssertEqual(M.cameraClickTarget(current: .everyoneAndMe, lastOn: .everyoneAndMe, noCameraAllowed: false), .everyoneAndMe)
    }

    func testTheCameraButtonShowsTheStateWithItsNameInTheTooltipAndSpokenLabel() {
        for state in CameraState.allCases {
            let cell = M.cameraStateCell(state)
            XCTAssertEqual(cell.symbol, VisibilitySymbol.camera(state).name)
            XCTAssertEqual(cell.symbolBadge, VisibilitySymbol.camera(state).badge)
            XCTAssertTrue(cell.help.contains(state.name), cell.help)
            XCTAssertTrue(cell.spoken.contains(state.name), cell.spoken)
            XCTAssertTrue(cell.help.contains("Click"), "the click's job is said: \(cell.help)")
        }
        XCTAssertEqual(M.cameraStateCell(.off).symbol, "video.slash")
        XCTAssertEqual(M.cameraStateCell(.everyoneAndMe).symbol, "video.fill")
    }

    func testNoCameraStatesAreOffWhileNothingIsShared() {
        let menu = M.cameraStateMenu(current: .everyoneAndMe, noCameraAllowed: false) { _ in }
        XCTAssertEqual(menu.filter { $0.kind == .item }.map(\.enabled), [true, true, false, false])
    }

    func testSelfViewStartsHiddenAlone() {
        typealias V = SelfViewVisibility
        XCTAssertFalse(V.joinsTogetherHide(.selfView))
        XCTAssertTrue(V.joinsTogetherHide(.activeSpeaker))
        XCTAssertTrue(V.hidden(startsHidden: true, hiddenTogether: false))
        XCTAssertFalse(V.hidden(startsHidden: false, hiddenTogether: false))
        XCTAssertTrue(V.hidden(startsHidden: false, hiddenTogether: true))   // all hidden together
    }

    func testViewsSlotFollowsTheMeetingButton() {
        typealias L = MeetingBarLayout
        XCTAssertEqual(L.cells(videoButtons: true).count - L.cells(videoButtons: false).count, 2)
    }

    // Hover help uses the person's shortcuts

    func testHelpNamesTheBoundKeyNeverAHardcodedOne() {
        XCTAssertEqual(M.help("Mute", .toggleMic, none), "Mute")  // unbound by default
        var b = ShortcutBindings()
        b.set(KeyCombo.controlOptionCommand(kVK_ANSI_M), for: .action(.toggleMic))
        XCTAssertEqual(M.help("Mute", .toggleMic, b), "Mute (\u{2303}\u{2325}\u{2318}M)")
        b.set(KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: KeyCombo.command | KeyCombo.shift), for: .action(.toggleMic))
        XCTAssertEqual(M.help("Mute", .toggleMic, b), "Mute (\u{21E7}\u{2318}J)")
        XCTAssertEqual(M.help("End", .endSession, none), "End (\u{2303}\u{2325}\u{2318}E)")
        XCTAssertEqual(M.help("People", nil, none), "People")
    }

    // Width

    func testWidthIsTheSumOfTheCells() {
        typealias L = MeetingBarLayout
        for video in [true, false] {
            let cells = L.cells(videoButtons: video)
            XCTAssertEqual(L.width(videoButtons: video),
                           L.leadingPad + L.trailingPad + cells.reduce(0, +) + L.spacing * CGFloat(cells.count - 1))
        }
        XCTAssertEqual(L.width(videoButtons: true) - L.width(videoButtons: false),
                       L.meeting + L.icon + 2 * L.spacing)  // Meeting, and the Views icon beside it
        // One camera button (mic + camera + a small arrow) brought the bar back under 720: it was 739 with two cells.
        XCTAssertLessThan(L.width(videoButtons: true), 720)
    }

    func testTheBarHasOneCameraCellAfterTheMic() {
        typealias L = MeetingBarLayout
        let cells = L.cells(videoButtons: false)
        XCTAssertEqual(cells.filter { $0 == L.camera }.count, 1)
        let i = cells.firstIndex(of: L.camera)!
        XCTAssertEqual(cells[i - 1], L.icon, "the mic is just before it")
        XCTAssertEqual(cells[i + 1], L.divider, "no second camera cell after it")
    }

    func testShareCellSitsBesideDrawAndCountsInBothBars() {
        typealias L = MeetingBarLayout
        let cells = L.cells(videoButtons: false)
        XCTAssertEqual(L.present, L.icon)
        XCTAssertEqual(L.draw, L.icon)
        let i = cells.firstIndex(of: L.recCell)! + 2
        XCTAssertEqual(cells[i], L.present)
        XCTAssertEqual(cells[i + 1], L.draw)
        XCTAssertGreaterThan(L.recordOnlyWidth, L.recordOnlyPill + L.pause + L.draw + L.notes + L.present)
    }

    func testRecordCellIsOneWidthInEveryState() {
        XCTAssertEqual(MeetingBarLayout.recCell, MeetingBarLayout.recPill + MeetingBarLayout.pause)
    }

    // End says what it does

    func testEndPromptUsesTheCloseWindowWords() {
        var s = LiveExitState(); s.kind = .host; s.isRecording = true
        let host = LiveExit.endPrompt(s)
        XCTAssertEqual(host?.choices, [.endMeetingForAll, .cancel])
        XCTAssertTrue(host?.message.contains("Recording will stop") ?? false)
        s.kind = .participant
        XCTAssertEqual(LiveExit.endPrompt(s)?.choices, [.leaveMeeting, .cancel])
        s.kind = .recordOnly
        XCTAssertNil(LiveExit.endPrompt(s))
        XCTAssertNil(LiveExit.endPrompt(LiveExitState()))
    }
}
