import XCTest
@testable import GreenroomTests

final class PreviewSecondDisplayRulesTests: XCTestCase {
    typealias R = PreviewSecondDisplayRules

    func testNothingOnTheSecondDisplayMeansNoNote() {
        XCTAssertNil(R.note(secondPieceIsMeeting: []))
    }
    func testMeetingAloneNamesTheMeetingWindow() {
        XCTAssertEqual(R.note(secondPieceIsMeeting: [true]), "Meeting window on your second display")
    }
    func testMeetingAndOthersCountsTheRest() {
        XCTAssertEqual(R.note(secondPieceIsMeeting: [false, true, false]),
                       "Meeting window and 2 more on your second display")
    }
    func testOtherPiecesOnlyAreCounted() {
        XCTAssertEqual(R.note(secondPieceIsMeeting: [false]), "1 window on your second display")
        XCTAssertEqual(R.note(secondPieceIsMeeting: [false, false]), "2 windows on your second display")
    }

    func testRowWithNoteKeepsTheNoteAndTheButton() {
        let row = R.row(pieceCount: 2, secondPieceIsMeeting: [false])
        XCTAssertEqual(row, R.Row(note: "1 window on your second display"))
    }
    func testRowWithoutNoteStillShowsTheButton() {
        XCTAssertEqual(R.row(pieceCount: 2, secondPieceIsMeeting: []), R.Row(note: nil))
    }
    func testNoPiecesMeansNoRowAtAll() {
        XCTAssertNil(R.row(pieceCount: 0, secondPieceIsMeeting: []))
        XCTAssertNil(R.row(pieceCount: nil, secondPieceIsMeeting: []))
    }
}

// Owner bug 2026-11-25: Show on screen under Home's preview must not show when the active layout tiles no
// windows (Leave my windows alone), even if pieces were left in it: it moves no window, so there is nothing to outline.
final class PreviewRowNoTilingTests: XCTestCase {
    private typealias R = PreviewSecondDisplayRules

    func testLeaveMyWindowsAloneHasNoRow() {
        let leave = LayoutLibrary.shipped(LayoutLibrary.leaveAlone)
        XCTAssertNil(R.row(for: leave, secondPieceIsMeeting: []))
    }

    func testLeaveMyWindowsAloneWithStrayPiecesStillHasNoRow() {
        var leave = LayoutLibrary.shipped(LayoutLibrary.leaveAlone)!
        leave.oneDisplay = [LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: 0.3, h: 1))]
        XCTAssertGreaterThan(leave.pieceCount, 0)
        XCTAssertNil(R.row(for: leave, secondPieceIsMeeting: []), "it moves no window")
    }

    func testATilingLayoutKeepsItsRow() {
        let teach = LayoutLibrary.shipped(LayoutLibrary.teachFromBrowser)
        XCTAssertEqual(R.row(for: teach, secondPieceIsMeeting: []), R.Row(note: nil))
    }

    func testNoLayoutHasNoRow() { XCTAssertNil(R.row(for: nil, secondPieceIsMeeting: [])) }
}
