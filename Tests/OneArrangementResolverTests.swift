import XCTest
import CoreGraphics

/// ADR 0002: one arrangement per display. The runtime rule (R26).
final class OneArrangementResolverTests: XCTestCase {
    private let main = LayoutScreen(id: "MAIN", name: "Built-in", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), isMain: true)
    private let second = LayoutScreen(id: "SECOND", name: "Projector", visibleFrame: CGRect(x: 1440, y: 100, width: 1920, height: 1050), isMain: false)
    private let primaryHeight: CGFloat = 900

    private let app = LayoutPiece(kind: .app(AppPiece(bundleID: "com.example.app")), rect: UnitRect(x: 0, y: 0, w: 0.5, h: 1))
    private let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 1))
    private let roomApp = LayoutPiece(kind: .app(AppPiece(bundleID: "com.example.second")), rect: .full)
    private let meeting = LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)

    private func layout(main mainPieces: [LayoutPiece], second secondPieces: [LayoutPiece]?) -> LayoutTemplate {
        var t = LayoutTemplate(name: "T", oneDisplay: mainPieces)
        if let secondPieces { t.addSecondDisplay(); t.setPieces(secondPieces, for: .second) }
        return t
    }

    // R26.2
    func testTwoConnectedPlacesMainOnMainAndSecondOnSecond() {
        let r = LayoutResolver.resolve(layout(main: [app, chat], second: [roomApp]), screens: [main, second], primaryHeight: primaryHeight)
        XCTAssertEqual(r.variant, .twoDisplays)
        XCTAssertEqual(r.placed.filter { $0.screen.id == "MAIN" }.map(\.piece.id), [app.id, chat.id])
        XCTAssertEqual(r.placed.filter { $0.screen.id == "SECOND" }.map(\.piece.id), [roomApp.id])
        XCTAssertEqual(r.placed.map(\.slot), [.main, .main, .second])
    }

    // R26.1
    func testOneConnectedPlacesMainOnlyAndIgnoresEverySecondPiece() {
        let r = LayoutResolver.resolve(layout(main: [app, chat], second: [roomApp, meeting]), screens: [main], primaryHeight: primaryHeight)
        XCTAssertEqual(r.variant, .oneDisplay)
        XCTAssertEqual(r.placed.map(\.piece.id), [app.id, chat.id])
        XCTAssertTrue(r.placed.allSatisfy { $0.screen.id == "MAIN" && $0.slot == .main })
        XCTAssertNil(r.meeting)
        XCTAssertNil(r.apps.first { $0.piece.id == roomApp.id })
    }

    // R26.1: a missing second display is no news, so no note.
    func testOneConnectedMakesNoNoteAboutTheMissingDisplay() {
        let r = LayoutResolver.resolve(layout(main: [app], second: [roomApp]), screens: [main], primaryHeight: primaryHeight)
        XCTAssertTrue(r.notes.isEmpty)
    }

    // R26.3
    func testMeetingOnlyOnSecondPlacesNoMeetingWindowWhenSecondIsMissing() {
        let t = layout(main: [app, chat], second: [meeting])
        XCTAssertNil(LayoutResolver.resolve(t, screens: [main], primaryHeight: primaryHeight).meeting)
        XCTAssertNotNil(LayoutResolver.resolve(t, screens: [main, second], primaryHeight: primaryHeight).meeting)
    }

    // R26.4
    func testActiveSpeakerOnMainStandsInForTheMeetingWhenTheSecondIsNotConnected() {
        let speaker = LayoutPiece(kind: .view(.activeSpeaker, startsHidden: false), rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.5))
        let t = layout(main: [app, speaker], second: [meeting])
        let alone = LayoutResolver.substitutingMeetingForActiveSpeaker(t, viewsCanOpen: false, secondConnected: false)
        XCTAssertTrue(alone.pieces(for: .main).contains { $0.kind.isMeeting }, "main's speaker becomes the Meeting")
        let both = LayoutResolver.substitutingMeetingForActiveSpeaker(t, viewsCanOpen: false, secondConnected: true)
        XCTAssertFalse(both.pieces(for: .main).contains { $0.kind.isMeeting }, "second's Meeting is the one")
    }

    // R26.5
    func testRoomScreenIsNotPlacedWithoutASecondDisplay() {
        let room = LayoutPiece(kind: .roomScreen, rect: .full)
        let t = layout(main: [app], second: [room])
        XCTAssertNil(LayoutResolver.resolve(t, screens: [main], primaryHeight: primaryHeight).roomScreen)
        XCTAssertNotNil(LayoutResolver.resolve(t, screens: [main, second], primaryHeight: primaryHeight).roomScreen)
    }
}
