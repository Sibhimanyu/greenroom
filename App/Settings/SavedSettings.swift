//
//  SavedSettings.swift
//  Greenroom
//
//  The one owner of the settings the app keeps in UserDefaults (docs/specs/saved-settings.md;
//  GLOSSARY.md "Saved setting"): each is declared once below with its key, its type and its
//  default. The coordinator loads and saves through these; the settings file and the views
//  that spell a key read it from here.
//
//  A plain value, no property wrapper: `@Published` and every `didSet` side effect stay on
//  the coordinator, which calls `save` where it used to call `defaults.set`. The store is
//  passed in, so a test uses an in-memory suite. Foundation only; compiled by the test target.
//
//  Not here (and why): the camera look (`CameraLook`), the meeting window's choices
//  (`MeetingViewPrefs`), Keychain secrets (`SecretStore`), layouts, shortcuts and anything with
//  its own loader. The spec lists them.
//
import Foundation

struct SavedSetting<Value> {
    /// The UserDefaults key. Never changes: it is what an installed Mac already holds.
    let key: String
    /// What loads when nothing usable is saved.
    let defaultValue: Value
    /// A value that is not the default, for the round-trip test.
    let other: Value
    /// The default as `SettingsCatalog` states it, where it is a plain bool, int or string.
    let plainDefault: SettingDefault?
    fileprivate let read: (UserDefaults) -> Value?
    fileprivate let write: (Value, UserDefaults) -> Void

    /// What is saved, or nil when the key is absent (or holds the wrong kind of value).
    /// For the optional settings (`Value` is itself optional) use `load`.
    func stored(in defaults: UserDefaults) -> Value? { read(defaults) }

    func load(from defaults: UserDefaults) -> Value { read(defaults) ?? defaultValue }

    func save(_ value: Value, to defaults: UserDefaults) { write(value, defaults) }
}

// MARK: Declaring one

extension SavedSetting where Value == Bool {
    /// A default of `false` reads like `bool(forKey:)` did; a default of `true` like
    /// `(object(forKey:) as? Bool) ?? true` did. Either way, a missing key is the default.
    static func bool(key: String, default fallback: Bool) -> SavedSetting<Bool> {
        SavedSetting(key: key, defaultValue: fallback, other: !fallback, plainDefault: .bool(fallback),
                     read: { d in
                         if fallback { return d.object(forKey: key) as? Bool }
                         return d.object(forKey: key) == nil ? nil : d.bool(forKey: key)
                     },
                     write: { v, d in d.set(v, forKey: key) })
    }
}

extension SavedSetting where Value == Int {
    static func int(key: String, default fallback: Int) -> SavedSetting<Int> {
        SavedSetting(key: key, defaultValue: fallback, other: fallback + 1, plainDefault: .int(fallback),
                     read: { d in d.object(forKey: key) as? Int },
                     write: { v, d in d.set(v, forKey: key) })
    }
}

extension SavedSetting where Value == String {
    static func string(key: String, default fallback: String) -> SavedSetting<String> {
        SavedSetting(key: key, defaultValue: fallback, other: fallback + "x", plainDefault: .string(fallback),
                     read: { d in d.string(forKey: key) },
                     write: { v, d in d.set(v, forKey: key) })
    }
}

extension SavedSetting where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
    /// Stored as the case's raw string; a string that is not a case reads as the default.
    static func choice(key: String, default fallback: Value) -> SavedSetting<Value> {
        let other = Value.allCases.first { $0.rawValue != fallback.rawValue } ?? fallback
        return SavedSetting(key: key, defaultValue: fallback, other: other, plainDefault: .string(fallback.rawValue),
                            read: { d in d.string(forKey: key).flatMap(Value.init(rawValue:)) },
                            write: { v, d in d.set(v.rawValue, forKey: key) })
    }
}

extension SavedSetting where Value: Codable {
    /// Stored as JSON `Data`. Data that does not decode reads as the default; a value that
    /// does not encode writes nothing.
    static func json(key: String, default fallback: Value, other: Value) -> SavedSetting<Value> {
        SavedSetting(key: key, defaultValue: fallback, other: other, plainDefault: nil,
                     read: { d in d.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) } },
                     write: { v, d in if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) } })
    }
}

extension SavedSetting {
    /// A Bool that may never have been answered. Saving nil removes the key.
    static func optionalBool(key: String) -> SavedSetting<Bool?> where Value == Bool? {
        SavedSetting(key: key, defaultValue: nil, other: true, plainDefault: nil,
                     read: { d in d.object(forKey: key) == nil ? nil : .some(d.object(forKey: key) as? Bool) },
                     write: { v, d in if let v { d.set(v, forKey: key) } else { d.removeObject(forKey: key) } })
    }

    /// JSON that may be absent. Saving nil, or a value that does not encode, removes the key.
    static func optionalJSON<T: Codable>(key: String, other: T) -> SavedSetting<T?> where Value == T? {
        SavedSetting(key: key, defaultValue: nil, other: other, plainDefault: nil,
                     read: { d in d.data(forKey: key) == nil ? nil : .some(d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }) },
                     write: { v, d in
                         if let data = v.flatMap({ try? JSONEncoder().encode($0) }) { d.set(data, forKey: key) }
                         else { d.removeObject(forKey: key) }
                     })
    }
}

// MARK: Listing them for the tests

/// A setting without its type, so one test can walk every declaration.
struct SavedSettingInfo {
    let key: String
    let plainDefault: SettingDefault?
    /// Saves a value that is not the default and loads it back equal.
    let roundTrips: (UserDefaults) -> Bool
    /// An empty store loads the default.
    let defaultsWhenEmpty: (UserDefaults) -> Bool
}

extension SavedSetting where Value: Equatable {
    var info: SavedSettingInfo {
        let setting = self
        return SavedSettingInfo(
            key: key, plainDefault: plainDefault,
            roundTrips: { d in
                setting.save(setting.other, to: d)
                return setting.load(from: d) == setting.other
            },
            defaultsWhenEmpty: { d in setting.load(from: d) == setting.defaultValue })
    }
}

// MARK: The settings

enum SavedSettings {

    // Meeting and Zoom
    static let meetingMode = SavedSetting.choice(key: "meetingMode", default: MeetingMode.create)
    static let meetingPresets = SavedSetting.json(
        key: "meetingPresets", default: [MeetingPreset](),
        other: [MeetingPreset(id: UUID(), name: "A", number: "1", password: "")])
    static let sdkClientID = SavedSetting.string(key: "zoomSDKClientID", default: "")
    static let s2sAccountID = SavedSetting.string(key: "zoomS2SAccountID", default: "")
    static let s2sClientID = SavedSetting.string(key: "zoomS2SClientID", default: "")
    static let userDisplayName = SavedSetting.string(key: "userDisplayName", default: NSFullUserName())
    static let className = SavedSetting.string(key: "className", default: "")
    static let micDeviceUID = SavedSetting.string(key: "micDeviceUID", default: "")
    static let screenCaptureDisplayUUID = SavedSetting.string(key: "screenCaptureDisplayUUID", default: "")
    static let copyInviteOnStart = SavedSetting.bool(key: "copyInviteOnStart", default: true)
    static let meetingViewsEnabled = SavedSetting.bool(key: "meetingViews.enabled", default: true)

    // Meeting window and camera (the old keys; each layout carries its own camera state now)
    static let cameraShownOnMyScreen = SavedSetting.bool(key: "cameraShownOnMyScreen", default: true)
    static let hideSelfView = SavedSetting.bool(key: "hideSelfView", default: false)
    static let speakerTileShortcutEnabled = SavedSetting.bool(key: "speakerTileShortcutEnabled", default: true)

    // Recording
    static let autoRecordOnStart = SavedSetting.bool(key: "autoRecordOnStart", default: false)
    static let recordingCountdownSeconds = SavedSetting.int(key: "recordingCountdownSeconds", default: 3)
    static let recordSystemAudio = SavedSetting.bool(key: "recordSystemAudio", default: false)
    static let clipBufferEnabled = SavedSetting.bool(key: "clipBufferEnabled", default: true)
    static let sessionNotesEnabled = SavedSetting.bool(key: "sessionNotesEnabled", default: false)

    // Browser
    static let browserRestoresTabs = SavedSetting.bool(key: "browserRestoresTabs", default: true)
    static let browserSearchSuggestions = SavedSetting.bool(key: "browserSearchSuggestions", default: true)

    // Cues (the keys keep the feature's old name, "prompter")
    static let cuesEnabled = SavedSetting.bool(key: "prompterEnabled", default: false)
    static let cuesVideoSearch = SavedSetting.bool(key: "prompterVideoSearch", default: true)
    static let cuesUseModel = SavedSetting.bool(key: "prompterUseModel", default: false)
    static let cuesSaveTranscript = SavedSetting.bool(key: "prompterSaveTranscript", default: true)
    static let cuesUseWhisper = SavedSetting.bool(key: "cuesUseWhisper", default: false)
    static let cuesLocaleIdentifier = SavedSetting.string(key: "prompterLocaleIdentifier", default: "")

    // YouTube
    static let youtubeUploadMode = SavedSetting.choice(key: "youtubeUploadMode", default: YouTubeUploadMode.off)
    static let youtubePrivacy = SavedSetting.string(key: "youtubePrivacy", default: "unlisted")
    static let youtubeClientID = SavedSetting.string(key: "youtubeClientID", default: "")
    /// Absent until chosen; `YouTubeRouteRules.initialPrefersOwnApp` decides what absent means.
    static let youtubeUsesOwnApp = SavedSetting.optionalBool(key: "youtubeUsesOwnApp")
    static let youtubeMadeForKids = SavedSetting.optionalBool(key: "youtubeMadeForKids")
    static let youtubeChannel = SavedSetting.optionalJSON(key: "youtubeChannel", other: YouTubeChannel(name: "A", avatarURL: nil))

    // Privacy
    static let analyticsEnabled = SavedSetting.bool(key: "analyticsEnabled", default: true)

    /// Every setting above, for the tests: no shared key, every key round-trips, nothing missing.
    static let all: [SavedSettingInfo] = [
        meetingMode.info, meetingPresets.info, sdkClientID.info, s2sAccountID.info, s2sClientID.info,
        userDisplayName.info, className.info, micDeviceUID.info, screenCaptureDisplayUUID.info,
        copyInviteOnStart.info, meetingViewsEnabled.info,
        cameraShownOnMyScreen.info, hideSelfView.info, speakerTileShortcutEnabled.info,
        autoRecordOnStart.info, recordingCountdownSeconds.info, recordSystemAudio.info, clipBufferEnabled.info,
        sessionNotesEnabled.info,
        browserRestoresTabs.info, browserSearchSuggestions.info,
        cuesEnabled.info, cuesVideoSearch.info, cuesUseModel.info, cuesSaveTranscript.info,
        cuesUseWhisper.info, cuesLocaleIdentifier.info,
        youtubeUploadMode.info, youtubePrivacy.info, youtubeClientID.info, youtubeUsesOwnApp.info,
        youtubeMadeForKids.info, youtubeChannel.info,
        analyticsEnabled.info,
    ]
}
