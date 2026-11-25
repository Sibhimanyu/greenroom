import XCTest

/// The Room screen piece: codec, where it may be added, the palette's reasons,
/// where it is placed and which source feeds it.
final class RoomScreenTests: XCTestCase {
    private let room = LayoutPiece.Kind.roomScreen
    private let meeting = LayoutPiece.Kind.meeting(fillsDisplay: false, startsHidden: false)
    private let main = LayoutScreen(id: "MAIN", name: "Built-in", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), isMain: true)
    private let second = LayoutScreen(id: "SECOND", name: "Projector", visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), isMain: false)

    private func piece(_ kind: LayoutPiece.Kind) -> LayoutPiece { LayoutPiece(kind: kind, rect: .full) }
    private func twoDisplay(second pieces: [LayoutPiece] = [], main mainPieces: [LayoutPiece] = []) -> LayoutTemplate {
        LayoutTemplate(name: "T", oneDisplay: mainPieces, twoDisplays: TwoDisplay(second: pieces))
    }

    // MARK: Codec

    func testRoundTripAndShape() throws {
        let p = piece(room)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(LayoutPiece.self, from: data), p)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kind = try XCTUnwrap(json["kind"] as? [String: Any])
        XCTAssertEqual(kind["type"] as? String, "roomScreen")
    }

    func testTemplateRoundTripKeepsIt() throws {
        let t = twoDisplay(second: [piece(room)])
        let back = try JSONDecoder().decode(LayoutTemplate.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.twoDisplays?.second.first?.kind, room)
    }

    /// An older build has no such case: its decoder throws on the type and the
    /// lossy array drops just that piece. The same path drops any unknown type.
    func testUnknownTypeIsSkippedNotFatal() throws {
        let good = String(data: try JSONEncoder().encode(piece(.chat)), encoding: .utf8)!
        let json = """
        {"name":"T","oneDisplay":[{"kind":{"type":"futureThing"},"rect":{"x":0,"y":0,"w":1,"h":1}},\(good)]}
        """
        let t = try JSONDecoder().decode(LayoutTemplate.self, from: Data(json.utf8))
        XCTAssertEqual(t.oneDisplay.map(\.kind), [.chat])
    }

    func testDefaultsAndLooks() {
        XCTAssertFalse(piece(room).offersShareSwitch)
        XCTAssertTrue(room.isRoomScreen)
        let cells = LayoutGeometry.defaultCells(for: room)
        XCTAssertEqual(cells.cols, LayoutGeometry.divisions)
        XCTAssertEqual(cells.rows, LayoutGeometry.divisions)
        XCTAssertEqual(RoomScreenRules.title, "Room screen")
        XCTAssertEqual(RoomScreenRules.hint, "What the meeting sees, for a screen in the room")
    }

    // MARK: canAdd

    func testOnlyTheSecondSlotOfATwoDisplayVersion() {
        let t = twoDisplay()
        XCTAssertTrue(t.canAdd(room, to: .second))
        XCTAssertFalse(t.canAdd(room, to: .main))
    }

    func testAtMostOnePerVersion() {
        let t = twoDisplay(second: [piece(room)])
        XCTAssertFalse(t.canAdd(room, to: .second))
    }

    func testDoesNotDisturbOtherPieces() {
        let t = twoDisplay(second: [piece(room)], main: [piece(meeting)])
        XCTAssertFalse(t.canAdd(meeting, to: .second))   // the Meeting limit still counts across the pair
        XCTAssertTrue(t.canAdd(.chat, to: .main))
    }

    // MARK: Palette

    func testPaletteReasons() {
        XCTAssertNil(RoomScreenRules.blockReason(slot: .second, existing: [], hasSecondDisplay: true))
        XCTAssertEqual(RoomScreenRules.blockReason(slot: .second, existing: [room], hasSecondDisplay: true), "Already in this layout")
        let one = RoomScreenRules.blockReason(slot: .main, existing: [], hasSecondDisplay: false)
        XCTAssertTrue(one?.contains("second display") == true)
        XCTAssertTrue(one?.contains("extended, not mirrored") == true)
        XCTAssertNotNil(RoomScreenRules.blockReason(slot: .main, existing: [], hasSecondDisplay: false))
    }

    // R31.4: with a second display the reason is where the Room screen goes, not "add a second display".
    func testMainWithASecondDisplayTellsWhereTheRoomScreenGoes() {
        XCTAssertEqual(RoomScreenRules.blockReason(slot: .main, existing: [], hasSecondDisplay: true),
                       "The Room screen goes on the second display")
    }

    // MARK: Placement

    func testPlacedOnTheSecondDisplayOnly() {
        let t = twoDisplay(second: [piece(room)])
        let two = LayoutResolver.resolve(t, screens: [main, second], primaryHeight: 875)
        XCTAssertEqual(two.roomScreen?.screen.id, "SECOND")
        XCTAssertEqual(two.roomScreen?.frames.ns, CGRect(x: 1440, y: 0, width: 1920, height: 1080))
    }

    func testMirroredOrUnpluggedPlacesNothing() {
        // Mirrored: the OS shows one display, so the one-display version is used.
        let t = twoDisplay(second: [piece(room)])
        XCTAssertNil(LayoutResolver.resolve(t, screens: [main], primaryHeight: 875).roomScreen)
    }

    func testARoomScreenInAOneDisplayVersionNeverShows() {
        // Reached only by editing a file by hand: it would show itself.
        let t = LayoutTemplate(name: "T", oneDisplay: [piece(room)])
        XCTAssertNil(LayoutResolver.resolve(t, screens: [main, second], primaryHeight: 875).roomScreen)
    }

    // MARK: Source

    func testSourceFollowsTheCompositor() {
        XCTAssertEqual(RoomScreenRules.source(compositorRunning: true), .compositor)
        XCTAssertEqual(RoomScreenRules.source(compositorRunning: false), .ownDisplay)
    }

    func testCaptureDisplayNeverTheRoomDisplay() {
        XCTAssertEqual(RoomScreenRules.captureDisplay(preferred: "A", roomDisplay: "B", main: "M"), "A")
        XCTAssertEqual(RoomScreenRules.captureDisplay(preferred: "B", roomDisplay: "B", main: "M"), "M")
        XCTAssertEqual(RoomScreenRules.captureDisplay(preferred: "", roomDisplay: "B", main: "M"), "M")
    }

    func testStreamSizeIsTheRoomDisplaysPixels() {
        XCTAssertEqual(RoomScreenRules.streamSize(roomPoints: CGSize(width: 1920, height: 1080), scale: 2),
                       CGSize(width: 3840, height: 2160))
    }

    func testTheLayoutsHideNeverHidesTheRoomScreen() {
        XCTAssertFalse(RoomScreenRules.isHidden(layoutHidden: true))
        XCTAssertFalse(RoomScreenRules.isHidden(layoutHidden: false))
    }

    // Owner bug list R14: Greenroom's own capture still never films the Room screen: it is fixed off
    // in the one rule for every share, and the exception list only holds registered windows.
    func testRoomScreenIsNeverInGreenroomsOwnCapture() {
        let piece = LayoutPiece(kind: .roomScreen, rect: .full)
        for target: Visibility.Target in [.wholeScreen, .whiteboard, .justMe, .window(bundleID: "com.apple.Safari")] {
            XCTAssertFalse(Visibility.everyoneSees(piece: piece, target: target).isOn, "\(target)")
        }
        XCTAssertFalse(ShareableWindow.allCases.map { "\($0)".lowercased() }.contains { $0.contains("room") })
        XCTAssertEqual(ShowOnShare.exceptionIDs(kind: .display, registry: [3], alwaysShared: [7]), [3, 7])
    }

    // MARK: Fills the whole display (owner bug list, Room screen item)

    func testFullRectIsFullDisplayAndSmallerIsNot() {
        XCTAssertTrue(RoomScreenRules.isFullDisplay(.full))
        XCTAssertTrue(RoomScreenRules.isFullDisplay(UnitRect(x: 0.001, y: 0, w: 0.999, h: 1)))
        XCTAssertFalse(RoomScreenRules.isFullDisplay(UnitRect(x: 0, y: 0, w: 1, h: 0.9)))
        XCTAssertFalse(RoomScreenRules.isFullDisplay(UnitRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5)))
    }

    func testFullPieceTakesTheWholeScreenFrameNotTheVisibleFrame() {
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 1440, y: 0, width: 1920, height: 1055)   // menu bar strip left out
        XCTAssertEqual(RoomScreenRules.windowFrame(pieceFrame: visible, rect: .full, screenFrame: screen), screen)
    }

    func testSmallerPieceKeepsItsOwnFrame() {
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let piece = CGRect(x: 1500, y: 100, width: 800, height: 450)
        XCTAssertEqual(RoomScreenRules.windowFrame(pieceFrame: piece, rect: UnitRect(x: 0.1, y: 0.1, w: 0.4, h: 0.4), screenFrame: screen), piece)
    }
}
