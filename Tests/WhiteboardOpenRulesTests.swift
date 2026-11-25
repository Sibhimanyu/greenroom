import XCTest

final class WhiteboardOpenRulesTests: XCTestCase {
    func testOpeningFromToolsIsLocalWhateverTheMeetingSees() {
        XCTAssertEqual(WhiteboardOpenRules.toolAction(shareIsWhiteboard: false, localIsOpen: false), .openLocal)
    }

    func testToolTogglesTheLocalWindowAway() {
        XCTAssertEqual(WhiteboardOpenRules.toolAction(shareIsWhiteboard: false, localIsOpen: true), .closeLocal)
    }

    func testWhenWhiteboardIsTheShareToolNeverChangesIt() {
        XCTAssertEqual(WhiteboardOpenRules.toolAction(shareIsWhiteboard: true, localIsOpen: false), .raisePresented)
        XCTAssertEqual(WhiteboardOpenRules.toolAction(shareIsWhiteboard: true, localIsOpen: true), .raisePresented)
    }

    func testOnlyAPresentedWhiteboardFeedsTheStage() {
        XCTAssertTrue(WhiteboardOpenRules.feedsStage(shareIsWhiteboard: true))
        XCTAssertFalse(WhiteboardOpenRules.feedsStage(shareIsWhiteboard: false))
    }
}
