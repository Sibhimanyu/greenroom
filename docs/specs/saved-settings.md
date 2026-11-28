# Saved settings: one owner for every setting the app keeps in UserDefaults

Branch: sibhimanyu/saved-settings-store. Style models: [camera-look.md](camera-look.md) (same refactor for four settings), [session-phase.md](session-phase.md). This is a refactor: no behaviour changes, no stored value is migrated.

## Terms

**Saved setting** (new, GLOSSARY.md): one value the app remembers between launches in UserDefaults, declared once with its key, its type and its default.

## Problem

Survey of a5027cf, 2026-11-28. `CoordinatorController` holds about thirty `@Published var x { didSet { defaults.set(x, forKey: "someKey") } }` properties. Each setting's key, type and default sit in two to four places:

- the property and its `didSet` (the key, as a string literal),
- the load in `init()` (the key again, and the default, in one of four spellings: `?? ""`, `?? true`, `defaults.bool(forKey:)`, `YouTubeUploadMode(rawValue: ... ?? "") ?? .off`),
- `SettingsCatalog` (the key and the default again, for the settings file),
- `SettingsKeys` and `SettingsDefaultsBridge` (the key and the default a third time, for the settings kept only in UserDefaults), and the views' own constants (`copyInviteOnStartKey`, `SessionNotesBar.enabledKey`, `MeetingViewPieces.defaultsKey`).

Nothing makes the four agree. `autoRecordOnStart` shows the cost: a comment in `init` says "On unless the teacher turned it off" while the line under it loads `false`.

## Decisions

- D1. One value type, `SavedSetting<Value>`, holds a setting's key, default and how it is read and written. It is Foundation only and compiled by the test target.
- D2. One list, `SavedSettings` (`App/Settings/SavedSettings.swift`), declares every saved setting once. Its `all` lists each one for the tests.
- D3. The `UserDefaults` is passed in (`load(from:)`, `save(_:to:)`), so a test uses an in-memory suite and never touches the real one.
- D4. Persistence does not change. Same keys, same stored types (Bool, Int, String, raw string of an enum, JSON `Data`), same defaults. A missing key or a value of the wrong type reads as the default, as before.
- D5. `@Published` and every `didSet` side effect stay on the coordinator. Only the line that wrote the key and the line that read it move. Views keep binding `$coordinator.x`.
- D6. No property wrapper. A wrapper would fight `@Published`; a plain value with `load` and `save` does not.
- D7. `MeetingMode` moves to its own file (`App/Settings/MeetingMode.swift`, same code) so the test target can compile it. Nothing else about it changes.
- D8. The settings file keeps its field names and its catalog. Keys the file's `SettingsKeys` and `SettingsDefaultsBridge` used are read from `SavedSettings`.

## What is in

34 settings. Key, type, default as the old `init` loaded it, and what the `didSet` does besides saving (all of it stays).

| Setting (coordinator name) | Key | Type | Default | `didSet` does besides saving |
| --- | --- | --- | --- | --- |
| `meetingMode` | `meetingMode` | `MeetingMode` raw String | `create` | nothing |
| `meetingPresets` | `meetingPresets` | JSON `[MeetingPreset]` | `[]` | nothing (an encode failure writes nothing) |
| `sdkClientID` | `zoomSDKClientID` | String | `""` | nothing |
| `s2sAccountID` | `zoomS2SAccountID` | String | `""` | nothing |
| `s2sClientID` | `zoomS2SClientID` | String | `""` | nothing |
| `userDisplayName` | `userDisplayName` | String | `NSFullUserName()` | nothing |
| `cameraShownOnMyScreen` | `cameraShownOnMyScreen` | Bool | `true` | nothing (import-only) |
| `hideSelfView` | `hideSelfView` | Bool | `false` | analytics, `zoomChatClient.setHideSelfView` |
| `speakerTileShortcutEnabled` | `speakerTileShortcutEnabled` | Bool | `true` | nothing (import-only) |
| `micDeviceUID` | `micDeviceUID` | String | `""` | `applyMeetingMicrophone()` while running |
| `browserRestoresTabs` | `browserRestoresTabs` | Bool | `true` | pushes to `BrowserWindowController`, analytics |
| `browserSearchSuggestions` | `browserSearchSuggestions` | Bool | `true` | pushes to `BrowserWindowController`, analytics |
| `cuesEnabled` | `prompterEnabled` | Bool | `false` | analytics |
| `cuesVideoSearch` | `prompterVideoSearch` | Bool | `true` | analytics |
| `cuesUseModel` | `prompterUseModel` | Bool | `false` | analytics |
| `cuesSaveTranscript` | `prompterSaveTranscript` | Bool | `true` | analytics |
| `cuesUseWhisper` | `cuesUseWhisper` | Bool | `false` | analytics |
| `cuesLocaleIdentifier` | `prompterLocaleIdentifier` | String | `""` | nothing |
| `youtubeUploadMode` | `youtubeUploadMode` | `YouTubeUploadMode` raw String | `off` | analytics |
| `youtubePrivacy` | `youtubePrivacy` | String | `unlisted` | analytics |
| `youtubeClientID` | `youtubeClientID` | String | `""` | nothing |
| `youtubeUsesOwnApp` | `youtubeUsesOwnApp` | Bool, may be absent | absent (`YouTubeRouteRules.initialPrefersOwnApp` decides at launch) | nothing |
| `youtubeMadeForKids` | `youtubeMadeForKids` | Bool, may be absent | absent; setting nil removes the key | nothing |
| `youtubeChannel` | `youtubeChannel` | JSON `YouTubeChannel`, may be absent | absent; setting nil removes the key | nothing |
| `analyticsEnabled` | `analyticsEnabled` | Bool | `true` | `Analytics.setEnabled` |
| `screenCaptureDisplayUUID` | `screenCaptureDisplayUUID` | String | `""` | nothing |
| `autoRecordOnStart` | `autoRecordOnStart` | Bool | `false` | analytics |
| `recordingCountdownSeconds` | `recordingCountdownSeconds` | Int | `3` | nothing |
| `recordSystemAudio` | `recordSystemAudio` | Bool | `false` | analytics, recorder flag, rebuilds a running capture |
| `className` | `className` | String | `""` | nothing |
| `clipBufferEnabled` | `clipBufferEnabled` | Bool | `true` | analytics |
| `copyInviteOnStart` | `copyInviteOnStart` | Bool | `true` | no property: a view's `@AppStorage`, read by `copyInviteWhenReady` |
| `sessionNotesEnabled` | `sessionNotesEnabled` | Bool | `false` | no property: a view's `@AppStorage` |
| `meetingViewsEnabled` | `meetingViews.enabled` | Bool | `true` | no property: read by `MeetingViewPieces` |

## What stays out, and why

- **Secrets.** `zoomSDKClientSecret`, `zoomS2SClientSecret`, `youtubeClientSecret` are in the Keychain through `SecretStore`. Not touched.
- **Camera look** (`backgroundRemoval`, `cameraBackground`, `cameraBackgroundImage`, `camera.mirrorSelfView`). Done by [camera-look.md](camera-look.md); `CameraLook` is their owner. `SettingsKeys` now reads their keys from it, so the key is still spelled once.
- **Meeting setup and layouts** (`layoutLibrary`, the camera piece, the share). Own module ([meeting-setup.md](meeting-setup.md)).
- **The meeting window's choices** (`meetingWindow.*`). `MeetingViewPrefs` is their owner and already takes an injected `UserDefaults`.
- **`zoomPrefersSignIn`.** Its first value depends on sign-in state and the stored secrets, and `init` saves it once when missing. `ZoomRouteChoiceRules` owns that.
- **`zoomRefusedAccountIDs`.** Encoded and decoded by `ZoomRefusalRules`.
- **`hasCompletedOnboarding`.** A one-shot flag written once; converting it adds nothing.
- **Settings with their own owner elsewhere** (shortcuts, Screenroom, camera director, stage fractions, window frames, one-time migration markers, tokens). Not in `CoordinatorController`, and each has its own loader.
- **The Debug-only switch** `ZoomSignInAvailability.debugSignInOnKey`.

## Requirements

**R1. Every saved setting is declared once.** (D1, D2) planned
- R1.1 `SavedSettings.all` lists 34 settings, one per row of the table above. A test reads `SavedSettings.swift` and fails when a `SavedSetting` is declared there and missing from `all`.
- R1.2 No two settings share a key. No setting shares a key with `CameraLook`.
- R1.3 A setting is declared with its key, its type and its default only here. Nothing else under `App/` spells these keys as a string literal for reading or writing (the guard in `SettingsCatalogTests` still finds every key in the sources).

**R2. They load under the old keys with the old defaults.** (D4) planned
- R2.1 Given an empty store, each setting loads the default in the table. A table of the old `init` defaults is written out in the test, apart from the module.
- R2.2 Given a store written the old way (the same key, the same stored type), each setting loads that value.
- R2.3 Given a key holding a value of another type, or a string that is not one of an enum's cases, or JSON that does not decode, the setting loads its default and nothing is written.
- R2.4 `autoRecordOnStart`, `cuesEnabled`, `cuesUseModel`, `cuesUseWhisper`, `recordSystemAudio` (default `false`) read like `bool(forKey:)` did. The ones with default `true` read like `(object(forKey:) as? Bool) ?? true` did.
- R2.5 The three optional settings (`youtubeUsesOwnApp`, `youtubeMadeForKids`, `youtubeChannel`) give nil when the key is absent, through `stored(in:)`. `cameraShownOnMyScreen` gives nil the same way for the layout fallbacks that need "never saved".

**R3. They save under the same keys.** (D4) planned
- R3.1 `save` writes the same key with the same stored type as the old `didSet`. A saved value loads back equal, for every setting.
- R3.2 Saving nil to an optional setting removes the key.
- R3.3 A value that cannot be encoded writes nothing for `meetingPresets`, and removes the key for `youtubeChannel`, as before.

**R4. The coordinator goes through it.** (D5) planned
- R4.1 Each property in the table (the ones that have one) saves with `SavedSettings.x.save(...)` and loads with `SavedSettings.x.load(from:)`. `CoordinatorController.swift` has no `forKey:` string literal left for them.
- R4.2 Every `didSet` side effect is as it was, in the same order, after the save.
- R4.3 `init` loads each setting exactly once, with the same default, and `autoRecordOnStart` still loads `false` when never saved.

**R5. The settings file reads the same declaration.** (D8) planned
- R5.1 `SettingsKeys` is built from `SavedSettings` keys (and `CameraLook` keys), so a key changed in one place changes everywhere.
- R5.2 `SettingsDefaultsBridge` reads its three toggles through `SavedSettings` (`copyInviteOnStart`, `sessionNotesEnabled`, `meetingViewsEnabled`) and writes them the same way. Export and import give what they gave before.
- R5.3 Where `SettingsCatalog` states a plain default (bool, int, string) for a key, it equals the `SavedSettings` default.
- R5.4 The settings-transfer requirements ([settings-transfer.md](settings-transfer.md) R1 to R9) still hold; its tests pass unchanged.

**R6. The other readers agree.** (D2) planned
- R6.1 `CoordinatorController.copyInviteOnStartKey`, `SessionNotesBar.enabledKey`, `MeetingViewPieces.defaultsKey` take their key from `SavedSettings`; the app-start analytics consent check and the legacy layout read of `speakerTileShortcutEnabled` read through it.

## Phases

| Phase | Delivers | Status | Commit |
| --- | --- | --- | --- |
| P1 | This spec, the glossary entry and the index | planned | |
| P2 | Failing tests: R1 to R3, R5.3 | planned | |
| P3 | `SavedSetting`, `SavedSettings`, `MeetingMode` moved: R1 to R3 pass | planned | |
| P4 | Wire the coordinator (batch by batch), the bridge, the key constants: R4, R5, R6 | planned | |
| P5 | Codemaps, statuses, `scripts/check.sh` green | planned | |

## Needs a live check

Nothing new is expected to differ. Worth a glance with a real settings store: launch with an existing install and see Settings, Home and the meeting mode as they were; flip a toggle, quit, relaunch; export then import a settings file.
