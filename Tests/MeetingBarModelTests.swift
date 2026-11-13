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
        XCTAssertEqual(p.help, "Recording 1:29 \u{00B7} class 1:38")
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

    func testNotRecordingPillHasNoTimerAndNoDot() {
        let p = M.recordPill(.idle, classSeconds: 98, recordingSeconds: 0)
        XCTAssertEqual(p.label, "Not recording")
        XCTAssertNil(p.time)
        XCTAssertFalse(p.showsDot)
        XCTAssertTrue(p.hasMenu)
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

    // The More menu

    func testMoreMenuKeepsNotesAndCollapseAlways() {
        let t = titles(M.moreMenu(.init(), views: [], layouts: [], none, .init()))
        XCTAssertEqual(t, ["Show Notes", "Collapse to Small Button"])
    }

    func testMoreMenuHoldsViewsAndLayoutWhenThereAreSome() {
        var s = M.MoreState()
        s.notesOpen = true; s.hasViews = true; s.hasLayouts = true
        let menu = M.moreMenu(s, views: [.item("Gallery") {}], layouts: [.item("Side by side") {}], none, .init())
        XCTAssertEqual(titles(menu).first, "Hide Notes")
        XCTAssertEqual(menu.flatTitles, ["Hide Notes", "Meeting Views", "Gallery", "Layout", "Side by side",
                                         "Collapse to Small Button"])
    }

    // Hover help uses the person's shortcuts

    func testHelpNamesTheBoundKeyNeverAHardcodedOne() {
        XCTAssertEqual(M.help("Mute", .toggleMic, none), "Mute")  // unbound by default
        var b = ShortcutBindings()
        b.set(KeyCombo.optionCommand(kVK_ANSI_M), for: .action(.toggleMic))
        XCTAssertEqual(M.help("Mute", .toggleMic, b), "Mute (\u{2325}\u{2318}M)")
        b.set(KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: KeyCombo.command | KeyCombo.shift), for: .action(.toggleMic))
        XCTAssertEqual(M.help("Mute", .toggleMic, b), "Mute (\u{21E7}\u{2318}J)")
        XCTAssertEqual(M.help("End", .endSession, none), "End (\u{2325}\u{2318}X)")
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
        XCTAssertEqual(L.width(videoButtons: true) - L.width(videoButtons: false), L.meeting + L.spacing)
        XCTAssertLessThan(L.width(videoButtons: true), 720)
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
