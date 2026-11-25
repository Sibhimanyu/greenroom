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

    func testBackToScreenReturnsToTheTargetBeforeTheWhiteboard() {
        var r: String? = nil
        r = WhiteboardOpenRules.remembered(r, replaced: "window", oldIsWhiteboard: false, newIsWhiteboard: true)
        XCTAssertEqual(WhiteboardOpenRules.returnTarget(remembered: r, fallback: "default"), "window")
        r = WhiteboardOpenRules.remembered(r, replaced: "whiteboard", oldIsWhiteboard: true, newIsWhiteboard: true)
        XCTAssertEqual(r, "window", "a change while it is the whiteboard keeps it")
        XCTAssertEqual(WhiteboardOpenRules.remembered(r, replaced: "whiteboard", oldIsWhiteboard: true, newIsWhiteboard: false), "window")
        XCTAssertNil(WhiteboardOpenRules.remembered(r, replaced: "display", oldIsWhiteboard: false, newIsWhiteboard: false))
        XCTAssertEqual(WhiteboardOpenRules.returnTarget(remembered: nil, fallback: "default"), "default")
    }

    func testClosingTheLocalWhiteboardAlwaysRestoresTheDrawingStateItFound() {
        XCTAssertEqual(WhiteboardOpenRules.closeOutcome(wasSuspended: true, shareIsWhiteboard: false, shareIsNothing: false), .resumeCanvas)
        XCTAssertEqual(WhiteboardOpenRules.closeOutcome(wasSuspended: false, shareIsWhiteboard: false, shareIsNothing: false), .drawingOff)
        XCTAssertEqual(WhiteboardOpenRules.closeOutcome(wasSuspended: true, shareIsWhiteboard: false, shareIsNothing: true), .drawingOff,
                       "Just me: no screen to draw on, but nothing stays stuck")
        XCTAssertEqual(WhiteboardOpenRules.closeOutcome(wasSuspended: true, shareIsWhiteboard: true, shareIsNothing: false), .untouched)
    }
}
