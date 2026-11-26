//
//  SettingsCatalog.swift
//  Greenroom
//
//  The one list of every setting Greenroom persists: its key, its default, and
//  whether it TRAVELS in the settings file (export and import), is IMPORT-ONLY
//  (an older file may carry it; nothing writes it), or is EXCLUDED with a
//  written reason. docs/specs/settings-transfer.md.
//
//  Adding a persisted setting means adding a line here. SettingsCatalogTests
//  scans the sources and fails, naming the key, when one is missing.
//
import Foundation

/// A setting's default, as the coordinator loads it when nothing is saved.
enum SettingDefault: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// Nothing is saved until the person sets it.
    case unset
    /// Worked out at load (a layout's size, the user's Mac name...).
    case derived(String)
}

struct SettingsEntry: Equatable {
    enum Disposition: Equatable {
        /// Written by export and read by import, under this key in the file.
        case travels(transferKey: String)
        /// Read from older files; nothing writes it any more.
        case importOnly(transferKey: String)
        /// Stays on this Mac, for this reason.
        case excluded(reason: String)
    }

    /// The UserDefaults (or Keychain) key. A trailing `*` means "every key that
    /// starts with this" (keys built at run time).
    let key: String
    let defaultValue: SettingDefault
    let disposition: Disposition
    /// Said when only part of the value travels.
    var note: String = ""

    var isPrefix: Bool { key.hasSuffix("*") }

    func matches(_ other: String) -> Bool {
        isPrefix ? other.hasPrefix(String(key.dropLast())) : other == key
    }

    var transferKey: String? {
        switch disposition {
        case .travels(let k), .importOnly(let k): return k
        case .excluded: return nil
        }
    }
}

/// Keys of the settings that live only in UserDefaults (no published property
/// on the coordinator), so the views that read them and the settings file agree
/// on one spelling.
enum SettingsKeys {
    static let cameraBackground = "cameraBackground"
    static let cameraBackgroundImage = "cameraBackgroundImage"
    static let className = "className"
    static let meetingMode = "meetingMode"
    static let micDeviceUID = "micDeviceUID"
    static let copyInviteOnStart = "copyInviteOnStart"
    static let sessionNotesEnabled = "sessionNotesEnabled"
    static let mirrorSelfView = "camera.mirrorSelfView"
    static let meetingWindowView = "meetingWindow.view"
    static let meetingWindowShareLayout = "meetingWindow.shareLayout"
    static let meetingWindowShareSplit = "meetingWindow.shareSplit"
    static let meetingWindowHideSelfView = "meetingWindow.hideSelfView"
    static let meetingWindowHideVideoOff = "meetingWindow.hideVideoOff"
    static let meetingViewsEnabled = "meetingViews.enabled"
}

enum SettingsCatalog {

    private static func travels(_ key: String, _ def: SettingDefault, as transferKey: String? = nil,
                                note: String = "") -> SettingsEntry {
        SettingsEntry(key: key, defaultValue: def, disposition: .travels(transferKey: transferKey ?? key), note: note)
    }

    private static func importOnly(_ key: String, _ def: SettingDefault, as transferKey: String? = nil) -> SettingsEntry {
        SettingsEntry(key: key, defaultValue: def, disposition: .importOnly(transferKey: transferKey ?? key))
    }

    private static func excluded(_ key: String, _ def: SettingDefault = .unset, _ reason: String) -> SettingsEntry {
        SettingsEntry(key: key, defaultValue: def, disposition: .excluded(reason: reason))
    }

    static let entries: [SettingsEntry] = [
        // Zoom and YouTube credentials (the secrets live in the Keychain).
        travels("zoomSDKClientID", .string(""), as: "sdkClientID"),
        travels("zoomSDKClientSecret", .string(""), as: "sdkClientSecret"),
        travels("zoomS2SAccountID", .string(""), as: "s2sAccountID"),
        travels("zoomS2SClientID", .string(""), as: "s2sClientID"),
        travels("zoomS2SClientSecret", .string(""), as: "s2sClientSecret"),
        excluded("zoomPrefersOwnApps", .bool(false), "Picks between this Mac's Zoom sign-in and the pasted apps; the sign-in does not travel, so neither does the choice."),
        travels("youtubeClientID", .string("")),
        travels("youtubeClientSecret", .string("")),
        travels("youtubeUploadMode", .string("off")),
        travels("youtubePrivacy", .string("unlisted")),

        // The picture and the person.
        travels("webcamShape", .string("circle")),
        travels("backgroundRemoval", .string("automatic")),
        travels("cameraDirectorSettings", .derived("CameraDirectorSettings()"), as: "cameraDirector"),
        travels("bubbleWidthFraction", .derived("StageLayout().widthFraction")),
        travels("bubbleRightInset", .derived("StageLayout().rightInset")),
        travels("bubbleBottomInset", .derived("StageLayout().bottomInset")),
        travels("cutoutHeightFraction", .derived("StageLayout().cutoutHeightFraction")),
        travels("cutoutRightInset", .derived("StageLayout().cutoutRightInset")),
        travels("userDisplayName", .derived("NSFullUserName()")),
        travels("shareTarget", .derived("ShareTarget()")),
        travels("screenCaptureDisplayUUID", .string("")),
        travels("hideSelfView", .bool(false)),

        // Recording, Cues, browser, layouts, shortcuts, Screenroom.
        travels("autoRecordOnStart", .bool(false)),
        travels("recordingCountdownSeconds", .int(3)),
        travels("recordSystemAudio", .bool(false)),
        travels("clipBufferEnabled", .bool(true)),
        travels("browserRestoresTabs", .bool(true)),
        travels("browserSearchSuggestions", .bool(true)),
        travels("prompterEnabled", .bool(false)),
        travels("prompterVideoSearch", .bool(true)),
        travels("prompterUseModel", .bool(false)),
        travels("prompterSaveTranscript", .bool(true)),
        travels("prompterLocaleIdentifier", .string("")),
        travels("cuesUseWhisper", .bool(false)),
        travels("meetingPresets", .unset),
        travels("layoutLibrary", .derived("LayoutLibrary.loadOrMigrate")),
        travels("shortcuts.bindings", .unset, as: "shortcutBindings"),
        travels("screenroomAgentSettings", .unset, as: "screenroomAgent"),
        travels("screenroomDefaultRubric", .unset, as: "screenroomRubric"),
        travels("screenroomTranscriberSettings", .unset, as: "screenroomLanguage",
                note: "Only the language travels; the model path is a file on the exporting Mac."),

        // Settings-transfer D1: added once an audit found them missing.
        travels(SettingsKeys.cameraBackground, .string("Normal"), as: "cameraBackground"),
        travels(SettingsKeys.cameraBackgroundImage, .string("studio"), as: "cameraBackgroundImage",
                note: "A custom picture is a file on the exporting Mac; import falls back to Blur without it."),
        travels(SettingsKeys.className, .string(""), as: "className"),
        travels(SettingsKeys.meetingMode, .string("create"), as: "meetingMode"),
        travels(SettingsKeys.micDeviceUID, .string(""), as: "micDeviceUID",
                note: "Applied only if that microphone is connected to the importing Mac."),
        travels(SettingsKeys.copyInviteOnStart, .bool(true), as: "copyInviteOnStart"),
        travels(SettingsKeys.sessionNotesEnabled, .bool(false), as: "sessionNotesEnabled"),
        travels(SettingsKeys.mirrorSelfView, .bool(true), as: "mirrorSelfView"),
        travels(SettingsKeys.meetingWindowView, .string("gallery"), as: "meetingWindowView"),
        travels(SettingsKeys.meetingWindowShareLayout, .string("standard"), as: "meetingWindowShareLayout"),
        travels(SettingsKeys.meetingWindowShareSplit, .derived("MeetingSplit.defaultFraction"), as: "meetingWindowShareSplit"),
        travels(SettingsKeys.meetingWindowHideSelfView, .bool(false), as: "meetingWindowHideSelfView"),
        travels(SettingsKeys.meetingWindowHideVideoOff, .bool(false), as: "meetingWindowHideVideoOff"),
        travels(SettingsKeys.meetingViewsEnabled, .bool(true), as: "meetingViewsEnabled"),

        // Read from older files, never written now.
        importOnly("speakerTileShortcutEnabled", .bool(true)),
        importOnly("browserClosesOnStop", .bool(false)),
        importOnly("workspaceLayout", .unset),
        importOnly("chromeLayout", .unset),
        importOnly("chromeURL", .unset),
        importOnly("chromeOnStart", .unset),
        importOnly("mainAppBundleID", .unset),
        importOnly("mainAppURL", .unset),
        importOnly("mainAppOnStart", .unset),
        importOnly("peopleViewOnStart", .unset),
        importOnly("peopleViewDisplayUUID", .unset),

        // Stays on this Mac.
        excluded("analyticsEnabled", .bool(true), "Consent. Each Mac asks itself."),
        excluded("hasCompletedOnboarding", .bool(false), "A new Mac runs onboarding."),
        excluded("watchPlayerVolume", .unset, "Per Mac listening level."),
        excluded("sessionsShow", .unset, "View state of this Mac's Sessions page."),
        excluded("sessionsSort", .unset, "View state of this Mac's Sessions page."),
        excluded("sessionsNeed", .unset, "View state of this Mac's Sessions page."),
        excluded("sessionsSidebarHidden", .unset, "View state of this Mac's window."),
        excluded("sessionPanelHidden", .unset, "View state of this Mac's window."),
        excluded("NSWindow Frame *", .unset, "Window positions; screens differ per Mac. Keys are built at run time."),
        excluded("recordingControlBar.frame", .unset, "Window position; screens differ per Mac."),
        excluded("meetingControlBar.collapsed", .unset, "Window state of this Mac's control bar."),
        excluded("meetingControlBar.pillFrame", .unset, "Window position; screens differ per Mac."),
        excluded("meetingControlBar.puckFrame", .unset, "Window position; screens differ per Mac."),
        excluded("meetingShrinkTip.done", .bool(false), "A tip each Mac shows once."),
        excluded("analysisSetupSeen", .bool(false), "A tip each Mac shows once."),
        excluded("screenroomStageTimings", .unset, "Measured on this Mac's hardware."),
        excluded("browserLastSessionTabs", .unset, "This Mac's open tabs."),
        excluded("browserLastSessionConfiguredIndex", .unset, "This Mac's open tabs."),
        excluded("browserLastSessionConfiguredURL", .unset, "This Mac's open tabs."),
        excluded("cameraShownOnMyScreen", .bool(true), "The camera state's saved default; each layout's camera piece carries its own look in the layout library."),
        excluded("layoutCameraMigrated", .unset, "One-time migration marker on this Mac."),
        excluded("layoutShareMigrated", .unset, "One-time migration marker on this Mac."),
        excluded("layoutLibrary.appsShownToEveryoneMigrated", .unset, "One-time migration marker on this Mac."),
        excluded("layoutLibrary.builtInsV2Migrated", .unset, "One-time migration marker on this Mac."),
        excluded("layoutLibrary.threeBuiltInsMigrated", .unset, "One-time migration marker on this Mac."),
        excluded("layoutLibrary.oneArrangementMigrated", .unset, "One-time migration marker on this Mac."),
        excluded("layoutLibrary.rajSanModeRenamed", .unset, "One-time migration marker on this Mac."),
        excluded("layoutLibrary.shownToEveryoneMigrated", .unset, "One-time migration marker on this Mac."),
        excluded("sessionNotesBarSpots", .unset, "Where the notes bar was dropped, per display: window positions stay on their Mac."),
        excluded("sessionNotesBarLastDisplay", .unset, "Which display the notes bar was last on: window positions stay on their Mac."),
        excluded("layoutLibrary.knownStarters", .unset, "Bookkeeping of which starter layouts this Mac has seen."),
        excluded("youtubeUploadConfirmed", .bool(false), "A consent the person gives on their own Mac."),
        excluded("youtubeRefreshToken", .unset, "A token: each Mac connects its own account."),
        excluded("zoomUserRefreshToken", .unset, "A token: each Mac signs in itself."),
        excluded("zoomUserProfile", .unset, "An account: each Mac signs in itself."),
        excluded("zoomUserGrantedScopes", .unset, "An account: each Mac signs in itself."),
        excluded("zoomUserClientID", .unset, "An account: each Mac signs in itself."),
        excluded("account.mock.preset", .unset, "Debug account mock."),
        excluded("account.mock.signedIn", .unset, "Debug account mock."),
        excluded("GreenroomRawVideoSpike", .bool(false), "A debug switch."),
        excluded("secret_*", .unset, "Keychain items are named at run time; the secrets that travel are listed above."),
    ]

    /// Transfer fields no setting stands behind any more: decoded so an old file
    /// still reads, then ignored.
    static let retiredTransferFields: [String: String] = [
        "participantPanelOnMainDisplay": "The setting was removed; old files still carry the key.",
        "visibleToRecorders": "The switch was removed: other apps always see Greenroom as you do. Old files carry the key; it is decoded and ignored, and nothing writes it.",
        "customUIMode": "Zoom's own meeting window was removed (2026-11-25); Greenroom's meeting window is the only mode. Old files carry the key; it is decoded and ignored, and nothing writes it.",
    ]

    /// Every key a file may contain, for the guard test.
    static var transferKeys: Set<String> {
        Set(entries.compactMap(\.transferKey)).union(retiredTransferFields.keys)
    }
}
