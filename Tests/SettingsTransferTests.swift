import XCTest

/// The settings file (docs/specs/settings-transfer.md). R2: today's fields keep
/// their JSON keys and round-trip.
final class SettingsTransferTests: XCTestCase {

    /// Every field that existed before the settings-transfer work, with a value.
    private func todaysFields() -> SettingsTransfer {
        var t = SettingsTransfer()
        t.sdkClientID = "sdk-id"; t.sdkClientSecret = "sdk-secret"
        t.s2sAccountID = "acct"; t.s2sClientID = "s2s-id"; t.s2sClientSecret = "s2s-secret"
        t.webcamShape = "circle"; t.backgroundRemoval = "automatic"
        t.mainAppBundleID = "com.apple.Safari"; t.mainAppURL = "https://example.com"; t.mainAppOnStart = true
        t.browserRestoresTabs = false; t.browserSearchSuggestions = false; t.browserClosesOnStop = true
        t.prompterEnabled = true; t.prompterVideoSearch = false; t.prompterUseModel = true
        t.prompterSaveTranscript = false; t.prompterLocaleIdentifier = "en_GB"
        t.youtubeUploadMode = "off"; t.youtubePrivacy = "unlisted"
        t.youtubeClientID = "yt-id"; t.youtubeClientSecret = "yt-secret"
        t.peopleViewOnStart = true; t.peopleViewDisplayUUID = "uuid-1"
        t.screenCaptureDisplayUUID = "uuid-2"
        t.shareTarget = ShareTarget()
        t.hideSelfView = true; t.speakerTileShortcutEnabled = false
        t.autoRecordOnStart = true; t.recordingCountdownSeconds = 5; t.recordSystemAudio = true
        t.meetingPresets = [MeetingPreset(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                          name: "Maths", number: "123456789", password: "pw")]
        t.workspaceLayout = WorkspaceLayout()
        t.layoutLibrary = LayoutLibrary()
        t.shortcutBindings = ShortcutBindings()
        t.userDisplayName = "Ms Rao"; t.customUIMode = true; t.clipBufferEnabled = false
        t.participantPanelOnMainDisplay = true
        t.cameraDirector = CameraDirectorSettings()
        t.bubbleWidthFraction = 0.3; t.bubbleRightInset = 0.02; t.bubbleBottomInset = 0.04
        t.cutoutHeightFraction = 0.8; t.cutoutRightInset = 0.01
        t.cuesUseWhisper = true
        t.screenroomAgent = "{}"; t.screenroomRubric = "{}"; t.screenroomLanguage = "en-GB"
        t.chromeLayout = "split"; t.chromeURL = "https://example.org"; t.chromeOnStart = true
        return t
    }

    /// The keys a file exported before this work can contain (R2, R8).
    static let todaysKeys: Set<String> = [
        "sdkClientID", "sdkClientSecret", "s2sAccountID", "s2sClientID", "s2sClientSecret",
        "webcamShape", "backgroundRemoval", "mainAppBundleID", "mainAppURL", "mainAppOnStart",
        "browserRestoresTabs", "browserSearchSuggestions", "browserClosesOnStop",
        "prompterEnabled", "prompterVideoSearch", "prompterUseModel", "prompterSaveTranscript",
        "prompterLocaleIdentifier", "youtubeUploadMode", "youtubePrivacy", "youtubeClientID",
        "youtubeClientSecret", "peopleViewOnStart", "peopleViewDisplayUUID",
        "screenCaptureDisplayUUID", "shareTarget", "hideSelfView", "speakerTileShortcutEnabled",
        "autoRecordOnStart", "recordingCountdownSeconds", "recordSystemAudio", "meetingPresets",
        "workspaceLayout", "layoutLibrary", "shortcutBindings", "userDisplayName", "customUIMode",
        "clipBufferEnabled", "participantPanelOnMainDisplay", "cameraDirector",
        "bubbleWidthFraction", "bubbleRightInset", "bubbleBottomInset", "cutoutHeightFraction",
        "cutoutRightInset", "cuesUseWhisper", "screenroomAgent", "screenroomRubric",
        "screenroomLanguage", "chromeLayout", "chromeURL", "chromeOnStart",
    ]

    private func encoded(_ t: SettingsTransfer) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(t)
    }

    // R2
    func testEveryFieldRoundTrips() throws {
        let original = todaysFields()
        let back = try JSONDecoder().decode(SettingsTransfer.self, from: try encoded(original))
        XCTAssertEqual(back, original)
    }

    // R2
    func testExistingKeysKeepTheirNames() throws {
        let object = try JSONSerialization.jsonObject(with: try encoded(todaysFields())) as? [String: Any]
        XCTAssertEqual(Set(object?.keys ?? [:].keys), Self.todaysKeys)
    }

    // R2
    func testEncodingIsPrettyPrintedAndSorted() throws {
        var t = SettingsTransfer()
        t.webcamShape = "circle"; t.autoRecordOnStart = true
        let text = String(decoding: try encoded(t), as: UTF8.self)
        XCTAssertEqual(text, "{\n  \"autoRecordOnStart\" : true,\n  \"webcamShape\" : \"circle\"\n}")
    }

    // R3
    func testUnknownKeysAreIgnored() throws {
        let json = #"{"webcamShape":"circle","somethingFromTheFuture":{"a":1}}"#
        let t = try JSONDecoder().decode(SettingsTransfer.self, from: Data(json.utf8))
        XCTAssertEqual(t.webcamShape, "circle")
    }
}
