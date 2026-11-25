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
        let two = TwoDisplay(second: [], secondUUID: "elsewhere")
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
            LayoutTemplate(name: "T", twoDisplays: TwoDisplay(second: [], secondUUID: "elsewhere"))])
        var env = SettingsImportEnvironment(); env.connectedDisplayUUIDs = ["here"]
        XCTAssertEqual(clean(t, env).layoutLibrary?.templates.first?.twoDisplays?.secondUUID, "")
    }

    // R3: a field the file omits stays nil (so the Mac keeps its own).
    func testOmittedFieldsStayNil() {
        let out = clean(SettingsTransfer())
        XCTAssertEqual(out, SettingsTransfer())
    }

    // MARK: R6, a missing custom picture falls back to Blur

    private func background(_ mode: String?, _ image: String?, custom: Bool) -> (SettingsTransfer, [String]) {
        var t = SettingsTransfer(); t.cameraBackground = mode; t.cameraBackgroundImage = image
        var env = SettingsImportEnvironment(); env.customPictureAvailable = custom
        let result = SettingsImportRules.sanitized(t, in: env)
        return (result.transfer, result.notes)
    }

    // R6
    func testCustomPictureMissingFallsBackToBlur() {
        let (t, notes) = background("Image", "custom-1760000000", custom: false)
        XCTAssertEqual(t.cameraBackground, "Blur")
        XCTAssertNil(t.cameraBackgroundImage, "the missing picture's key is not imported")
        XCTAssertEqual(notes, [SettingsImportRules.pictureDidNotTravelNote])
    }

    // R6
    func testCustomPictureMissingWhileNotInUseNeedsNoNote() {
        for mode in ["Normal", "Blur"] {
            let (t, notes) = background(mode, "custom-1760000000", custom: false)
            XCTAssertEqual(t.cameraBackground, mode)
            XCTAssertTrue(notes.isEmpty, mode)
        }
    }

    // R6
    func testCustomPicturePresentIsKept() {
        let (t, notes) = background("Image", "custom-1760000000", custom: true)
        XCTAssertEqual(t.cameraBackground, "Image")
        XCTAssertEqual(t.cameraBackgroundImage, "custom-1760000000")
        XCTAssertTrue(notes.isEmpty)
    }

    // R6
    func testPresetPictureNeverFallsBack() {
        let (t, notes) = background("Image", "sunset", custom: false)
        XCTAssertEqual(t.cameraBackground, "Image")
        XCTAssertEqual(t.cameraBackgroundImage, "sunset")
        XCTAssertTrue(notes.isEmpty)
    }

    // R5
    func testUnknownBackgroundNameIsDropped() {
        let (t, _) = background("Sparkles", "not-a-picture", custom: true)
        XCTAssertNil(t.cameraBackground)
        XCTAssertNil(t.cameraBackgroundImage)
    }

    // MARK: R7, the microphone applies only if it is connected

    private func mic(_ uid: String?, connected: Set<String>) -> String? {
        var t = SettingsTransfer(); t.micDeviceUID = uid
        var env = SettingsImportEnvironment(); env.connectedMicrophoneUIDs = connected
        return SettingsImportRules.sanitized(t, in: env).transfer.micDeviceUID
    }

    // R7
    func testMicrophoneAppliedWhenConnected() {
        XCTAssertEqual(mic("usb-1", connected: ["usb-1", "builtin"]), "usb-1")
    }

    // R7
    func testMicrophoneDroppedWhenNotConnected() {
        XCTAssertNil(mic("usb-1", connected: ["builtin"]))
    }

    // R7
    func testSystemInputMicrophoneAlwaysApplies() {
        XCTAssertEqual(mic("", connected: []), "")
    }

    // MARK: R5, values the settings themselves would not accept

    // R5
    func testUnknownMeetingViewIsDropped() {
        var t = SettingsTransfer()
        t.meetingWindowView = "carousel"; t.meetingWindowShareLayout = "diagonal"
        let out = clean(t)
        XCTAssertNil(out.meetingWindowView)
        XCTAssertNil(out.meetingWindowShareLayout)
        t.meetingWindowView = MeetingViewMode.allCases[0].rawValue
        XCTAssertEqual(clean(t).meetingWindowView, MeetingViewMode.allCases[0].rawValue)
    }

    // R5
    func testMeetingWindowSplitIsClamped() {
        var t = SettingsTransfer(); t.meetingWindowShareSplit = 99
        XCTAssertEqual(clean(t).meetingWindowShareSplit, MeetingSplit.clamp(99))
        t.meetingWindowShareSplit = -5
        XCTAssertEqual(clean(t).meetingWindowShareSplit, MeetingSplit.clamp(-5))
    }
}
