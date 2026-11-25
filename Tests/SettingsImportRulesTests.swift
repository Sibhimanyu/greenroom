import XCTest

/// R3, R6, R7 of docs/specs/settings-transfer.md.
final class SettingsImportRulesTests: XCTestCase {

    private func clean(_ t: SettingsTransfer, _ env: SettingsImportEnvironment = .init()) -> SettingsTransfer {
        SettingsImportRules.sanitized(t, in: env).transfer
    }

    // R3
    func testCuesEnabledNeedsARelease() {
        var t = SettingsTransfer(); t.prompterEnabled = true
        var env = SettingsImportEnvironment(); env.cuesReleased = false
        XCTAssertNil(clean(t, env).prompterEnabled)
        env.cuesReleased = true
        XCTAssertEqual(clean(t, env).prompterEnabled, true)
    }

    // R3
    func testWhisperIsAndedWithAvailability() {
        var t = SettingsTransfer(); t.cuesUseWhisper = true
        var env = SettingsImportEnvironment(); env.whisperAvailable = false
        XCTAssertEqual(clean(t, env).cuesUseWhisper, false)
        env.whisperAvailable = true
        XCTAssertEqual(clean(t, env).cuesUseWhisper, true)
        t.cuesUseWhisper = false
        XCTAssertEqual(clean(t, env).cuesUseWhisper, false)
    }

    // R3
    func testWhisperCarriedWhenNotCheckable() {
        var t = SettingsTransfer(); t.cuesUseWhisper = true
        var env = SettingsImportEnvironment(); env.whisperAvailable = nil
        XCTAssertEqual(clean(t, env).cuesUseWhisper, true)
    }

    // R3
    func testCountdownMustBeOneOfTheOffered() {
        for ok in [0, 3, 5, 10] {
            var t = SettingsTransfer(); t.recordingCountdownSeconds = ok
            XCTAssertEqual(clean(t).recordingCountdownSeconds, ok)
        }
        var t = SettingsTransfer(); t.recordingCountdownSeconds = 7
        XCTAssertNil(clean(t).recordingCountdownSeconds)
    }

    // R3
    func testSecondDisplayClearedWhenNotConnected() {
        let two = TwoDisplay(main: [], second: [], secondUUID: "elsewhere")
        let template = LayoutTemplate(name: "T", twoDisplays: two)
        let gone = SettingsImportRules.withLocalDisplays(template, connected: ["here"])
        XCTAssertEqual(gone.twoDisplays?.secondUUID, "")
        let kept = SettingsImportRules.withLocalDisplays(template, connected: ["elsewhere"])
        XCTAssertEqual(kept.twoDisplays?.secondUUID, "elsewhere")
    }

    // R3
    func testImportedLibraryGetsLocalDisplays() {
        var t = SettingsTransfer()
        t.layoutLibrary = LayoutLibrary(templates: [
            LayoutTemplate(name: "T", twoDisplays: TwoDisplay(main: [], second: [], secondUUID: "elsewhere"))])
        var env = SettingsImportEnvironment(); env.connectedDisplayUUIDs = ["here"]
        XCTAssertEqual(clean(t, env).layoutLibrary?.templates.first?.twoDisplays?.secondUUID, "")
    }

    // R3: a field the file omits stays nil (so the Mac keeps its own).
    func testOmittedFieldsStayNil() {
        let out = clean(SettingsTransfer())
        XCTAssertEqual(out, SettingsTransfer())
    }
}
