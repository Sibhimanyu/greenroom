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
}
