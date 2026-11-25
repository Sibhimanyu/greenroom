# Settings transfer: one list of settings, and a file that carries all that should travel

Branch: sibhimanyu/hi. Terms: `GLOSSARY.md` (Settings file, Travels). Code: `App/Settings/`. Tests: `Tests/SettingsTransferTests.swift`, `Tests/SettingsCatalogTests.swift`.

## Problem

Settings export/import (`SettingsTransfer`) lived inside `CoordinatorController.swift`. Every setting was spelled by hand in five places (the property and its `didSet`, the load in `init` with its default, the transfer field, the export argument, the import line). Nothing said which persisted settings were left out on purpose and which were forgotten, and no test covered any of it. An audit found that a colleague importing a file got a Mac set up "most of the way": the camera background, the meeting name, the chosen microphone, the meeting window's view and a dozen toggles never travelled.

## Goals

- One catalog lists every persisted setting key, with its default and whether it travels or why it does not.
- A test fails the moment a persisted key is neither exported nor excluded with a written reason.
- The settings in D1 travel.
- The pure part (file format, catalog, validation rules) compiles into `GreenroomTests` without the coordinator or the Zoom SDK.
- Old files keep importing.

## Non-goals

- No new export format, no version field, no encryption of the plaintext secrets.
- `didSet` side effects stay on the coordinator's published properties.
- No change to what the Transfer page looks like, except one extra sentence in the import result (R6).

## Decisions

- D1. Travel (added): `cameraBackground`, `cameraBackgroundImage` (a preset by name), `className`, `meetingMode`, `copyInviteOnStart`, `sessionNotesEnabled`, `camera.mirrorSelfView`, `presence.visibleToRecorders`, `meetingWindow.view`, `.shareLayout`, `.shareSplit`, `.hideSelfView`, `.hideVideoOff`, `meetingViews.enabled`, `micDeviceUID` (applied only if that microphone is connected on this Mac, like `cameraDirector`'s `availableOnly`). Stay out, with a reason: see "Excluded settings".
- D2. A custom camera background picture (`custom-...`) travels as a setting but not as a file. On import, if no custom picture file is on this Mac, the background becomes Blur and the import result says the picture did not travel. (The check is "a custom picture file exists on this Mac", as decided. If this Mac has its own custom picture, that one shows, because the key only names "the custom picture".)
- D3. File format unchanged: same JSON keys for existing fields, every field optional, unknown keys ignored, no version field. New fields are new optional keys, so older files still import and newer files import into older builds, which ignore them.
- D4. A guard test fails when a persisted key is in neither the export list nor the exclusion list.
- D5. Export and import leave `CoordinatorController.swift` for `App/Settings/`. A single catalog holds key, default and disposition. Import still assigns through the published properties and keeps every validation. The pure part is compiled into `GreenroomTests`.
- Validation becomes a pure step: `SettingsImportRules.sanitized(transfer, environment)` returns the transfer with invalid or unavailable fields removed, and a list of notes for the person. The coordinator then assigns what is left. One place to read to know what import refuses.
- Settings kept only in `UserDefaults` with no published property (the meeting window's choices, the toggles) are read and written by a small pure bridge that takes an injected `UserDefaults`, so a test never touches the real ones.
- The guard finds persisted keys by scanning `App/**/*.swift` for `UserDefaults`/`defaults` reads and writes, `@AppStorage` and `...Key = "..."` constants. It is a net, not a proof: a key built at run time is invisible to it, and the catalog says so for the one such family (window frames).

## Requirements

### R1. The pure part compiles into the test target

The transfer struct, catalog, import rules and the defaults bridge import Foundation only and are listed in `GreenroomTests.sources`. `CoordinatorController` holds no `SettingsTransfer` declaration.

Acceptance: `xcodebuild test -scheme GreenroomTests` builds and runs them; `grep "struct SettingsTransfer" App/CoordinatorController.swift` finds nothing.

Tests: the Settings tests compile only if this holds.
Status: built.

### R2. The existing fields round-trip and keep their JSON keys

Every field that exists today encodes under its current name and decodes back equal. Export is pretty-printed with sorted keys.

Acceptance: a transfer with every field set round-trips; the encoded key set equals the list of today's keys plus the D1 keys.

Tests: `testEveryFieldRoundTrips`, `testEncodingIsPrettyPrintedAndSorted`, `testExistingKeysKeepTheirNames`.
Status: built.

### R3. Existing validations hold

- `prompterEnabled` is dropped unless Cues is released in this build.
- `cuesUseWhisper` becomes `value && whisperAvailable` where the check exists, and is carried as it is where it does not (macOS 14/15).
- `recordingCountdownSeconds` outside 0, 3, 5, 10 is dropped.
- A layout template's saved second display is cleared when that display is not connected.
- Unknown keys are ignored; a file that omits a field leaves that setting alone.

Tests: `testCuesEnabledNeedsARelease`, `testWhisperIsAndedWithAvailability`, `testWhisperCarriedWhenNotCheckable`, `testCountdownMustBeOneOfTheOffered`, `testSecondDisplayClearedWhenNotConnected`, `testImportedLibraryGetsLocalDisplays`, `testOmittedFieldsStayNil`, `testUnknownKeysAreIgnored`.
Status: built.

### R4. Every persisted key is classified (guard)

Each persisted key is in the catalog as `travels`, `importOnly` or `excluded(reason)`. Every `SettingsTransfer` property is named by a catalog entry, and every travelling entry names a real property. No stale entries.

Acceptance: adding a persisted key without classifying it fails the test and names the key.

Tests: `testEveryPersistedKeyIsClassified`, `testEveryTransferFieldIsInTheCatalog`, `testEveryTravellingEntryHasATransferField`, `testExcludedEntriesGiveAReason`, `testCatalogHasNoStaleKeys`, `testKeysAreListedOnce`.
Status: built.

### R5. The D1 settings travel

Export carries them; import applies them (through the published property where one exists, else through the defaults bridge). Values that are not valid for their type (an unknown view name, a split outside its range, an unknown meeting mode) are dropped or clamped as the setting does itself.

Acceptance: a transfer with the D1 fields applied to an empty defaults suite writes each key; read back into a transfer, it equals the original.

Tests: `testBridgeRoundTripsTheKeptOnlyInDefaults`, `testUnsavedSettingsExportTheirDefaults`, `testApplyTouchesOnlyWhatTheFileCarries`, `testKeysMatchTheViewsOwnConstants` (SettingsDefaultsBridgeTests); `testMeetingWindowSplitIsClamped`, `testUnknownMeetingViewIsDropped`, `testUnknownBackgroundNameIsDropped` (SettingsImportRulesTests). `meetingMode` is checked against `MeetingMode` by the coordinator, as `webcamShape` is.
Status: built.

### R6. A missing custom picture falls back to Blur, and says so

With `cameraBackground == Image` and a `custom-...` picture, and no custom picture file on this Mac: background becomes Blur, the picture key is not imported, and the import result carries one note. A preset picture never falls back. A custom key under Normal or Blur needs no note, because the picture is not in use.

The note reads: "The background picture did not travel (it is a file on the other Mac), so your background is set to Blur." The Transfer page shows it after "Imported from <file>"; Onboarding shows it after the same sentence.

Tests: `testCustomPictureMissingFallsBackToBlur`, `testCustomPictureMissingWhileNotInUseNeedsNoNote`, `testCustomPicturePresentIsKept`, `testPresetPictureNeverFallsBack`.
Status: built.

### R7. The microphone applies only if it is connected

`micDeviceUID` is applied if it is empty (the system input) or names a microphone connected now; otherwise this Mac keeps its own.

Tests: `testMicrophoneAppliedWhenConnected`, `testMicrophoneDroppedWhenNotConnected`, `testSystemInputMicrophoneAlwaysApplies`.
Status: built.

### R8. Old files still import

A fixture file written in today's format (before this work) decodes, sanitizes and applies without error. Keys the fixture lacks stay nil.

Tests: `testTodaysExportFixtureStillDecodes`, `testOldFileLeavesEveryNewSettingAlone`, `testLegacyOnlyKeysStillDecode`, `testNewKeysAreAdditiveOnly`.
Status: built.

### R9. Import assigns through the published properties

Import still assigns through the coordinator's `@Published` properties so `didSet` runs, mutes analytics setting events during import, and keeps the legacy-layout migration.

Acceptance: code review plus the Debug build; the manual check below.
Status: built (verified live waits on the owner).

## Excluded settings

| Key | Reason |
|---|---|
| `analyticsEnabled` | Consent. Each Mac asks itself. |
| `hasCompletedOnboarding` | A new Mac runs onboarding. |
| `watchPlayerVolume` | Per Mac listening level. |
| `sessionsShow`, `sessionsSort`, `sessionsNeed`, `sessionsSidebarHidden`, `sessionPanelHidden` | View state of this Mac's window. |
| `NSWindow Frame ...`, `recordingControlBar.frame`, `meetingControlBar.*` | Window positions; screens differ per Mac. |
| `meetingShrinkTip.done`, `shareVisibility.explained`, `analysisSetupSeen` | Tip and "seen" flags: each Mac shows its own once. |
| `screenroomStageTimings` | Measured on this Mac's hardware. |
| `browserLastSession*` | This Mac's open tabs. |
| `layoutLibrary.knownStarters` | Bookkeeping of which starter layouts this Mac has seen. |
| `youtubeUploadConfirmed` | A consent the person gives on their own Mac. |
| `youtubeRefreshToken`, `zoomUser*`, `account.mock.*` | Accounts and tokens: each Mac signs in itself. |
| `screenroomTranscriberSettings` (model path) | Absolute path to a file on the exporting Mac. Only the language travels. |
| `customUIMode.migratedV2`, `GreenroomRawVideoSpike` | Migration marker and debug switch. |

## Open questions

- `participantPanelOnMainDisplay` is a retired field (setting gone, key still decoded); the catalog lists it under `retiredTransferFields`.
- None blocking. `speakerTileShortcutEnabled` stays import-only on purpose (older files carry it; nothing writes it).

### Verification state

Unit tests and the Debug build pass. Nothing is verified live; see the manual check.

## Manual check (owner)

- [ ] Export on this Mac. Open the file: it has `cameraBackground` and the other D1 keys.
- [ ] Import that file back. Nothing changes and no note appears.
- [ ] Import an old export file (from before this change). It imports, with no error.
- [ ] Choose a custom background picture, export, delete the picture folder (`~/Library/Application Support/Greenroom/CameraBackground`), import. The background becomes Blur and the page says the picture did not travel.
- [ ] Export with a microphone that is not plugged in on the importing Mac. Import leaves the importing Mac's microphone alone.
