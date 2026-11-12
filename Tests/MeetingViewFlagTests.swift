import XCTest

/// The six meeting views stay out of the Add panel until the flag is on.
final class MeetingViewFlagTests: XCTestCase {
    override func tearDown() {
        MeetingViewPieces.override = nil
        super.tearDown()
    }

    func testFlagOffOffersOnlyTheMeetingWindow() {
        let entries = MeetingViewPieces.addEntries(customUIMode: true, viewsEnabled: false)
        XCTAssertEqual(entries.map(\.id), ["meeting"])
        XCTAssertEqual(entries.first?.title, "Meeting window")
        XCTAssertEqual(MeetingViewPieces.addEntries(customUIMode: false, viewsEnabled: false).first?.title, "Zoom window")
    }

    func testFlagOnOffersWindowAndAllSixViews() {
        let entries = MeetingViewPieces.addEntries(customUIMode: true, viewsEnabled: true)
        XCTAssertEqual(entries.count, 1 + MeetingView.allCases.count)
        XCTAssertEqual(entries.compactMap { $0.kind.view }, MeetingView.allCases)
    }

    func testFlagReadsTheOverrideThenTheDefault() {
        MeetingViewPieces.override = true
        XCTAssertTrue(MeetingViewPieces.enabled)
        MeetingViewPieces.override = false
        XCTAssertFalse(MeetingViewPieces.enabled)
        MeetingViewPieces.override = nil
        XCTAssertEqual(MeetingViewPieces.enabled, UserDefaults.standard.bool(forKey: "meetingViews.enabled"))
    }
}
