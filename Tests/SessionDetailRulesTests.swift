import XCTest

/// The session page's pure rules: the inspector fold, the marks lane's click,
/// and what the toolbar buttons call themselves.
final class SessionDetailRulesTests: XCTestCase {

    func testNarrowPageFoldsInspectorAndWideBringsItBack() {
        var r = SessionDetailRules.inspector(width: 800, shown: true, foldedByWidth: false)
        XCTAssertEqual(r.shown, false)
        XCTAssertEqual(r.foldedByWidth, true)
        r = SessionDetailRules.inspector(width: 900, shown: r.shown, foldedByWidth: r.foldedByWidth)
        XCTAssertEqual(r.shown, true)
        XCTAssertEqual(r.foldedByWidth, false)
    }

    func testPersonsHiddenInspectorStaysHiddenWhenWide() {
        let r = SessionDetailRules.inspector(width: 1200, shown: false, foldedByWidth: false)
        XCTAssertEqual(r.shown, false)
    }

    func testZeroWidthDoesNotFold() {
        let r = SessionDetailRules.inspector(width: 0, shown: true, foldedByWidth: false)
        XCTAssertEqual(r.shown, true)
    }

    func testSeekTimeMapsClickToRecordingAndClamps() {
        XCTAssertEqual(SessionDetailRules.seekTime(x: 50, width: 200, duration: 100) ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(SessionDetailRules.seekTime(x: 500, width: 200, duration: 100) ?? -1, 100, accuracy: 0.001)
        XCTAssertNil(SessionDetailRules.seekTime(x: 5, width: 200, duration: 0))
        XCTAssertNil(SessionDetailRules.seekTime(x: 5, width: 0, duration: 10))
    }

    func testFractionClamps() {
        XCTAssertEqual(SessionDetailRules.fraction(of: 30, in: 60), 0.5, accuracy: 0.001)
        XCTAssertEqual(SessionDetailRules.fraction(of: 90, in: 60), 1)
        XCTAssertEqual(SessionDetailRules.fraction(of: 5, in: 0), 0)
    }

    func testButtonTitlesFollowState() {
        XCTAssertEqual(SessionDetailRules.uploadTitle(uploading: false, uploaded: false), "Upload")
        XCTAssertEqual(SessionDetailRules.uploadTitle(uploading: true, uploaded: false), "Uploading\u{2026}")
        XCTAssertEqual(SessionDetailRules.uploadTitle(uploading: false, uploaded: true), "On YouTube")
        XCTAssertEqual(SessionDetailRules.analyseTitle(running: true, analysed: false, progress: (2, 4)),
                       "Analysing 2/4\u{2026}")
        XCTAssertEqual(SessionDetailRules.analyseTitle(running: true, analysed: false, progress: nil),
                       "Analysing\u{2026}")
        XCTAssertEqual(SessionDetailRules.analyseTitle(running: false, analysed: true, progress: nil),
                       "Report")
        XCTAssertEqual(SessionDetailRules.analyseTitle(running: false, analysed: false, progress: nil), "Analyse")
    }
}
