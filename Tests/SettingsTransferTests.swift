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

    // MARK: R8, a file exported before the D1 settings existed

    /// What the app wrote today (before settings-transfer): sorted keys, no D1
    /// keys, legacy layout keys from an older era, and one key from the future.
    private static let todaysExport = """
    {
      "autoRecordOnStart" : true,
      "backgroundRemoval" : "automatic",
      "browserRestoresTabs" : true,
      "browserSearchSuggestions" : true,
      "bubbleBottomInset" : 0.04,
      "bubbleRightInset" : 0.02,
      "bubbleWidthFraction" : 0.28,
      "cameraDirector" : {
        "awayDegrees" : 25,
        "cameraUIDs" : ["cam-a", "cam-b"],
        "dwellSeconds" : 1,
        "enabled" : true,
        "noCamera" : false,
        "transition" : "cut"
      },
      "chromeLayout" : "split",
      "chromeOnStart" : true,
      "chromeURL" : "https://example.org",
      "clipBufferEnabled" : true,
      "cuesUseWhisper" : false,
      "customUIMode" : true,
      "cutoutHeightFraction" : 0.8,
      "cutoutRightInset" : 0.01,
      "hideSelfView" : false,
      "layoutLibrary" : { "templates" : [], "version" : 1 },
      "meetingPresets" : [
        { "id" : "11111111-1111-1111-1111-111111111111", "name" : "Maths", "number" : "123456789", "password" : "pw" }
      ],
      "prompterEnabled" : false,
      "prompterLocaleIdentifier" : "en_GB",
      "recordSystemAudio" : false,
      "recordingCountdownSeconds" : 3,
      "s2sAccountID" : "acct",
      "s2sClientID" : "s2s-id",
      "s2sClientSecret" : "s2s-secret",
      "screenroomLanguage" : "en-GB",
      "sdkClientID" : "sdk-id",
      "sdkClientSecret" : "sdk-secret",
      "shareTarget" : { "kind" : "display" },
      "speakerTileShortcutEnabled" : true,
      "userDisplayName" : "Ms Rao",
      "webcamShape" : "circle",
      "workspaceLayout" : { "mainFraction" : 0.6, "mainOnLeft" : true },
      "youtubePrivacy" : "unlisted",
      "youtubeUploadMode" : "off",
      "aKeyFromTheFuture" : [1, 2, 3]
    }
    """

    // R8
    func testTodaysExportFixtureStillDecodes() throws {
        let t = try JSONDecoder().decode(SettingsTransfer.self, from: Data(Self.todaysExport.utf8))
        XCTAssertEqual(t.sdkClientID, "sdk-id")
        XCTAssertEqual(t.s2sClientSecret, "s2s-secret")
        XCTAssertEqual(t.webcamShape, "circle")
        XCTAssertEqual(t.recordingCountdownSeconds, 3)
        XCTAssertEqual(t.meetingPresets?.first?.name, "Maths")
        XCTAssertEqual(t.cameraDirector?.cameraUIDs, ["cam-a", "cam-b"])
        XCTAssertEqual(t.shareTarget?.kind, .display)
        XCTAssertEqual(t.layoutLibrary?.templates.count, 0)
        XCTAssertEqual(t.screenroomLanguage, "en-GB")
    }

    // R8: nothing the new settings add is invented for an old file.
    func testOldFileLeavesEveryNewSettingAlone() throws {
        let t = try JSONDecoder().decode(SettingsTransfer.self, from: Data(Self.todaysExport.utf8))
        let result = SettingsImportRules.sanitized(t, in: SettingsImportEnvironment())
        XCTAssertTrue(result.notes.isEmpty)
        for value in [result.transfer.cameraBackground, result.transfer.cameraBackgroundImage,
                      result.transfer.className, result.transfer.meetingMode, result.transfer.micDeviceUID,
                      result.transfer.meetingWindowView, result.transfer.meetingWindowShareLayout] {
            XCTAssertNil(value)
        }
        XCTAssertNil(result.transfer.copyInviteOnStart)
        XCTAssertNil(result.transfer.meetingWindowShareSplit)
        XCTAssertNil(result.transfer.meetingViewsEnabled)
    }

    // R8
    func testLegacyOnlyKeysStillDecode() throws {
        let t = try JSONDecoder().decode(SettingsTransfer.self, from: Data(Self.todaysExport.utf8))
        XCTAssertEqual(t.chromeLayout, "split")
        XCTAssertEqual(t.chromeURL, "https://example.org")
        XCTAssertEqual(t.chromeOnStart, true)
        XCTAssertEqual(t.workspaceLayout?.mainFraction, 0.6)
        XCTAssertEqual(t.speakerTileShortcutEnabled, true)
    }

    // R8: a file written now carries the D1 keys, and the old keys are unchanged.
    func testNewKeysAreAdditiveOnly() throws {
        var t = todaysFields()
        t.cameraBackground = "Blur"; t.className = "Year 9"
        let object = try JSONSerialization.jsonObject(with: try encoded(t)) as? [String: Any]
        let keys = Set(object?.keys ?? [:].keys)
        XCTAssertTrue(Self.todaysKeys.isSubset(of: keys))
        XCTAssertEqual(keys.subtracting(Self.todaysKeys), ["cameraBackground", "className"])
    }
}
