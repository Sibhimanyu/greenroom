import XCTest
@testable import GreenroomTests

final class MenuBarModelTests: XCTestCase {
    private let bindings = ShortcutBindings()

    private func build(_ s: MenuBarState = MenuBarState(), problems: [MenuBarProblem] = [],
                       last: MenuBarLastSession? = nil, bindings: ShortcutBindings? = nil) -> [MenuBarItem] {
        MenuBarModel.items(state: s, problems: problems, lastSession: last, shortcuts: bindings ?? self.bindings)
    }
    private func actions(_ items: [MenuBarItem]) -> [MenuBarAction] { items.compactMap(\.action) }
    private func live(_ edit: (inout MenuBarState) -> Void = { _ in }) -> MenuBarState {
        var s = MenuBarState(); s.isLive = true; s.className = "Maths 7"; s.sessionElapsed = 754
        s.layoutLocked = true; s.layoutName = "Side by side"; edit(&s); return s
    }

    // Idle

    func testIdleReadyHeaderAndItems() {
        var s = MenuBarState(); s.layoutName = "None"
        let items = build(s)
        XCTAssertEqual(items.first?.kind, .status)
        XCTAssertEqual(items.first?.title, "Greenroom \u{00B7} Ready")
        XCTAssertFalse(items.first!.attention)
        XCTAssertEqual(actions(items), [.newMeeting, .joinMeeting, .record, .sessions, .showGreenroom,
                                        .settings, .checkForUpdates, .howItWorks, .quit])
        XCTAssertTrue(items.contains { $0.kind == .layoutMenu && $0.title == "Layout: None" })
    }

    func testIdleHidesEverySessionControl() {
        let a = actions(build())
        for gone: MenuBarAction in [.endSession, .toggleRecording, .togglePause, .toggleNotes,
                                    .snapBack, .toggleSpeakerTile, .toggleDrawing] {
            XCTAssertFalse(a.contains(gone), "\(gone) should be hidden when idle")
        }
    }

    func testNeedsAttentionListsProblemsRightUnderHeader() {
        let p = [MenuBarProblem(fix: .zoomSettings, text: "Zoom: add credentials"),
                 MenuBarProblem(fix: .micPrivacy, text: "Mic: not allowed")]
        let items = build(problems: p)
        XCTAssertEqual(items[0].title, "Greenroom \u{00B7} Needs attention")
        XCTAssertTrue(items[0].attention)
        XCTAssertEqual(items[1].action, .fix(.zoomSettings))
        XCTAssertEqual(items[2].action, .fix(.micPrivacy))
        XCTAssertEqual(items[2].title, "Mic: not allowed")
    }

    func testLastSessionShownOnlyWhenThereIsOne() {
        XCTAssertFalse(actions(build()).contains(.openLastSession))
        let last = MenuBarLastSession(path: "/x", title: "Maths 7", length: "48 min")
        XCTAssertEqual(build(last: last).first { $0.action == .openLastSession }?.title,
                       "Last: Maths 7 \u{00B7} 48 min")
        let noLen = build(last: MenuBarLastSession(path: "/x", title: "Maths 7", length: nil))
        XCTAssertEqual(noLen.first { $0.action == .openLastSession }?.title, "Last: Maths 7")
    }

    func testShortcutsComeFromCustomBindings() {
        let custom = KeyCombo.optionCommand(0)
        var b = ShortcutBindings()
        b.set(custom, for: .action(.startClass))
        XCTAssertEqual(build(bindings: b).first { $0.action == .newMeeting }?.shortcut, custom)
        XCTAssertEqual(build().first { $0.action == .newMeeting }?.shortcut,
                       bindings.combo(for: .action(.startClass)))
        b.clear(.action(.openSessions))
        XCTAssertNil(build(bindings: b).first { $0.action == .sessions }?.shortcut)
    }

    func testSettingsHasCommandComma() {
        let item = build().first { $0.action == .settings }
        XCTAssertEqual(item?.shortcut, MenuBarModel.settingsCombo)
        XCTAssertEqual(item?.shortcut?.glyphs, "\u{2318},")
    }

    // Live

    func testLiveHeaderShowsClassAndElapsed() {
        let items = build(live())
        XCTAssertEqual(items.first?.title, "\u{25CF} Live \u{00B7} Maths 7 \u{00B7} 12:34")
        // Clickable: it brings the meeting forward.
        XCTAssertEqual(items.first?.kind, .action(.showMeeting))
    }

    func testLiveWithoutNameOmitsIt() {
        XCTAssertEqual(build(live { $0.className = " " }).first?.title, "\u{25CF} Live \u{00B7} 12:34")
    }

    func testNotRecordingOffersStart() {
        let items = build(live())
        XCTAssertFalse(actions(items).contains(.togglePause))
        XCTAssertEqual(items.first { $0.action == .toggleRecording }?.title, "Start Recording")
    }

    func testRecordingShowsHeaderPauseAndStop() {
        let items = build(live { $0.isRecording = true; $0.recordingElapsed = 65 })
        XCTAssertEqual(items[1].title, "\u{25CF} Recording 1:05")
        XCTAssertEqual(items.first { $0.action == .togglePause }?.title, "Pause Recording")
        XCTAssertEqual(items.first { $0.action == .toggleRecording }?.title, "Stop Recording")
    }

    func testPausedShowsResumeAndPausedHeader() {
        let items = build(live { $0.isRecording = true; $0.isPaused = true; $0.recordingElapsed = 65 })
        XCTAssertEqual(items[1].title, "\u{25CF} Recording 1:05 \u{00B7} Paused")
        XCTAssertEqual(items.first { $0.action == .togglePause }?.title, "Resume Recording")
    }

    func testSavingHidesRecordingControls() {
        let a = actions(build(live { $0.isSavingRecording = true }))
        XCTAssertFalse(a.contains(.toggleRecording))
        XCTAssertFalse(a.contains(.togglePause))
    }

    func testLiveItemsAndOrder() {
        let a = actions(build(live { $0.canDraw = true }))
        XCTAssertEqual(a, [.showMeeting, .toggleRecording, .toggleNotes, .snapBack, .toggleSpeakerTile, .toggleDrawing,
                           .endSession, .showGreenroom, .quit])
    }

    func testLayoutToolsHiddenWhenSessionArrangesNothing() {
        let a = actions(build(live { $0.layoutToolsAvailable = false }))
        XCTAssertFalse(a.contains(.snapBack))
        XCTAssertFalse(a.contains(.toggleSpeakerTile))
    }

    func testLayoutSubmenuHiddenWhileLockedShownWhenNot() {
        XCTAssertFalse(build(live()).contains { $0.kind == .layoutMenu })
        XCTAssertTrue(build(live { $0.layoutLocked = false }).contains { $0.kind == .layoutMenu })
    }

    func testDrawingHiddenWhenNothingShared() {
        XCTAssertFalse(actions(build(live())).contains(.toggleDrawing))
        XCTAssertEqual(build(live { $0.isDrawing = true }).first { $0.action == .toggleDrawing }?.title,
                       "Stop Drawing")
    }

    func testEndSessionIsDestructiveAndNearBottom() {
        let items = build(live())
        let end = items.firstIndex { $0.action == .endSession }!
        XCTAssertTrue(items[end].destructive)
        XCTAssertNotNil(items[end].shortcut)
        XCTAssertGreaterThan(end, items.count - 6)
    }

    func testStoppingHidesEndSession() {
        let items = build(live { $0.isStopping = true })
        XCTAssertEqual(items.first?.title, "Ending\u{2026}")
        XCTAssertFalse(actions(items).contains(.endSession))
    }

    func testStartingShowsEndButNotRecord() {
        var s = MenuBarState(); s.isStarting = true; s.layoutLocked = true
        let items = build(s)
        XCTAssertEqual(items.first?.title, "Starting\u{2026}")
        XCTAssertTrue(actions(items).contains(.endSession))
        XCTAssertFalse(actions(items).contains(.toggleRecording))
    }

    func testCuesAndUploadAppearOnlyWhenActive() {
        XCTAssertFalse(actions(build(live())).contains(.stopCues))
        let items = build(live { $0.cuesListening = true; $0.cuesStatusText = "Listening"; $0.uploadProgress = 0.42 })
        XCTAssertTrue(actions(items).contains(.stopCues))
        XCTAssertTrue(items.contains { $0.title == "Uploading to YouTube \u{00B7} 42%" })
    }

    // Rules

    func testStatusItemsAreNeverActions_andNoStrayDividers() {
        let cases: [[MenuBarItem]] = [
            build(), build(problems: [MenuBarProblem(fix: .screenPrivacy, text: "Screen: permission needed")]),
            build(live()), build(live { $0.isRecording = true; $0.canDraw = true; $0.layoutLocked = false }),
            build(live { $0.isSavingRecording = true; $0.layoutToolsAvailable = false }),
            build(live { $0.isStopping = true }),
        ]
        for items in cases {
            XCTAssertFalse(items.first!.isSeparator)
            XCTAssertFalse(items.last!.isSeparator)
            for (a, b) in zip(items, items.dropFirst()) {
                XCTAssertFalse(a.isSeparator && b.isSeparator, "adjacent dividers")
            }
            for i in items where i.kind == .status { XCTAssertNil(i.action) }
        }
    }

    func testEveryExistingActionReachableWhereItApplies() {
        let idle = actions(build())
        let liveRec = actions(build(live { $0.isRecording = true; $0.canDraw = true }))
        for a: MenuBarAction in [.showGreenroom, .checkForUpdates, .howItWorks, .quit] { XCTAssertTrue(idle.contains(a)) }
        for a: MenuBarAction in [.endSession, .toggleRecording, .togglePause, .toggleNotes, .snapBack,
                                 .toggleSpeakerTile, .toggleDrawing, .showGreenroom, .quit] {
            XCTAssertTrue(liveRec.contains(a))
        }
    }

    func testClock() {
        XCTAssertEqual(MenuBarModel.clock(0), "0:00")
        XCTAssertEqual(MenuBarModel.clock(3729), "1:02:09")
        XCTAssertEqual(MenuBarModel.clock(-5), "0:00")
    }
}
