import XCTest

/// The meeting views are on by default; the defaults key is a kill switch.
final class MeetingViewFlagTests: XCTestCase {
    override func tearDown() {
        MeetingViewPieces.override = nil
        super.tearDown()
    }

    func testKillSwitchOffOffersOnlyTheMeetingWindow() {
        let entries = MeetingViewPieces.addEntries(customUIMode: true, viewsEnabled: false)
        XCTAssertEqual(entries.map(\.id), ["meeting"])
        XCTAssertEqual(entries.first?.title, "Meeting window")
        XCTAssertEqual(MeetingViewPieces.addEntries(customUIMode: false, viewsEnabled: false).first?.title, "Zoom window")
    }

    func testOnOffersTheWindowAndAllNineViews() {
        let entries = MeetingViewPieces.addEntries(customUIMode: true, viewsEnabled: true)
        XCTAssertEqual(MeetingView.allCases.count, 9)
        XCTAssertEqual(entries.count, 1 + 9)
        XCTAssertEqual(entries.compactMap { $0.kind.view }, MeetingView.allCases)
        XCTAssertEqual(entries.map(\.title), ["Meeting window", "Active speaker", "Gallery", "Multi-speaker", "Speaker + strip",
                                              "Self view", "People list", "Shared screen", "Spotlight student", "Hands up"])
    }

    func testFlagReadsTheOverrideThenTheDefaultWhichIsOn() {
        MeetingViewPieces.override = true
        XCTAssertTrue(MeetingViewPieces.enabled)
        MeetingViewPieces.override = false
        XCTAssertFalse(MeetingViewPieces.enabled)
        MeetingViewPieces.override = nil
        let stored = UserDefaults.standard.object(forKey: MeetingViewPieces.defaultsKey) as? Bool
        XCTAssertEqual(MeetingViewPieces.enabled, stored ?? true)
    }

    func testNothingStoredMeansOn() {
        let saved = UserDefaults.standard.object(forKey: MeetingViewPieces.defaultsKey)
        UserDefaults.standard.removeObject(forKey: MeetingViewPieces.defaultsKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: MeetingViewPieces.defaultsKey) } }
        XCTAssertTrue(MeetingViewPieces.enabled)
        UserDefaults.standard.set(false, forKey: MeetingViewPieces.defaultsKey)
        XCTAssertFalse(MeetingViewPieces.enabled, "the defaults key is the kill switch")
        UserDefaults.standard.removeObject(forKey: MeetingViewPieces.defaultsKey)
    }
}
