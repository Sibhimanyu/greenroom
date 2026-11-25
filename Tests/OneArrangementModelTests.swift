import XCTest

/// ADR 0002: the model (R25), built-ins (R28) and editor rules (R29, R30).
final class OneArrangementModelTests: XCTestCase {
    private let browser = LayoutPiece(kind: .app(AppPiece(bundleID: "com.example.browser")), rect: UnitRect(x: 0, y: 0, w: 0.75, h: 1))
    private let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0.75, y: 0, w: 0.25, h: 1))
    private let meeting = LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)

    private func withSecond(main: [LayoutPiece], second: [LayoutPiece]) -> LayoutTemplate {
        var t = LayoutTemplate(name: "T", oneDisplay: main)
        t.addSecondDisplay()
        t.setPieces(second, for: .second)
        return t
    }

    // MARK: R25

    // R25.2
    func testPieceCountAndPlacedPiecesWalkMainAndSecondOnce() {
        let t = withSecond(main: [browser, chat], second: [meeting])
        XCTAssertEqual(t.pieceCount, 3)
        XCTAssertEqual(t.placedPieces.map(\.piece.id), [browser.id, chat.id, meeting.id])
        XCTAssertEqual(t.placedPieces.map(\.slot), [.main, .main, .second])
        XCTAssertEqual(t.pieces(for: .main), [browser, chat])
        XCTAssertEqual(LayoutTemplate(name: "Alone", oneDisplay: [chat]).pieces(for: .second), [])
    }

    // R25.1: the file has no twoDisplays.main any more.
    func testAnEncodedLayoutHasNoTwoDisplayMain() throws {
        let t = withSecond(main: [browser], second: [meeting])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
        let two = try XCTUnwrap(json["twoDisplays"] as? [String: Any])
        XCTAssertNil(two["main"])
        XCTAssertNotNil(two["second"])
        XCTAssertNotNil(json["oneDisplay"], "the main arrangement keeps its saved key")
    }

    // R25.4
    func testAnOldFileLoadsWithMainFromOneDisplayAndTheOldTwoDisplayMainKeptForMigration() throws {
        let old = LegacyFile.template(name: "Old", oneDisplay: [browser, chat], oldMain: [browser], second: [meeting])
        let t = try JSONDecoder().decode(LayoutTemplate.self, from: old)
        XCTAssertEqual(t.pieces(for: .main), [browser, chat])
        XCTAssertEqual(t.pieces(for: .second), [meeting])
        XCTAssertEqual(t.twoDisplays?.legacyMain, [browser])
        let again = try JSONDecoder().decode(LayoutTemplate.self, from: JSONEncoder().encode(t))
        XCTAssertNil(again.twoDisplays?.legacyMain, "read for the migration, never written")
    }

    // R25.3
    func testAddingASecondDisplayAddsAnEmptyOneAndMovesNothing() {
        var t = LayoutTemplate(name: "T", oneDisplay: [browser, chat])
        t.addSecondDisplay()
        XCTAssertEqual(t.pieces(for: .main), [browser, chat])
        XCTAssertEqual(t.pieces(for: .second), [])
        XCTAssertNotNil(t.twoDisplays)
        let before = t
        t.addSecondDisplay()
        XCTAssertEqual(t, before, "adding twice changes nothing")
    }

    // R25.3
    func testRemovingTheSecondDisplayDropsItWithItsPiecesAndKeepsMain() {
        var t = withSecond(main: [browser], second: [meeting])
        t.removeSecondDisplay()
        XCTAssertNil(t.twoDisplays)
        XCTAssertEqual(t.pieces(for: .main), [browser])
        XCTAssertEqual(t.pieceCount, 1)
        t.removeSecondDisplay()
        XCTAssertNil(t.twoDisplays)
    }

    // R25.5
    func testMeetingAndChatLimitsCountAcrossBothArrangements() {
        let t = withSecond(main: [browser, chat], second: [meeting])
        XCTAssertFalse(t.canAdd(.chat, to: .second), "one Chat, on either display")
        XCTAssertFalse(t.canAdd(.meeting(fillsDisplay: false, startsHidden: false), to: .main), "one Meeting, on either display")
        XCTAssertTrue(t.canAdd(.app(AppPiece(bundleID: "com.example.other")), to: .second))
    }

    // R25.2: the Meeting-starts-hidden flag and the app swap reach the second arrangement too.
    func testTemplateWideEditsReachBothArrangements() {
        var t = withSecond(main: [browser, chat], second: [meeting])
        t.setMeetingStartsHidden(true)
        XCTAssertEqual(t.meetingStartsHidden, true)
        t.replaceApp("com.example.browser", with: "com.example.new")
        XCTAssertEqual(t.firstAppBundleID, "com.example.new")
    }

    // MARK: R28

    // R28.1
    func testRajSanModeIsBrowserSpeakerAndChatOnMainAndAFullMeetingOnSecond() throws {
        let raj = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.rajMode))
        let main = raj.pieces(for: .main)
        XCTAssertEqual(main.count, 3)
        XCTAssertNotNil(main[0].kind.app)
        XCTAssertEqual(main[0].rect, UnitRect(x: 0, y: 0, w: 0.75, h: 1))
        XCTAssertEqual(main[1].kind.view, .activeSpeaker)
        XCTAssertEqual(main[1].rect, UnitRect(x: 0.75, y: 0, w: 0.25, h: 5.0 / 12))
        XCTAssertTrue(main[2].kind.isChat)
        XCTAssertEqual(main[2].rect, UnitRect(x: 0.75, y: 5.0 / 12, w: 0.25, h: 1 - 5.0 / 12))
        XCTAssertEqual(raj.pieces(for: .second).count, 1)
        guard case .meeting(true, _) = raj.pieces(for: .second)[0].kind else { return XCTFail("a full-display Meeting") }
        XCTAssertEqual(LayoutLibrary.description(forStarter: LayoutLibrary.rajMode),
                       "The browser with the speaker and chat beside it. With a second display, the meeting fills it.")
    }

    // R28.1: the owner uses Raj San Mode on the laptop alone, so a meeting surface must appear there.
    func testRajSanModeOnTheLaptopAloneStillPlacesAMeetingSurface() throws {
        let raj = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.rajMode))
        let screen = LayoutScreen(id: "MAIN", name: "Built-in", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), isMain: true)
        let withViews = LayoutResolver.resolve(raj, screens: [screen], primaryHeight: 900)
        XCTAssertFalse(withViews.views.isEmpty, "the Active speaker view is the surface")
        let zoomUI = LayoutResolver.substitutingMeetingForActiveSpeaker(raj, viewsCanOpen: false, secondConnected: false)
        XCTAssertNotNil(LayoutResolver.resolve(zoomUI, screens: [screen], primaryHeight: 900).meeting)
    }

    // R28.1: an Active speaker on main may sit beside the Meeting on second (views count per version).
    func testActiveSpeakerOnMainIsAllowedBesideAMeetingOnSecond() throws {
        let raj = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.rajMode))
        var noSpeaker = raj
        noSpeaker.setPieces(raj.pieces(for: .main).filter { $0.kind.view != .activeSpeaker }, for: .main)
        XCTAssertTrue(noSpeaker.canAdd(.view(.activeSpeaker, startsHidden: false), to: .main))
    }

    // R28.2
    func testRoomPlusLaptopIsBrowserAndChatOnMainAndTheRoomScreenOnSecond() throws {
        let room = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.roomLaptop))
        XCTAssertEqual(room.pieces(for: .main).count, 2)
        XCTAssertEqual(room.pieces(for: .second).map(\.kind.isRoomScreen), [true])
        XCTAssertEqual(room.twoDisplays?.sharedSlot, .main)
    }

    // R28.3
    func testTheOtherFourBuiltInsHaveOnlyAMainArrangement() {
        for key in [LayoutLibrary.teachFromBrowser, LayoutLibrary.talkToMeeting, LayoutLibrary.present, LayoutLibrary.leaveAlone] {
            XCTAssertNil(LayoutLibrary.shipped(key)?.twoDisplays, key)
        }
    }

    // R28.4
    func testIsAsShippedComparesBothArrangements() throws {
        var raj = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.rajMode))
        XCTAssertTrue(raj.isAsShipped)
        raj.setPieces([], for: .second)
        XCTAssertFalse(raj.isAsShipped, "second changed")
        raj = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.rajMode))
        raj.removeSecondDisplay()
        XCTAssertFalse(raj.isAsShipped, "second removed")
    }

    // MARK: R29, R30

    // R32.2: editing the saved layout mid-meeting must not move the shared display; only Apply now does.
    func testARunningMeetingKeepsItsSharedDisplayWhenTheSavedLayoutIsEdited() {
        var running = LayoutTemplate(name: "x", oneDisplay: [], camera: LayoutCamera(), share: ShareTarget())
        running.addSecondDisplay()
        var edited = running
        edited.twoDisplays?.sharedSlot = .second
        edited.setPieces([LayoutPiece(kind: .chat, rect: .full)], for: .main)
        let adopted = running.adoptingEdit(edited)
        XCTAssertEqual(adopted.effectiveSharedSlot, .main, "the live shared display waits for Apply now")
        XCTAssertEqual(adopted.oneDisplay.count, 1, "the edit to the pieces still reaches the running meeting")
        XCTAssertEqual(edited.twoDisplays?.sharedSlot, .second, "the saved layout keeps the pick")
    }

    // R29.3: the strip also shows on Leave my windows alone; clicking it forks (like +) and adds the second there.
    func testTheStripOnLeaveMyWindowsAloneForksThenAddsTheSecond() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.builtIns())
        lib.activeID = lib.leaveAloneID
        let before = lib.templates.count
        let id = try XCTUnwrap(lib.addSecondDisplayToActive())
        XCTAssertEqual(lib.templates.count, before + 1)
        XCTAssertEqual(lib.activeID, id)
        XCTAssertNotNil(lib.template(id: id)?.twoDisplays)
        XCTAssertNil(lib.template(id: id)?.starter)
        XCTAssertNil(lib.templates.first { $0.starter == LayoutLibrary.leaveAlone }?.twoDisplays, "the built-in stays clean")
    }

    func testTheStripOnAnyOtherLayoutAddsTheSecondInPlace() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.builtIns())
        let teach = try XCTUnwrap(lib.templates.first { $0.starter == LayoutLibrary.teachFromBrowser })
        lib.activeID = teach.id
        let before = lib.templates.count
        XCTAssertEqual(lib.addSecondDisplayToActive(), teach.id)
        XCTAssertEqual(lib.templates.count, before)
        XCTAssertNotNil(lib.template(id: teach.id)?.twoDisplays)
    }

    // R29.3
    func testTheDashedStripShowsOnlyWithoutASecondDisplay() {
        XCTAssertTrue(LayoutEditorRules.showsAddSecondStrip(hasSecondDisplay: false))
        XCTAssertFalse(LayoutEditorRules.showsAddSecondStrip(hasSecondDisplay: true))
        XCTAssertEqual(LayoutEditorRules.addSecondTooltip, "Add a second display")
    }

    // R29.4
    func testWithASecondBothCanvasesShareTheWidthAtOneHeight() throws {
        let w = LayoutEditorRules.canvasWidths(panelWidth: 700, gap: 12, mainAspect: 16.0 / 10, secondAspect: 16.0 / 9)
        let second = w.second
        XCTAssertEqual(w.main + 12 + second, 700, accuracy: 0.001)
        XCTAssertEqual(w.main / (16.0 / 10), second / (16.0 / 9), accuracy: 0.001, "same height")
        XCTAssertGreaterThan(w.main, 100)
        XCTAssertGreaterThan(second, 100)
    }

    // R29.4: the bezel's own padding is not part of the picture, so the pictures, not the frames, share one height.
    func testWithASecondTheDrawnDisplaysShareOneHeightAfterThePadding() throws {
        let w = LayoutEditorRules.canvasWidths(panelWidth: 700, gap: 12, mainAspect: 16.0 / 10, secondAspect: 16.0 / 9,
                                               inset: 8)
        let second = w.second
        XCTAssertEqual(w.main + 12 + second, 700, accuracy: 0.001)
        XCTAssertEqual((w.main - 16) / (16.0 / 10), (second - 16) / (16.0 / 9), accuracy: 0.001)
    }

    // R30.1
    func testTheSecondMenuSaysRemoveSecondDisplay() {
        XCTAssertEqual(LayoutEditorRules.removeSecondTitle, "Remove second display")
    }

    // R30.2
    func testRemovingAsksOnlyWhenTheSecondHasPieces() {
        XCTAssertFalse(LayoutEditorRules.removeSecondNeedsConfirmation(secondPieceCount: 0))
        XCTAssertTrue(LayoutEditorRules.removeSecondNeedsConfirmation(secondPieceCount: 1))
    }

    // R30.4: undo or redo leaves the editor on a canvas that exists.
    func testAfterRemovingTheSecondTheActiveCanvasIsMain() {
        let t = LayoutTemplate(name: "T", oneDisplay: [chat])
        let r = LayoutEditorRules.reconciled(.init(activeSlot: .second, selection: nil), in: t, cameraID: UUID())
        XCTAssertEqual(r.activeSlot, .main)
        let two = withSecond(main: [chat], second: [])
        XCTAssertEqual(LayoutEditorRules.reconciled(.init(activeSlot: .second, selection: nil), in: two, cameraID: UUID()).activeSlot, .second)
    }
}

/// An old file as a previous build wrote it: `twoDisplays.main` is in it.
enum LegacyFile {
    static func pieces(_ pieces: [LayoutPiece]) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(pieces))) ?? []
    }

    /// A template's JSON with `twoDisplays.main` = `oldMain` (nil: no two-display version at all).
    static func templateObject(_ t: LayoutTemplate, oldMain: [LayoutPiece]?) -> [String: Any] {
        var o = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(t))) as? [String: Any] ?? [:]
        if let oldMain {
            var two = o["twoDisplays"] as? [String: Any] ?? [:]
            two["main"] = pieces(oldMain)
            if two["second"] == nil { two["second"] = [] }
            o["twoDisplays"] = two
        } else {
            o["twoDisplays"] = nil
        }
        return o
    }

    static func template(name: String, oneDisplay: [LayoutPiece], oldMain: [LayoutPiece], second: [LayoutPiece]) -> Data {
        var t = LayoutTemplate(name: name, oneDisplay: oneDisplay)
        t.addSecondDisplay()
        t.setPieces(second, for: .second)
        return (try? JSONSerialization.data(withJSONObject: templateObject(t, oldMain: oldMain))) ?? Data()
    }

    /// The library file of an old install.
    static func library(_ entries: [(LayoutTemplate, oldMain: [LayoutPiece]?)], activeID: UUID?) -> Data {
        var o: [String: Any] = ["version": 1, "templates": entries.map { templateObject($0.0, oldMain: $0.oldMain) }]
        if let activeID { o["activeID"] = activeID.uuidString }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }
}
