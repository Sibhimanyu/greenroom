import XCTest

/// Every setting the app keeps in UserDefaults is declared once (docs/specs/saved-settings.md).
final class SavedSettingsTests: XCTestCase {

    private func store() -> UserDefaults {
        let name = "SavedSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: R1 One declaration each

    // Spec: saved-settings R1.1
    func testEveryDeclaredSettingIsListed() throws {
        let text = try source("App/Settings/SavedSettings.swift")
        let regex = try NSRegularExpression(pattern: #"static\s+let\s+(\w+)\s*=\s*SavedSetting\."#)
        let declared = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).count
        XCTAssertEqual(SavedSettings.all.count, declared, "A SavedSetting is declared but not in SavedSettings.all (or the reverse)")
        XCTAssertEqual(SavedSettings.all.count, 34)
    }

    // Spec: saved-settings R1.2
    func testNoTwoSettingsShareAKey() {
        let keys = SavedSettings.all.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "Shared keys: \(Dictionary(grouping: keys, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    // Spec: saved-settings R1.2
    func testNoSettingSharesAKeyWithTheCameraLook() {
        let look: Set<String> = [CameraLook.removalKey, CameraLook.backgroundKey, CameraLook.backgroundImageKey, CameraLook.mirrorKey]
        XCTAssertTrue(Set(SavedSettings.all.map(\.key)).isDisjoint(with: look))
    }

    // MARK: R2 Loads under the old keys with the old defaults

    // Spec: saved-settings R2.1
    func testDefaultsAreWhatInitUsedToLoad() {
        let d = store()
        XCTAssertEqual(SavedSettings.meetingMode.load(from: d), .create)
        XCTAssertEqual(SavedSettings.meetingPresets.load(from: d), [])
        XCTAssertEqual(SavedSettings.sdkClientID.load(from: d), "")
        XCTAssertEqual(SavedSettings.s2sAccountID.load(from: d), "")
        XCTAssertEqual(SavedSettings.s2sClientID.load(from: d), "")
        XCTAssertEqual(SavedSettings.userDisplayName.load(from: d), NSFullUserName())
        XCTAssertEqual(SavedSettings.cameraShownOnMyScreen.load(from: d), true)
        XCTAssertEqual(SavedSettings.hideSelfView.load(from: d), false)
        XCTAssertEqual(SavedSettings.speakerTileShortcutEnabled.load(from: d), true)
        XCTAssertEqual(SavedSettings.micDeviceUID.load(from: d), "")
        XCTAssertEqual(SavedSettings.browserRestoresTabs.load(from: d), true)
        XCTAssertEqual(SavedSettings.browserSearchSuggestions.load(from: d), true)
        XCTAssertEqual(SavedSettings.cuesEnabled.load(from: d), false)
        XCTAssertEqual(SavedSettings.cuesVideoSearch.load(from: d), true)
        XCTAssertEqual(SavedSettings.cuesUseModel.load(from: d), false)
        XCTAssertEqual(SavedSettings.cuesSaveTranscript.load(from: d), true)
        XCTAssertEqual(SavedSettings.cuesUseWhisper.load(from: d), false)
        XCTAssertEqual(SavedSettings.cuesLocaleIdentifier.load(from: d), "")
        XCTAssertEqual(SavedSettings.youtubeUploadMode.load(from: d), .off)
        XCTAssertEqual(SavedSettings.youtubePrivacy.load(from: d), "unlisted")
        XCTAssertEqual(SavedSettings.youtubeClientID.load(from: d), "")
        XCTAssertNil(SavedSettings.youtubeUsesOwnApp.load(from: d))
        XCTAssertNil(SavedSettings.youtubeMadeForKids.load(from: d))
        XCTAssertNil(SavedSettings.youtubeChannel.load(from: d))
        XCTAssertEqual(SavedSettings.analyticsEnabled.load(from: d), true)
        XCTAssertEqual(SavedSettings.screenCaptureDisplayUUID.load(from: d), "")
        XCTAssertEqual(SavedSettings.autoRecordOnStart.load(from: d), false)
        XCTAssertEqual(SavedSettings.recordingCountdownSeconds.load(from: d), 3)
        XCTAssertEqual(SavedSettings.recordSystemAudio.load(from: d), false)
        XCTAssertEqual(SavedSettings.className.load(from: d), "")
        XCTAssertEqual(SavedSettings.clipBufferEnabled.load(from: d), true)
        XCTAssertEqual(SavedSettings.copyInviteOnStart.load(from: d), true)
        XCTAssertEqual(SavedSettings.sessionNotesEnabled.load(from: d), false)
        XCTAssertEqual(SavedSettings.meetingViewsEnabled.load(from: d), true)
    }

    // Spec: saved-settings R2.2
    func testLoadsAStoreWrittenTheOldWay() throws {
        let d = store()
        d.set("record", forKey: "meetingMode")
        let preset = MeetingPreset(name: "Maths", number: "123", password: "pw")
        d.set(try JSONEncoder().encode([preset]), forKey: "meetingPresets")
        d.set("sdk", forKey: "zoomSDKClientID")
        d.set("acct", forKey: "zoomS2SAccountID")
        d.set("s2s", forKey: "zoomS2SClientID")
        d.set("Ms Rao", forKey: "userDisplayName")
        d.set(false, forKey: "cameraShownOnMyScreen")
        d.set(true, forKey: "hideSelfView")
        d.set(false, forKey: "speakerTileShortcutEnabled")
        d.set("mic-1", forKey: "micDeviceUID")
        d.set(false, forKey: "browserRestoresTabs")
        d.set(false, forKey: "browserSearchSuggestions")
        d.set(true, forKey: "prompterEnabled")
        d.set(false, forKey: "prompterVideoSearch")
        d.set(true, forKey: "prompterUseModel")
        d.set(false, forKey: "prompterSaveTranscript")
        d.set(true, forKey: "cuesUseWhisper")
        d.set("en_GB", forKey: "prompterLocaleIdentifier")
        d.set("automatic", forKey: "youtubeUploadMode")
        d.set("private", forKey: "youtubePrivacy")
        d.set("yt", forKey: "youtubeClientID")
        d.set(true, forKey: "youtubeUsesOwnApp")
        d.set(false, forKey: "youtubeMadeForKids")
        d.set(try JSONEncoder().encode(YouTubeChannel(name: "Maths", avatarURL: nil)), forKey: "youtubeChannel")
        d.set(false, forKey: "analyticsEnabled")
        d.set("uuid-1", forKey: "screenCaptureDisplayUUID")
        d.set(true, forKey: "autoRecordOnStart")
        d.set(10, forKey: "recordingCountdownSeconds")
        d.set(true, forKey: "recordSystemAudio")
        d.set("Period 3", forKey: "className")
        d.set(false, forKey: "clipBufferEnabled")
        d.set(false, forKey: "copyInviteOnStart")
        d.set(true, forKey: "sessionNotesEnabled")
        d.set(false, forKey: "meetingViews.enabled")

        XCTAssertEqual(SavedSettings.meetingMode.load(from: d), .record)
        XCTAssertEqual(SavedSettings.meetingPresets.load(from: d), [preset])
        XCTAssertEqual(SavedSettings.sdkClientID.load(from: d), "sdk")
        XCTAssertEqual(SavedSettings.s2sAccountID.load(from: d), "acct")
        XCTAssertEqual(SavedSettings.s2sClientID.load(from: d), "s2s")
        XCTAssertEqual(SavedSettings.userDisplayName.load(from: d), "Ms Rao")
        XCTAssertEqual(SavedSettings.cameraShownOnMyScreen.load(from: d), false)
        XCTAssertEqual(SavedSettings.hideSelfView.load(from: d), true)
        XCTAssertEqual(SavedSettings.speakerTileShortcutEnabled.load(from: d), false)
        XCTAssertEqual(SavedSettings.micDeviceUID.load(from: d), "mic-1")
        XCTAssertEqual(SavedSettings.browserRestoresTabs.load(from: d), false)
        XCTAssertEqual(SavedSettings.browserSearchSuggestions.load(from: d), false)
        XCTAssertEqual(SavedSettings.cuesEnabled.load(from: d), true)
        XCTAssertEqual(SavedSettings.cuesVideoSearch.load(from: d), false)
        XCTAssertEqual(SavedSettings.cuesUseModel.load(from: d), true)
        XCTAssertEqual(SavedSettings.cuesSaveTranscript.load(from: d), false)
        XCTAssertEqual(SavedSettings.cuesUseWhisper.load(from: d), true)
        XCTAssertEqual(SavedSettings.cuesLocaleIdentifier.load(from: d), "en_GB")
        XCTAssertEqual(SavedSettings.youtubeUploadMode.load(from: d), .automatic)
        XCTAssertEqual(SavedSettings.youtubePrivacy.load(from: d), "private")
        XCTAssertEqual(SavedSettings.youtubeClientID.load(from: d), "yt")
        XCTAssertEqual(SavedSettings.youtubeUsesOwnApp.load(from: d), true)
        XCTAssertEqual(SavedSettings.youtubeMadeForKids.load(from: d), false)
        XCTAssertEqual(SavedSettings.youtubeChannel.load(from: d), YouTubeChannel(name: "Maths", avatarURL: nil))
        XCTAssertEqual(SavedSettings.analyticsEnabled.load(from: d), false)
        XCTAssertEqual(SavedSettings.screenCaptureDisplayUUID.load(from: d), "uuid-1")
        XCTAssertEqual(SavedSettings.autoRecordOnStart.load(from: d), true)
        XCTAssertEqual(SavedSettings.recordingCountdownSeconds.load(from: d), 10)
        XCTAssertEqual(SavedSettings.recordSystemAudio.load(from: d), true)
        XCTAssertEqual(SavedSettings.className.load(from: d), "Period 3")
        XCTAssertEqual(SavedSettings.clipBufferEnabled.load(from: d), false)
        XCTAssertEqual(SavedSettings.copyInviteOnStart.load(from: d), false)
        XCTAssertEqual(SavedSettings.sessionNotesEnabled.load(from: d), true)
        XCTAssertEqual(SavedSettings.meetingViewsEnabled.load(from: d), false)
    }

    // Spec: saved-settings R2.3
    func testAValueOfTheWrongKindReadsAsTheDefault() {
        let d = store()
        d.set("not a mode", forKey: "meetingMode")
        d.set("not an upload mode", forKey: "youtubeUploadMode")
        d.set(Data("not json".utf8), forKey: "meetingPresets")
        d.set(Data("not json".utf8), forKey: "youtubeChannel")
        d.set("three", forKey: "recordingCountdownSeconds")
        d.set(5, forKey: "className")
        d.set("sometimes", forKey: "clipBufferEnabled")
        XCTAssertEqual(SavedSettings.meetingMode.load(from: d), .create)
        XCTAssertEqual(SavedSettings.youtubeUploadMode.load(from: d), .off)
        XCTAssertEqual(SavedSettings.meetingPresets.load(from: d), [])
        XCTAssertNil(SavedSettings.youtubeChannel.load(from: d))
        XCTAssertEqual(SavedSettings.recordingCountdownSeconds.load(from: d), 3)
        XCTAssertEqual(SavedSettings.clipBufferEnabled.load(from: d), true)
        // Reading never writes.
        XCTAssertEqual(d.string(forKey: "meetingMode"), "not a mode")
    }

    // Spec: saved-settings R2.4
    func testABoolWithDefaultOffReadsLikeBoolForKeyDid() {
        let d = store()
        d.set("YES", forKey: "autoRecordOnStart")      // bool(forKey:) reads this as true
        d.set(1, forKey: "prompterEnabled")               // and this
        XCTAssertEqual(SavedSettings.autoRecordOnStart.load(from: d), d.bool(forKey: "autoRecordOnStart"))
        XCTAssertEqual(SavedSettings.cuesEnabled.load(from: d), true)
    }

    // Spec: saved-settings R2.4
    func testABoolWithDefaultOnReadsLikeObjectAsBoolDid() {
        let d = store()
        d.set("NO", forKey: "clipBufferEnabled")        // as? Bool is nil for a string, so the default holds
        XCTAssertEqual(SavedSettings.clipBufferEnabled.load(from: d), (d.object(forKey: "clipBufferEnabled") as? Bool) ?? true)
        d.set(false, forKey: "browserRestoresTabs")
        XCTAssertEqual(SavedSettings.browserRestoresTabs.load(from: d), false)
    }

    // Spec: saved-settings R2.5
    func testStoredIsNilUntilTheKeyIsSaved() {
        let d = store()
        XCTAssertNil(SavedSettings.cameraShownOnMyScreen.stored(in: d))
        XCTAssertNil(SavedSettings.youtubeUsesOwnApp.load(from: d))
        XCTAssertNil(SavedSettings.youtubeMadeForKids.load(from: d))
        XCTAssertNil(SavedSettings.youtubeChannel.load(from: d))
        XCTAssertNil(SavedSettings.analyticsEnabled.stored(in: d))
        d.set(false, forKey: "cameraShownOnMyScreen")
        XCTAssertEqual(SavedSettings.cameraShownOnMyScreen.stored(in: d), false)
    }

    // MARK: R3 Saves under the same keys

    // Spec: saved-settings R3.1
    func testEveryDeclaredKeyRoundTrips() {
        for info in SavedSettings.all {
            XCTAssertTrue(info.roundTrips(store()), "\(info.key) did not load back what was saved")
            XCTAssertTrue(info.defaultsWhenEmpty(store()), "\(info.key) did not load its default from an empty store")
        }
    }

    // Spec: saved-settings R3.1
    func testSaveWritesTheOldStoredTypes() throws {
        let d = store()
        SavedSettings.meetingMode.save(.join, to: d)
        SavedSettings.youtubeUploadMode.save(.ask, to: d)
        SavedSettings.autoRecordOnStart.save(true, to: d)
        SavedSettings.recordingCountdownSeconds.save(5, to: d)
        SavedSettings.className.save("Period 1", to: d)
        SavedSettings.youtubeMadeForKids.save(true, to: d)
        SavedSettings.youtubeUsesOwnApp.save(false, to: d)
        SavedSettings.meetingViewsEnabled.save(false, to: d)
        XCTAssertEqual(d.string(forKey: "meetingMode"), "join")
        XCTAssertEqual(d.string(forKey: "youtubeUploadMode"), "ask")
        XCTAssertEqual(d.object(forKey: "autoRecordOnStart") as? Bool, true)
        XCTAssertEqual(d.object(forKey: "recordingCountdownSeconds") as? Int, 5)
        XCTAssertEqual(d.string(forKey: "className"), "Period 1")
        XCTAssertEqual(d.object(forKey: "youtubeMadeForKids") as? Bool, true)
        XCTAssertEqual(d.object(forKey: "youtubeUsesOwnApp") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "meetingViews.enabled") as? Bool, false)
        let preset = MeetingPreset(name: "A", number: "1", password: "")
        SavedSettings.meetingPresets.save([preset], to: d)
        XCTAssertEqual(try JSONDecoder().decode([MeetingPreset].self, from: XCTUnwrap(d.data(forKey: "meetingPresets"))), [preset])
    }

    // Spec: saved-settings R3.2
    func testSavingNilRemovesTheKey() {
        let d = store()
        SavedSettings.youtubeMadeForKids.save(true, to: d)
        SavedSettings.youtubeMadeForKids.save(nil, to: d)
        XCTAssertNil(d.object(forKey: "youtubeMadeForKids"))
        SavedSettings.youtubeChannel.save(YouTubeChannel(name: "A", avatarURL: "u"), to: d)
        XCTAssertNotNil(d.data(forKey: "youtubeChannel"))
        SavedSettings.youtubeChannel.save(nil, to: d)
        XCTAssertNil(d.object(forKey: "youtubeChannel"))
    }

    // MARK: R4 The coordinator goes through it

    // Spec: saved-settings R4.1
    func testTheCoordinatorSpellsNoSavedKeyAsALiteral() throws {
        let text = try source("App/CoordinatorController.swift")
        for info in SavedSettings.all {
            XCTAssertFalse(text.contains("forKey: \"\(info.key)\""), "CoordinatorController.swift still spells \(info.key) by hand")
        }
    }

    // MARK: R5 The settings file reads the same declaration

    // Spec: saved-settings R5.1
    func testSettingsKeysAreTheDeclaredKeys() {
        XCTAssertEqual(SettingsKeys.className, SavedSettings.className.key)
        XCTAssertEqual(SettingsKeys.meetingMode, SavedSettings.meetingMode.key)
        XCTAssertEqual(SettingsKeys.micDeviceUID, SavedSettings.micDeviceUID.key)
        XCTAssertEqual(SettingsKeys.copyInviteOnStart, SavedSettings.copyInviteOnStart.key)
        XCTAssertEqual(SettingsKeys.sessionNotesEnabled, SavedSettings.sessionNotesEnabled.key)
        XCTAssertEqual(SettingsKeys.meetingViewsEnabled, SavedSettings.meetingViewsEnabled.key)
        XCTAssertEqual(SettingsKeys.cameraBackground, CameraLook.backgroundKey)
        XCTAssertEqual(SettingsKeys.cameraBackgroundImage, CameraLook.backgroundImageKey)
        XCTAssertEqual(SettingsKeys.mirrorSelfView, CameraLook.mirrorKey)
    }

    // Spec: saved-settings R5.2
    func testTheBridgeReadsAndWritesThroughTheDeclaration() {
        let d = store()
        var transfer = SettingsTransfer()
        SettingsDefaultsBridge(defaults: d).read(into: &transfer)
        XCTAssertEqual(transfer.copyInviteOnStart, SavedSettings.copyInviteOnStart.defaultValue)
        XCTAssertEqual(transfer.sessionNotesEnabled, SavedSettings.sessionNotesEnabled.defaultValue)
        XCTAssertEqual(transfer.meetingViewsEnabled, SavedSettings.meetingViewsEnabled.defaultValue)
        var file = SettingsTransfer()
        file.copyInviteOnStart = false
        file.sessionNotesEnabled = true
        file.meetingViewsEnabled = false
        SettingsDefaultsBridge(defaults: d).apply(file)
        XCTAssertEqual(SavedSettings.copyInviteOnStart.load(from: d), false)
        XCTAssertEqual(SavedSettings.sessionNotesEnabled.load(from: d), true)
        XCTAssertEqual(SavedSettings.meetingViewsEnabled.load(from: d), false)
    }

    // Spec: saved-settings R5.3
    func testTheCatalogStatesTheSameDefaults() {
        for info in SavedSettings.all {
            guard let plain = info.plainDefault,
                  let entry = SettingsCatalog.entries.first(where: { $0.key == info.key }) else { continue }
            switch entry.defaultValue {
            case .bool, .int, .string: XCTAssertEqual(entry.defaultValue, plain, "SettingsCatalog and SavedSettings disagree on the default of \(info.key)")
            default: break
            }
        }
    }

    // Spec: saved-settings R6.1
    func testTheKeysSpelledOutsideTheModuleAreTheDeclaredKeys() {
        // LayoutTemplate.swift is compiled alone by scripts/render, so it keeps its own spelling; this pins it.
        XCTAssertEqual(MeetingViewPieces.defaultsKey, SavedSettings.meetingViewsEnabled.key)
        let d = store()
        SavedSettings.speakerTileShortcutEnabled.save(false, to: d)
        XCTAssertFalse(LegacyLayoutSettings.read(from: d, defaultSiteURL: "https://example.com").quickHide)
    }
}
