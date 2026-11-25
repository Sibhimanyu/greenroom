//
//  CoordinatorController+SettingsTransfer.swift
//  Greenroom
//
//  Export and import of the settings file, through the coordinator's own
//  published properties so every didSet runs.
//
import Foundation

extension CoordinatorController {

    func exportSettingsData() throws -> Data {
        loadSecretsIfNeeded()
        var transfer = SettingsTransfer(
            sdkClientID: sdkClientID,
            sdkClientSecret: sdkClientSecret,
            s2sAccountID: s2sAccountID,
            s2sClientID: s2sClientID,
            s2sClientSecret: s2sClientSecret,
            webcamShape: webcamShape.rawValue,
            backgroundRemoval: backgroundRemoval.rawValue,
            browserRestoresTabs: browserRestoresTabs,
            browserSearchSuggestions: browserSearchSuggestions,
            prompterEnabled: cuesEnabled,
            prompterVideoSearch: cuesVideoSearch,
            prompterUseModel: cuesUseModel,
            prompterSaveTranscript: cuesSaveTranscript,
            prompterLocaleIdentifier: cuesLocaleIdentifier,
            youtubeUploadMode: youtubeUploadMode.rawValue,
            youtubePrivacy: youtubePrivacy,
            youtubeClientID: youtubeClientID,
            youtubeClientSecret: youtubeClientSecret,
            screenCaptureDisplayUUID: screenCaptureDisplayUUID,
            shareTarget: shareTarget,
            hideSelfView: hideSelfView,
            autoRecordOnStart: autoRecordOnStart,
            recordingCountdownSeconds: recordingCountdownSeconds,
            recordSystemAudio: recordSystemAudio,
            meetingPresets: meetingPresets,
            layoutLibrary: layoutLibrary,
            shortcutBindings: ShortcutStore.shared.bindings,
            userDisplayName: userDisplayName,
            clipBufferEnabled: clipBufferEnabled,
            cameraDirector: cameraDirectorSettings,
            bubbleWidthFraction: bubbleWidthFraction,
            bubbleRightInset: bubbleRightInset,
            bubbleBottomInset: bubbleBottomInset,
            cutoutHeightFraction: cutoutHeightFraction,
            cutoutRightInset: cutoutRightInset,
            cuesUseWhisper: cuesUseWhisper,
            screenroomAgent: Self.jsonString(forKey: ScreenroomAgentSettings.key),
            screenroomRubric: Self.jsonString(forKey: "screenroomDefaultRubric"),
            screenroomLanguage: ScreenroomTranscriberSettings.load().language,
            cameraBackground: cameraBackground.rawValue,
            cameraBackgroundImage: cameraBackgroundImage,
            className: className,
            meetingMode: meetingMode.rawValue,
            micDeviceUID: micDeviceUID
        )
        // The settings kept only in UserDefaults (the meeting window's choices and so on).
        SettingsDefaultsBridge().read(into: &transfer)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(transfer)
    }

    /// Assigning through the @Published properties (not UserDefaults
    /// directly) means every didSet persistence hook fires on its own - the
    /// import needs no separate save step.
    /// A Data-shaped preference, as text, so it survives a JSON round trip.
    ///
    /// ScreenroomAgentSettings and the rubric are stored as encoded JSON in
    /// UserDefaults rather than as individual keys. Carrying them as strings
    /// keeps the transfer file readable and means neither type has to be
    /// imported into SettingsTransfer, which would couple the transfer format
    /// to types that are still moving.
    static func jsonString(forKey key: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setJSONString(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// What this Mac looks like, for `SettingsImportRules`.
    private static func importEnvironment() -> SettingsImportEnvironment {
        var environment = SettingsImportEnvironment()
        environment.cuesReleased = CuesAvailability.isReleased
        if #available(macOS 26.0, *) { environment.whisperAvailable = CuesWhisperTranscriber.isAvailable }
        environment.connectedDisplayUUIDs = Set(DisplayResolver.connectedDisplays().map(\.id))
        environment.connectedMicrophoneUIDs = Set(LocalDeviceResolver.availableMicrophones().map(\.id))
        environment.customPictureAvailable = CameraBackgroundLibrary.customFileURL != nil
        return environment
    }

    @discardableResult
    func importSettings(from data: Data) throws -> SettingsImportReport {
        let decoded = try JSONDecoder().decode(SettingsTransfer.self, from: data)
        let environment = Self.importEnvironment()
        // What import refuses is decided in SettingsImportRules; what is left
        // is assigned below, through the published properties.
        let (transfer, notes) = SettingsImportRules.sanitized(decoded, in: environment)
        // One import assigns every field; that is not twenty deliberate changes.
        Analytics.suppressSettingEvents = true
        defer { Analytics.suppressSettingEvents = false }
        Analytics.feature("settings_import")
        loadSecretsIfNeeded() // so fields the file omits keep their current values
        if let value = transfer.sdkClientID { sdkClientID = value }
        if let value = transfer.sdkClientSecret { sdkClientSecret = value }
        if let value = transfer.s2sAccountID { s2sAccountID = value }
        if let value = transfer.s2sClientID { s2sClientID = value }
        if let value = transfer.s2sClientSecret { s2sClientSecret = value }
        if let value = transfer.webcamShape, let shape = WebcamShape(rawValue: value) { webcamShape = shape }
        if let value = transfer.backgroundRemoval, let mode = BackgroundRemoval(rawValue: value) { backgroundRemoval = mode }
        if let value = transfer.browserRestoresTabs { browserRestoresTabs = value }
        if let value = transfer.browserSearchSuggestions { browserSearchSuggestions = value }
        if let value = transfer.prompterEnabled { cuesEnabled = value }
        if let value = transfer.prompterVideoSearch { cuesVideoSearch = value }
        if let value = transfer.prompterUseModel { cuesUseModel = value }
        if let value = transfer.prompterSaveTranscript { cuesSaveTranscript = value }
        if let value = transfer.prompterLocaleIdentifier { cuesLocaleIdentifier = value }
        // The OAuth client travels (a colleague shares the same Google Cloud
        // app); the connected account never does - each Mac connects its own.
        if let value = transfer.youtubeUploadMode, let mode = YouTubeUploadMode(rawValue: value) { youtubeUploadMode = mode }
        if let value = transfer.youtubePrivacy { youtubePrivacy = value }
        if let value = transfer.youtubeClientID { youtubeClientID = value }
        if let value = transfer.youtubeClientSecret { youtubeClientSecret = value }
        if let value = transfer.screenCaptureDisplayUUID { screenCaptureDisplayUUID = value }
        if let value = transfer.shareTarget { shareTarget = value }
        if let value = transfer.hideSelfView { hideSelfView = value }
        if let value = transfer.speakerTileShortcutEnabled { speakerTileShortcutEnabled = value }
        if let value = transfer.autoRecordOnStart { autoRecordOnStart = value }
        if let value = transfer.recordingCountdownSeconds { recordingCountdownSeconds = value }
        if let value = transfer.recordSystemAudio { recordSystemAudio = value }
        if let value = transfer.userDisplayName { userDisplayName = value }
        if let value = transfer.clipBufferEnabled { clipBufferEnabled = value }
        if let value = transfer.cameraDirector { cameraDirectorSettings = value }
        if let value = transfer.bubbleWidthFraction { bubbleWidthFraction = value }
        if let value = transfer.bubbleRightInset { bubbleRightInset = value }
        if let value = transfer.bubbleBottomInset { bubbleBottomInset = value }
        if let value = transfer.cutoutHeightFraction { cutoutHeightFraction = value }
        if let value = transfer.cutoutRightInset { cutoutRightInset = value }
        if let value = transfer.cuesUseWhisper { cuesUseWhisper = value }
        if let value = transfer.screenroomAgent {
            Self.setJSONString(value, forKey: ScreenroomAgentSettings.key)
        }
        if let value = transfer.screenroomRubric {
            Self.setJSONString(value, forKey: "screenroomDefaultRubric")
        }
        if let value = transfer.screenroomLanguage {
            var settings = ScreenroomTranscriberSettings.load()
            settings.language = value
            settings.save()
        }
        // The camera background: the picture first, so the mode never shows an empty one.
        if let value = transfer.cameraBackgroundImage { cameraBackgroundImage = value }
        if let value = transfer.cameraBackground, let mode = CameraBackground(rawValue: value) { cameraBackground = mode }
        if let value = transfer.className { className = value }
        if let value = transfer.meetingMode, let mode = MeetingMode(rawValue: value) { meetingMode = mode }
        if let value = transfer.micDeviceUID { micDeviceUID = value }
        SettingsDefaultsBridge().apply(transfer)
        if let value = transfer.meetingPresets { meetingPresets = value }
        if let value = transfer.shortcutBindings { ShortcutStore.shared.replace(with: value) }
        if let library = transfer.layoutLibrary {
            // Already cleaned of second displays that are not connected here.
            layoutLibrary = library
        } else if transfer.workspaceLayout != nil || transfer.chromeLayout != nil {
            // An older file: the old keys it carries (import-only now) laid over
            // this Mac's own, then built into one more template. Keys the file
            // omits keep what this Mac has, as before.
            var legacy = LegacyLayoutSettings.read(from: UserDefaults.standard, defaultSiteURL: AppLinks.site)
            if let old = transfer.workspaceLayout ?? transfer.chromeLayout.flatMap({ WorkspaceLayout(legacyChromeLayout: $0) }) {
                legacy.mainFraction = old.mainFraction
                legacy.mainOnLeft = old.mainOnLeft
                legacy.sideShowsZoomTile = old.sideShowsZoomTile
                legacy.sideShowsChat = old.sideShowsChat
                legacy.zoomSlotRatio = old.zoomSlotRatio
                legacy.arrangeWindowsOnStart = old.arrangeWindowsOnStart
            }
            // The chrome* fallbacks import Chrome-only-era files (whose main
            // app was implicitly Chrome, so the values carry straight over).
            if let value = transfer.mainAppBundleID { legacy.mainAppBundleID = value }
            if let value = transfer.mainAppURL ?? transfer.chromeURL { legacy.mainAppURL = value }
            if let value = transfer.mainAppOnStart ?? transfer.chromeOnStart { legacy.mainAppOnStart = value }
            if let value = transfer.browserClosesOnStop { legacy.browserClosesOnStop = value }
            if let value = transfer.peopleViewOnStart { legacy.peopleViewOnStart = value }
            if let value = transfer.peopleViewDisplayUUID { legacy.peopleViewDisplayUUID = value }
            if var imported = legacy.asTemplate().map({ SettingsImportRules.withLocalDisplays($0, connected: environment.connectedDisplayUUIDs) }) {
                var library = layoutLibrary
                if library.templates.contains(where: { $0.name == imported.name }) { imported.name = "Imported layout" }
                library.templates.append(imported)
                if legacy.arrangeWindowsOnStart { library.select(imported.id) }
                layoutLibrary = library
            }
        }
        log("Imported settings.")
        return SettingsImportReport(notes: notes)
    }
}
