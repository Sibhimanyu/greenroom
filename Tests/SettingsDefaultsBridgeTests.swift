import XCTest

/// R5 of docs/specs/settings-transfer.md: the settings kept only in UserDefaults.
final class SettingsDefaultsBridgeTests: XCTestCase {

    private func suite() -> UserDefaults {
        let name = "SettingsDefaultsBridgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // R5
    func testBridgeRoundTripsTheKeptOnlyInDefaults() {
        let source = SettingsDefaultsBridge(defaults: suite())
        var original = SettingsTransfer()
        original.copyInviteOnStart = false
        original.sessionNotesEnabled = true
        original.mirrorSelfView = false
        original.meetingViewsEnabled = false
        original.meetingWindowView = MeetingViewMode.allCases.last!.rawValue
        original.meetingWindowShareLayout = MeetingShareLayout.allCases.last!.rawValue
        original.meetingWindowShareSplit = 0.6
        original.meetingWindowHideSelfView = true
        original.meetingWindowHideVideoOff = true
        source.apply(original)

        var read = SettingsTransfer()
        source.read(into: &read)
        XCTAssertEqual(read, original)
    }

    // R5: what the Mac shows when nothing was ever saved is what is exported.
    func testUnsavedSettingsExportTheirDefaults() {
        var read = SettingsTransfer()
        SettingsDefaultsBridge(defaults: suite()).read(into: &read)
        XCTAssertEqual(read.copyInviteOnStart, true)
        XCTAssertEqual(read.sessionNotesEnabled, false)
        XCTAssertEqual(read.mirrorSelfView, true)
        XCTAssertEqual(read.meetingViewsEnabled, true)
        XCTAssertEqual(read.meetingWindowShareSplit, MeetingSplit.defaultFraction)
    }

    // R5: a file that omits a field leaves this Mac's value alone.
    func testApplyTouchesOnlyWhatTheFileCarries() {
        let defaults = suite()
        defaults.set(true, forKey: SettingsKeys.sessionNotesEnabled)
        var t = SettingsTransfer(); t.copyInviteOnStart = false
        SettingsDefaultsBridge(defaults: defaults).apply(t)
        XCTAssertEqual(defaults.object(forKey: SettingsKeys.copyInviteOnStart) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: SettingsKeys.sessionNotesEnabled) as? Bool, true)
    }

    // R5: the keys are the ones the views read.
    func testKeysMatchTheViewsOwnConstants() {
        XCTAssertEqual(SettingsKeys.meetingWindowView, MeetingViewPrefs.viewKey)
        XCTAssertEqual(SettingsKeys.meetingWindowShareLayout, MeetingViewPrefs.shareLayoutKey)
        XCTAssertEqual(SettingsKeys.meetingWindowShareSplit, MeetingViewPrefs.splitKey)
        XCTAssertEqual(SettingsKeys.meetingWindowHideSelfView, MeetingViewPrefs.hideSelfKey)
        XCTAssertEqual(SettingsKeys.meetingWindowHideVideoOff, MeetingViewPrefs.hideNoVideoKey)
        XCTAssertEqual(SettingsKeys.meetingViewsEnabled, MeetingViewPieces.defaultsKey)
    }
}
