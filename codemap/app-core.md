# App core: root files, Account, Analytics, Audio, Browser, Chrome, Debug, YouTube

Purpose. `App/` is one SwiftUI/AppKit target (`Greenroom`, macOS 14+). The top-level files hold the
process lifecycle (`GreenroomApp`, `AppDelegate`), the one big orchestrator (`CoordinatorController`,
5.7k lines, the only object the UI talks to), system-wide shortcuts (Carbon hotkeys), and a set of small
**pure decision files** (`*Rules.swift`, `MeetingMorph`, `StartChoreography`, `RecordStartFlow`,
`MainWindowVisibility`, `MeetingBarPlacement`) that are Foundation/CoreGraphics-only so the unit-test
target compiles them directly. The sub-folders are leaf services: analytics (Zoho Apptics, privacy-first),
Apptics-free audio helpers, the built-in WebKit browser used as the "main pane", AppleScript control of
Chrome-family browsers, DEBUG-only UI tour/film hooks, YouTube upload, and a placeholder account store.

## Files

| Path | What it owns | Key types / functions |
|---|---|---|
| `App/GreenroomApp.swift` | `@main`; scenes; Heresay config; Sparkle updater; brand tokens; link constants | `GreenroomApp` (Window id `"main"`, `Settings`, `MenuBarExtra`), `Brand` (`green`, `buttonFill`, `text`, `name`, `fill`, `net`, `netText`), `AppLinks` |
| `App/AppDelegate.swift` | Launch + termination hygiene | `AppDelegate`: `applicationWillFinishLaunching` (Apptics init), `applicationDidFinishLaunching` (FieldFocusRelease, whisper resolve, `ShortcutRuntime.shared.start()`, `DebugTour.start()`), `applicationShouldHandleReopen`, `applicationShouldTerminate` (confirm quit, `windDownForQuit`), `applicationWillTerminate` (`_exit(0)`) |
| `App/CoordinatorController.swift` | Orchestrator: `@MainActor ObservableObject` with ~85 `@Published` fields; start/end session, stage, recording, layout, presets, Cues, scheduled meetings, main-window step-aside, quit wind-down, settings export/import | `CoordinatorController` (`static weak var shared`), `StartStep`, `start()` (~l.1515), `startRecordingFlow()` (~l.2606), `prepareForTermination()`, `windDownForQuit()`, `confirmQuitWhileLive`, `bringLiveSessionForward`, `applyMainWindow`, `applyPreset`, `useLayout`, `loadSecretsIfNeeded`; `// MARK:` sections list the areas (Onboarding, Start-a-meeting S2S, Defaults, Cues, YouTube, main window steps aside, The stage, Pause/countdown, Drawing, Record mode, After a session, Asking before End/Stop, Live shape preview, Meeting window, Two sizes, Displays coming and going, Scheduled meetings, Settings transfer) |
| `App/CoordinatorController+Presence.swift` | Wires the presence bubble panel (`App/UI/PresenceBubble.swift`) to the stage | `startPresenceBubble`, `schedulePresenceRefresh`, `refreshPresenceBubble`, `previewPlacementStep`, `commitPreviewPlacement`, `applyPresencePlacement` |
| `App/HotkeyManager.swift` | Carbon `RegisterEventHotKey` wrapper (no Accessibility/Input Monitoring permission needed) | `HotkeyManager.shared`, `Hotkey{id,keyCode,modifiers,action}`, `replaceAll(_:) -> [String]` (ids that could not be claimed), `unregisterAll` |
| `App/ShortcutModel.swift` | Pure shortcut model: actions, scopes, groups, defaults, binding persistence, reserved combos | `KeyCombo` (`glyphs`, `optionCommand`), `ReservedShortcuts.reason(for:)`, `ShortcutCapture.interpret`, `ShortcutScope` (`global`/`appOnly`/`meetingWindow`), `ShortcutGroup`, `ShortcutAction` (raw values = saved ids), `ShortcutAction.defaultCombo`, `ShortcutSlot` (`.action`, per-layout, per-meeting-view), `ShortcutCatalog`, `ShortcutBindings` (JSON, lossy decode, `conflict`, `resolved`, `pruned`) |
| `App/ShortcutStore.swift` | `ObservableObject` holding bindings in UserDefaults `shortcuts.bindings` | `ShortcutStore.shared`, `assign/move/clear/reset/resetAll/replace/prune`, `glyphs(_:)`, `phrase(_:)`, `ShortcutNotice`, `setUnavailable` |
| `App/ShortcutRuntime.swift` | Turns bindings into system hotkeys; runs the action on press | `ShortcutRuntime.shared`, `start()`, `refresh()`, `perform(_ slot:)` (guards on session state) |
| `App/LiveExitRules.swift` | Pure: what to ask before close/end/quit while live; Dock reopen target | `LiveExit.closePrompt/endPrompt/quitPrompt`, `LiveExitState`, `LiveExitChoice`, `LiveExit.isSystemEnd(quitReason:)`, `reopenTarget`, `reopenHandledByMeeting` |
| `App/MeetingCollapseRules.swift` | Pure: meeting window/bar size ladder, surface plan, show-on-share | `MeetingSize`, `MeetingCollapse.next`, `MeetingSurfacePlan.decide`, `MeetingSurfaces.*`, `ShowOnShare`, `MeetingSurfaceChrome` |
| `App/MeetingShrinkRules.swift` | Pure: minimize outcome and the one-time shrink tip | `MeetingMinimize.outcome`, `MeetingShrinkTip` (defaults key `meetingShrinkTip.done`, `reset`) |
| `App/ShareVisibilityRules.swift` | Pure: "who sees this window" switch, explainer toast, shareable windows | `ShareVisibility`, `ShareVisibilityExplainer` (key `shareVisibility.explained`), `ShareableWindow`, `ShareSwitchState`, `WindowBackdrop` |
| `App/MeetingMorph.swift` | Pure: window <-> bar morph keyframes, easing, retargetable timeline | `MeetingMorph.keyframe`, `Timeline.start/progress/windowness`, `retarget`, `duration = 0.35` |
| `App/StartChoreography.swift` | Pure: what each surface shows while starting (starting = island alone with Cancel, no bar; live = bar alone; failed = island + Home); Home exit frame | `StartChoreography.surfaces(_ phase)`, `islandShowsCancel`, `homeExitFrame`, `homeSeconds`, `opensMeetingWindowOnLive`, `barKeptAfterLive`, `needsDisplayQuiet`; `barText`/`startingBarWidth` are dormant (the bar has no Starting state in use) |
| `App/RecordStartFlow.swift` | Pure state machine for Home "Start Recording": events in, actions out | `RecordStartFlow` (`Stage`, `Event`, `Action`; `stepLabels = ["Picture","Recording"]`) |
| `App/MainWindowVisibility.swift` | Pure state machine: main window steps aside while live, returns after | `MainWindowVisibility.handle(_ Event) -> [Action]` (`startBegan`, `liveChanged`, `startFailed`, `openedOnPurpose`, `quitting`) |
| `App/MeetingBarPlacement.swift` | Pure geometry for the control bar and toasts; People pop-out | `MeetingBarPlacement` (`clamp`, `snap`, `drop`, `restore`, `resized`, `notesRestingY`, `toastFloorY`, `spring`), `PeoplePopOutPlacement.frame` |
| `App/UpdateGate.swift` | Sparkle delegate: refuse scheduled update checks while a session is live | `UpdateGate.shared`, `updater(_:mayPerform:)` |
| `App/Notifier.swift` | Fire-and-forget `UNUserNotification` | `Notifier.post(title:body:)` |
| `App/Info.plist` | Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, `SUScheduledCheckInterval` 6h), usage strings, `AP_INFOPLIST_FILE` | edited by hand; Apptics pre-build script injects `AP_INFOPLIST_FILE` |
| `App/App.entitlements` | Hardened-runtime entitlements: camera + audio-input only | `com.apple.security.device.camera`, `...audio-input` |
| `App/Assets.xcassets` | `AccentColor` (brand green #5FA83C), `AppIcon`, `LogoMark`, `MenuBarMark` (template image) | referenced as `Color("AccentColor")`, `Image("MenuBarMark")` |
| `App/Account/AccountStore.swift` | PLACEHOLDER sign-in (no network) | `AccountStore.shared`, `Scope` (`youtubeUpload`, `thriveniPost`), `Profile`, `State` |
| `App/Account/ThriveniMock.swift` | Fake Thriveni assignments + fake post | `ThriveniMock.assignments`, `post(link:to:note:)` |
| `App/Analytics/Analytics.swift` | Apptics wrapper with a fixed event/property vocabulary | `Analytics.Event`, `Analytics.Key`, `track`, `feature(_:source:)`, `setting(_:_:)`, `failure(_:)`, `setEnabled`, `band(seconds:)`, `band(gigabytes:)`, `mainAppKind`, `layoutChanged` |
| `App/Audio/MicLevelMonitor.swift` | Live level of the user's mic via AVAudioEngine tap | `MicLevelMonitor` (`@Published level`, `start/stop`) |
| `App/Audio/SpeechActivity.swift` | Energy-based voiced-span detection to align/clean whisper output | `SpeechActivity.levels/threshold/voiced/overlaps/align`, `WhisperNoise.isMusic/drop/clean` |
| `App/Browser/BrowserWindow.swift` | Built-in WebKit browser window (tabs, omnibox, find, history, downloads) | `BrowserTab`, `BrowserModel`, `BrowserWindowView`, `FaviconCache`, `SuggestionPanel`, `BrowserWindowController` (`show`, `open`, `reposition`, `activate`, `close`, `owns`, `isOpen`, `restoresTabs`, `searchSuggestions`) |
| `App/Browser/BrowserHistory.swift` | Local JSON page history in Application Support | `BrowserHistory`, `Entry` |
| `App/Chrome/ChromeWindowManager.swift` | AppleScript tiling of Chrome-family browsers | `ChromeWindowManager.openWindow(bundleID:occupying:urlString:)`, `repositionFrontWindow`, `closeSessionWindow`, `chromeBundleID` |
| `App/Debug/DebugTour.swift` | DEBUG-only distributed-notification driver for UI screenshots/navigation | `DebugTour` (`start`, `handle`, cmds), `DebugTourBridge` (view), `Notification.Name("com.greenroom.debug.tour")` |
| `App/Debug/DebugFilm.swift` | DEBUG-only 60 fps film of the main window across a page change | `DebugFilm.film(_:dir:_:)` |
| `App/YouTube/YouTubeAuth.swift` | Google OAuth for desktop: system browser + loopback + PKCE; refresh token | `YouTubeAuth.connect/disconnect/accessToken/isConnected`, `LoopbackListener`, `YouTubeCallbackPage` |
| `App/YouTube/YouTubeUploader.swift` | Resumable videos.insert upload (32 MiB chunks), rename, delete | `YouTubeUploader.upload/rename/delete`, `UploadError` |
| `App/YouTube/CoordinatorController+YouTube.swift` | What happens after a recording is saved; connect/disconnect | `YouTubeUploadMode` (`off/ask/automatic`), `recordingFinished(path:)`, `uploadRecordingToYouTube`, `connectAndUpload`, `uploadToYouTube`, `renameYouTubeVideo`, `deleteYouTubeVideo`, `connectYouTube`, `disconnectYouTube` |

## How it fits

- **Entry.** `GreenroomApp` creates `@StateObject coordinator = CoordinatorController()` and `EditorViewModel`,
  injects both as environment objects into `ContentView` (`App/UI/ContentView.swift`) and the coordinator
  into `SettingsView` and `MenuBarView`. `CoordinatorController.shared` (weak static, set in init) is the
  back door for non-SwiftUI callers: `AppDelegate`, `ShortcutRuntime`, `UpdateGate`.
- **Scenes.** One `Window("Greenroom", id: "main")` (not WindowGroup, so reopen can recreate it), `Settings`,
  and `MenuBarExtra` styled `.menu` whose label is the `MenuBarMark` image (waveform prefix only while Cues
  listens on the rail). Sessions, report and editor are pages of the main window (`CoordinatorController.MainPage`), not scenes.
- **Sparkle.** `SPUStandardUpdaterController` lives in `GreenroomApp`; delegate is `UpdateGate.shared`
  (held strongly because Sparkle holds delegates weakly). Feed is `docs/appcast.xml` on GitHub Pages.
- **Heresay.** `Heresay.configure(...)` in `GreenroomApp.init`; `.heresay()` on the main window; `Heresay.introduce()` fires once, after onboarding.
- **Start/stop.** `AppDelegate.applicationShouldTerminate` -> `confirmQuitWhileLive` (uses `LiveExit.quitPrompt`)
  -> `prepareForTermination` -> async `windDownForQuit` (bounded stop of recorder, cameras, capture) -> `reply`; then `applicationWillTerminate` -> `zoomChatClient.shutdown()` -> `_exit(0)`.
- **Pure rule files -> consumers.** `MainWindowVisibility` (`mainWindowVisibility.handle(.startBegan)` etc. in the coordinator, applied by `applyMainWindow`);
  `StartChoreography` (coordinator `beginStartChoreography`, `UI/MeetingControls.swift`, `UI/MainWindowTransition.swift`);
  `MeetingMorph` (`UI/MeetingControls.swift`); `RecordStartFlow` (`startRecordingFlow`); `MeetingBarPlacement` (bar window code in `UI/MeetingControls.swift`, toasts, People pop-out);
  `LiveExit`, `MeetingSurfaces`, `ShowOnShare`, `ShareVisibility` (coordinator + meeting window UI).
- **Shortcuts.** `ShortcutStore` (state) -> `ShortcutRuntime` (observes `$bindings`, `$recordingSlot`, and `coordinator.$layoutLibrary` templates) -> `HotkeyManager.replaceAll` (Carbon). `ShortcutRuntime.perform(slot)` calls into the coordinator. UI: `App/UI/ShortcutsSettingsTab.swift`; menu items show glyphs via `ShortcutStore.glyphs(_:)`.
- **Analytics.** `AppDelegate` starts Apptics (only if `AP_INFOPLIST_FILE` is in Info.plist) and honours the `analyticsEnabled` default; ~40 call sites use `Analytics.feature/setting/track/failure` (coordinator `@Published` `didSet`s call `Analytics.setting`).
- **Browser/Chrome.** `App/Layout/MainPaneManager.swift` routes the main pane: built-in browser (`BrowserWindowController.show/reposition`), Chrome-family (`ChromeWindowManager`), else Accessibility (`AppWindowManager`). `LayoutEngine` closes/activates them. Cues card taps call `BrowserWindowController.open`. `CoordinatorController` pushes `restoresTabs`/`searchSuggestions` settings into `BrowserWindowController`.
- **Audio.** `MicLevelMonitor` is a `@StateObject` in `UI/HomeView.swift` and a static in `UI/ParticipantGridWindow.swift`. `SpeechActivity`/`WhisperNoise` are used by `Cues/CuesWhisperTranscriber.swift`, `Screenroom/ScreenroomTranscriber.swift`, `Screenroom/ScreenroomWhisper.swift`, `Recording/SessionSummary.swift`.
- **YouTube.** Recorder stop paths call `recordingFinished(path:)`; settings UI is `UI/YouTubeSettingsTab.swift`, upload prompt `UI/UploadPrompt.swift`. Client id/secret and refresh token go through `App/Zoom/SecretStore.swift` (plain UserDefaults, no Keychain).
- **Account.** `UI/AccountSettingsTab.swift` observes `AccountStore.shared`; nothing else depends on it yet.
- **Debug.** `DebugTourBridge` is attached to the main window under `#if DEBUG`; `AppDelegate` calls `DebugTour.start()` under `#if DEBUG`.

## To change X, go to Y

- Change the global hotkey defaults -> `App/ShortcutModel.swift` `ShortcutAction.defaultCombo` (defaults today, Option-Command plus: start G, end X, record R, pause Opt-Shift-P, draw Opt-Shift-D, snap S, hide meeting Z, clips 1/2/5, shrink-to-bar Cmd-M in-window only).
- Add a new shortcut action -> add a case to `ShortcutAction` (never change existing raw values), set its `scope`/`group`/`title` in `ShortcutModel.swift`, then handle it in `ShortcutRuntime.perform(_:)`.
- Refuse a key combo as reserved -> `ShortcutModel.swift` `ReservedShortcuts.entries`.
- Change what is asked on End/Close/Quit while live -> `App/LiveExitRules.swift` `LiveExit.closePrompt/endPrompt/quitPrompt`; Dock-click behaviour -> `LiveExit.reopenTarget`.
- Change when the main window hides/returns -> `App/MainWindowVisibility.swift` `handle(_:)`; the AppKit side -> `CoordinatorController.applyMainWindow` / `reconcileMainWindow`.
- Change the Start sequence text/animation/which surface shows -> `App/StartChoreography.swift` (the island carries a meeting start via `syncReadinessHUD` -> `ReadinessHUDController.show(cancellable:onCancel: cancelStart)`; the floating bar is installed only on live, in `start()`; Record start is island-only with no Cancel in its working state); the readiness checklist -> `CoordinatorController.StartStep`, `mark`, `finishStartReadiness`, `failStartReadiness`.
- Change Home "Start Recording" steps (countdown, failure, cancel) -> `App/RecordStartFlow.swift` `RecordStartFlow.handle` + `CoordinatorController.startRecordingFlow()`.
- Change the bar snapping/margins/toast floor -> `App/MeetingBarPlacement.swift` constants (`snapDistance`, `edgeMargin`, `stackGap`, `toastDefaultFloor`).
- Change the window <-> bar morph curve/length -> `App/MeetingMorph.swift` (`duration`, `ease`, `keyframe`).
- Change the shrink/collapse ladder or the "show on my share" switch -> `App/MeetingCollapseRules.swift` (`MeetingCollapse`, `ShowOnShare`), `App/MeetingShrinkRules.swift`, `App/ShareVisibilityRules.swift`.
- Change brand colours -> never hardcode: `App/Assets.xcassets/AccentColor.colorset` (global accent) and `Brand` in `App/GreenroomApp.swift` (read DESIGN.md first; list of open drift is in DESIGN.md).
- Add/rename a menu-bar item or Window command -> `App/GreenroomApp.swift` `.commands { ... }` (app menu) or `App/UI/MenuBarView.swift` (menu-bar extra; model in `UI/MenuBarModel.swift`).
- Change update-check cadence -> `App/Info.plist` `SUScheduledCheckInterval` (6h); when checks may run -> `App/UpdateGate.swift`.
- Add an analytics event/property -> `App/Analytics/Analytics.swift` `Event`/`Key` (property names are capped at 100 per app for life; reuse keys). Never pass names, meeting ids, URLs, transcript text or `localizedDescription`.
- Change quit behaviour/latency -> `CoordinatorController.windDownForQuit` (+ `boundedStop`, `boundedWait`); measure with `scripts/measure-quit.sh`; log at `~/Library/Logs/Greenroom-quit.log`.
- Add a built-in-browser feature (tab, shortcut, omnibox) -> `App/Browser/BrowserWindow.swift` (`BrowserModel` for state, `BrowserWindowView` for UI, `BrowserWindowController` for window/key monitor); history storage -> `BrowserHistory.swift`.
- Tile an external Chromium browser -> `App/Chrome/ChromeWindowManager.swift` (needs `NSAppleEventsUsageDescription` in `Info.plist`).
- Change YouTube privacy/upload mode defaults -> `CoordinatorController` `youtubeUploadMode` / `youtubePrivacy` (defaults keys `youtubeUploadMode`, `youtubePrivacy`); the post-recording flow -> `CoordinatorController+YouTube.swift`; OAuth scope -> `YouTubeAuth.scope`.
- Add a DEBUG tour command -> `App/Debug/DebugTour.swift` `handle(_:)` switch (`goto`, `appearance`, `shot`, `film`, `status`, `tree`, `live`, ...).
- Change which mic-level/whisper silence rules apply -> `App/Audio/SpeechActivity.swift`.
- Add a camera/mic/permission entitlement -> `App/App.entitlements` plus matching `NS*UsageDescription` in `App/Info.plist`.

## Gotchas

- `AppDelegate.applicationWillTerminate` ends with `_exit(0)` on purpose: Zoom SDK's ~80 dylibs crash in static destructors at normal exit. Anything needing to run at quit must be done in `windDownForQuit`/`prepareForTermination`/`applicationShouldTerminate`, not after.
- Apptics must be initialised in `applicationWillFinishLaunching`, not `didFinishLaunching` (Zoho's macOS requirement). It is a silent no-op when `apptics-config.plist` is absent (no `AP_INFOPLIST_FILE`).
- `UpdateGate.shared` must stay a strongly-held singleton (Sparkle keeps the delegate weakly). A user-pressed "Check for Updates" (`SPUUpdateCheck.updates`) is always allowed; only scheduled checks are refused while `isRunning || stageLive || isRecording`.
- `ShortcutAction` raw values are persisted in `shortcuts.bindings` (note `cycleMeetingView` keeps raw `"galleryOrSpeaker"`, `toggleMeeting` is `"hideMeeting"`). Never rename them. `.meetingWindow` scope shortcuts are never registered with the system.
- `HotkeyManager.replaceAll` returns ids that another app already owns; `ShortcutRuntime` reports them via `ShortcutStore.setUnavailable`. Dragging layout pieces changes `layoutLibrary` constantly: `ShortcutRuntime` deliberately maps to `(id, name)` and de-duplicates before re-registering.
- The test target compiles these files directly (see `project.yml` `GreenroomTests.sources`): `ShortcutModel`, `MeetingBarPlacement`, `MeetingMorph`, `MeetingShrinkRules`, `MeetingCollapseRules`, `ShareVisibilityRules`, `LiveExitRules`, `MainWindowVisibility`, `StartChoreography`, `RecordStartFlow`. They must import only Foundation/CoreGraphics/Carbon, never AppKit-coordinator types, and a NEW pure file needs adding to that list. `ShortcutStore`, `ShortcutRuntime`, `HotkeyManager`, `UpdateGate`, `Notifier` are not test-compiled.
- `CoordinatorController` is `@MainActor`; `objectWillChange` fires before a value lands, so listeners (`+Presence`, `ShortcutRuntime`) defer a beat. It publishes only discrete state, never per-frame data or meter levels; keep it that way (the presence refresh runs on every change).
- `MainWindowVisibility` hides with `orderOut`, never close/miniaturize, so Home keeps typed state; it only hides once a session is live (or at start click via `hideForStart`).
- The `GreenroomApp` main scene is `Window`, not `WindowGroup` (closing a WindowGroup window left no way to recreate it). Settings is a `Settings` scene; do not add a Settings window by hand.
- `MenuBarMark` is a one-colour template image; the label must keep the same width while recording (a wider "REC" label got hidden behind the notch). REC is shown by the bar, island and menu instead.
- `#if DEBUG` in the Debug folder: both files are wholly inside `#if DEBUG`, and so are their call sites (`AppDelegate`, `GreenroomApp`, `SettingsView`). Debug UI must never ship; verify a Release binary with `strings`. `DebugTour.defaultDir` hardcodes a per-session scratch path: pass `dir=` explicitly.
- Analytics: never forward the status log (it interpolates student names, meeting numbers, paths). `Analytics.failure` is for genuine failures only (5k errors/month cap). `setEnabled(false)` calls `Apptics.setCompleteOff(true)`.
- `AccountStore`/`ThriveniMock` are fakes with no network. Do not wire real behaviour to them without replacing them (the real design is loopback + PKCE like `YouTubeAuth`).
- YouTube: the user must supply a Google Cloud Desktop OAuth client id/secret (stored via `SecretStore`, key `youtubeClientSecret`); real-API upload has not been tested end to end. Quota ~1,600 units per upload of 10,000/day. Recordings are 1-2 GB so uploads are resumable by chunk.
- `BrowserWindowController` is all statics around one `NSWindow`/`BrowserModel`; `restoresTabs` and `searchSuggestions` are set from the coordinator and read on first `show`. Search suggestions hit Google when on; off keeps the address bar local-only.
- `ChromeWindowManager` uses AppleScript against Chrome's dictionary (works for the Chromium family incl. Ulaa/Edge/Brave/Vivaldi); needs one-time per-app Automation consent; AppleScript runs with a 30 s timeout.
- `MicLevelMonitor` taps the default input with AVAudioEngine (Zoom's own level API would fight the meeting for the mic); a zero sample rate means no device and must be guarded.
- `Brand.green` is `Color("AccentColor")`; the app accent is #5FA83C (the lime #78C000 was rejected as too highlighty). `--accent-lime`-style fills fail contrast as text.
