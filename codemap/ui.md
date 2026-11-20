# codemap: App/UI (main app surfaces)

Everything the person sees outside a live meeting's video windows lives in `App/UI/`: the one main window (Home, Sessions, a session's watch page, the report, the editor as pages), the Settings window, the menu bar menu, the setup guide, the "island" that grows from the notch, the floating Control bar, the camera bubble, recording chrome and shared building blocks (glass, tiles, segmented switcher, fields). Meeting-window, view-window and participant-panel code is in `ui-meeting.md`. Most files are split "pure rules/model" (testable, no views; compiled by the test target) vs "view/controller". Design rules: `DESIGN.md` (read before any visual change).

## Files

### Main window shell
| path | owns | key types |
|---|---|---|
| App/GreenroomApp.swift (outside UI) | Scenes, `Brand` tokens | `Window("Greenroom", id:"main")`, `Settings{}`, `MenuBarExtra`, `enum Brand` |
| UI/ContentView.swift | Root `NavigationSplitView`; Home<->page transition, window sizing, main toolbar | `ContentView`, `modeSwitcher`, `pageLayers`, `changePage` |
| UI/MainWindow.swift | Find main window by scene id (not title) | `MainWindow.current/matches` |
| UI/MainWindowTransition.swift | Home steps toward Control bar on Start | `MainWindowTransition.hide/show` |
| UI/PageChrome.swift | Back button (Cmd-[) + subtitle on pages | `PageBack`, `.pageToolbar` |
| UI/SidebarRules.swift | Sidebar visibility/width; Home toolbar min-width arithmetic | `SidebarRules`, `HomeToolbarRules` |
| UI/WindowFrost.swift | Frosted window backdrop (only-you-see-this) | `WindowFrost`, `FrostedWindow` |
| UI/WindowFrameRules.swift | Window frame maths | `WindowFrameRules` |
| UI/LaunchSplash.swift | Launch logo animation over frosted window | `LaunchSplashCover`, `SplashMarkView` |
| UI/SessionFinishedCard.swift | Overlay after a meeting/take ends (Watch, Edit, Upload) | `SessionFinishedCard` |

### Home (and Record view)
Record is `MeetingMode.record` (enum in CoordinatorController.swift; Create / Scheduled(`.join`) / Record), shown by the same `HomeView`.
| path | owns | key types |
|---|---|---|
| UI/HomeView.swift (1646 lines) | Picture card left, setup column right: name, dock chips, readiness, Start button, scheduled picker, status log | `HomeView` (`pictureCard`, `setupColumn`, `shareChip`, `cameraChip`, `micChip`, `layoutChip`, `readyRow`, `primaryButton`, `scheduledPicker`) |
| UI/HomeCalmRules.swift | Pure: one-line setup summary, readiness reduction | `SetupSummary`, `ReadinessSummary`, `ReadinessItem` |
| UI/LookSummary.swift | "what Start will send" line | `LookSummary`, `LookSummaryLine/Row` |
| UI/DockHint.swift | Hover card with mini visual on dock chips | `DockHintPanel`, `DockHintCard`, `.dockHint` |
| UI/PreviewCameraDrag.swift | Drag layer over live preview (move camera in output) | `PreviewCameraDragLayer`, `CroppedLivePicture` |
| UI/PreviewFrameRules.swift / PreviewOutlineRules.swift | Preview crop, camera rules, outline placement (pure) | `PreviewFrameRules`, `LayoutCameraRules`, `PreviewOutlineRules` |
| UI/LayoutChoiceMenu.swift | "Layout: name" menu under Start, also in menu bar | `LayoutChoiceItems/Line` |
| UI/NewScheduledMeetingSheet.swift | New scheduled meeting sheet | `NewScheduledMeetingSheet` |
| UI/AnalysisSetupPanel.swift | "How to analyse" sheet | `AnalysisSetupPanel` |

### Sessions, watch page, report
| path | owns | key types |
|---|---|---|
| UI/RecordingsView.swift | The page host: scan of ~/Documents/Greenroom, grid/detail/report routing by `coordinator.mainPage`, rename/upload dialogs | `RecordingsView`, `.Session`, `.Recording` |
| UI/SessionsSidebar.swift | Sidebar column (filters, badges) + View menu commands | `SessionsSidebar`, `SessionsSidebarModel`, `SidebarCommands` |
| UI/SessionsContent.swift / SessionsRow.swift | Timeline grouped by day; row; card; inspector model | `SessionsLayout`, `SessionCard`, `SessionRow`, `SessionInspectorModel` |
| UI/SessionsQuery.swift / SessionsIndex.swift | Pure filter/sort/count/chips/transcript search; per-folder extras | `SessionsQuery`, `SessionChips`, `TranscriptSearch`, `SessionsIndex` |
| UI/SessionSelection.swift | Finder-style multi-select, trash plan | `SessionSelection`, `SessionTrashPlan` |
| UI/SessionDetailContent.swift / SessionDetailRules.swift | Watch page layout (picture, timeline, rail, cards) and pure rules | `SessionDetailPage`, `SessionDetailToolbar`, `SessionDetailRules` |
| UI/SessionTimeline.swift | The watch page's one control bar: skip back/forward 10s, play, time, track, duration, mute (volume slider opens on hover), speed, full screen; all with `.help` | `SessionTimeline` |
| UI/PlayerControlRules.swift | Pure: skip clamping, volume glyph and saved level (`watchPlayerVolume`), key map, full-screen auto-hide (2.5s). Tests: PlayerControlRulesTests | `PlayerControlRules`, `PlayerKeyAction` |
| UI/FullScreenPlayer.swift | Full screen: a borderless black window over the display sharing the page's AVPlayer, glass control bar, controls and cursor auto-hide; own key and mouse monitors | `WatchFullScreen`, `WatchPlayerState`, `PlayerVolumeStore` |
| UI/SessionTimeline.swift, SessionMoments.swift, SessionTranscriptView.swift, SessionTitleSuggester.swift | Timeline, moments tab, transcript tab, suggested titles | `SessionTimeline`, `SessionMomentsList`, `SessionTranscriptView`, `SessionTitleSuggester` |
| UI/SessionNotesBar.swift | Floating notes bar during any session | `SessionNotes.shared`, `SessionNotesBarContent` |

### Settings window (8 tabs; SettingsView.swift)
| path | owns |
|---|---|
| UI/SettingsView.swift | `TabView`, tab order/heights, Cmd-1..8, notifications `.showWebcamSettings` / `.showSettingsTab` |
| UI/WebcamPage.swift (+ WebcamShapePreview, CameraSwitchSection, MicrophoneSection, ShareTargetSettings) | Webcam tab: `WebcamSettingsTab` feeds `WebcamPageContent`; `BubbleDragLayer`; `CameraSwitchSection` (two-camera cut) |
| UI/LayoutSettingsTab.swift (+ LayoutCanvas, LayoutAddPanel, LayoutAppOrdering, LayoutScreenPreview) | Layout creator: `LayoutSettingsTab`/`LayoutPageContent`, `LayoutCanvas`, `LayoutPieceTile`, `LayoutAddPanel` |
| UI/ShortcutsSettingsTab.swift | `ShortcutRecorderField` |
| UI/ZoomSettingsTab.swift, YouTubeSettingsTab.swift, CuesSettingsTab.swift, TransferSettingsTab.swift | other tabs; `Cues*` rows reused by onboarding |
| UI/AccountSettingsTab.swift | DEBUG only (mock Thriveni account) |
| UI/SettingsKit.swift | Shared Settings parts: `Collapsible`, `Collapse`, `ChoiceTile`, `PictureChip`, `StatusBadge` |

### Menu bar, island, floating surfaces, onboarding, chat
| path | owns | key types |
|---|---|---|
| UI/MenuBarModel.swift / MenuBarView.swift | Pure menu items from state; SwiftUI `.menu` rendering | `MenuBarModel.items`, `MenuBarState`, `MenuBarView` |
| UI/NotchStatusController.swift / NotchStatusRules.swift | The island (one pill: failure > countdown > status > FIFO of prompts/toasts) | `NotchStatusController.shared`, `NotchStatusModel`, `IslandQueue`, `IslandRules`, `NotchGeometry` |
| UI/Toast.swift, UploadPrompt.swift | Facades into island | `ToastController.show`, `UploadPromptCard.show` |
| UI/MeetingControls.swift | Floating Control bar (pill/puck) panel + `MeetingControlsModel` | `MeetingControlBarController`, `MeetingControlBarRoot` |
| UI/MeetingBarModel.swift, MeetingBarContent.swift | Pure bar cell rules; cell views | `MeetingBarModel`, `MeetingBarLayout`, `MeetingBarContent` |
| UI/RecordingChrome.swift | Record-only bar + border while recording | `RecordingChrome`, `RecordingControlBarController`, `RecordingBorderController` |
| UI/PresenceBubble.swift, PresenceBubbleInteractionView.swift | Floating camera bubble that drives the picture | `PresenceBubble`, `PresenceFeed`, `PresenceQuickModel` |
| UI/OnboardingView.swift, OnboardingWindow.swift, OnboardingPlacement.swift | Setup guide: own window, 7 pages | `OnboardingView`, `OnboardingWindowController.shared` |
| UI/ChatWindow.swift (+ChatGrouping, ChatMessageRow, ChatMessageField) | Chat window | `ChatWindowController`, `ChatWindowView`, `ChatGrouping` |
| UI/WhiteboardViews.swift, AnnotationToolbar.swift | Whiteboard/annotation (Recorditor port) | `WhiteboardWindowController`, `AnnotationToolbarView` |
| UI/WindowShareController.swift | Per-window "show to class" eye | `WindowShareController`, `ShareableWindowAnchor`, `LayoutShareChoice` |
| UI/PresentMenuSpec.swift, PresentMenuLive.swift | Present menu as data + live wiring | `PresentMenu`, `CoordinatorController.presentMenu` ext |

### Shared components / tokens
| path | owns |
|---|---|
| UI/Glass.swift | `.greenroomGlass(in:interactive:)`, `.greenroomGlassButton`, `GreenroomGlassAppKit.makeBacking/host/prepare` |
| UI/Tiles.swift + TileAppearance.swift | `.greenroomTile(role:radius:)`, `GreenroomTileStyle`, pure `TileAppearance` |
| UI/Segmented.swift + SegmentedMath.swift | `GreenroomSegmented` (the only segmented switcher) |
| UI/Fields.swift | `GreenroomFieldStyle`, `FieldFocusRelease` |
| UI/ParticipantAvatar.swift | `ParticipantAvatar` |
| UI/ClosureButton.swift | NSButton with closure, answers first click |

## How it fits
- Scenes (GreenroomApp.swift): main `Window("Greenroom", id:"main")` hosts `ContentView` with `.tint(Brand.green)`, `LaunchSplashCover`, `FrostedWindow`; `Settings { SettingsView }`; `MenuBarExtra { MenuBarView }` (label = `MenuBarMark` image, `.menuBarExtraStyle(.menu)`). Everything else is an AppKit controller (below). Sessions/report/editor are NOT scenes: they are pages (`CoordinatorController.MainPage`: home, sessions, detail(id), report(id), editor(id)) rendered by `ContentView.pageLayers` (`HomeView` and `RecordingsView` overlaid, crossfaded by `changePage`).
- Main toolbar (ContentView `.toolbar`): on Home: `modeSwitcherItem` (principal `GreenroomSegmented` bound to `coordinator.meetingMode`), Sessions icon, fixed `ToolbarSpacer`, Setup guide + Settings group. On pages: `.pageToolbar` Back + subtitle.
- State: `CoordinatorController` (App/CoordinatorController.swift, `@EnvironmentObject`) feeds all views; pure `*Rules`/`*Model` files are called by the views and by Tests/.
- AppKit windows opened by static controllers: island (`NotchStatusController.shared`, non-activating panel over menu bar), Control bar (`MeetingControlBarController.install`), onboarding (`OnboardingWindowController.sync`, called from ContentView on `coordinator.showOnboarding`), chat (`ChatWindowController.show`), whiteboard, recording chrome, presence bubble (driven from App/CoordinatorController+Presence.swift: `startPresenceBubble`, `refreshPresenceBubble`), dock hint (`DockHintPanel`).
- Pages meant to render off-screen take plain values/bindings (`WebcamPageContent`, `LayoutPageContent`, `CuesSetupContent`, `MeetingBarContent`, toolbar) and have thin coordinator-fed wrappers (`WebcamSettingsTab`, ...).

## To change X, go to Y
- Add a Settings tab -> `SettingsView.tabOrder`, `TabView` item + `.tag`, `height(for:)`; update Cmd-N hint (count) and `.showSettingsTab` users.
- Add a Settings row -> the tab's `*PageContent` (e.g. `WebcamPageContent`, `ZoomPageContent`, `TransferPageContent`); use `SettingsKit` parts; wrap dependent controls in `Collapsible(hidden:)` with `Binding.animatedCollapse()`.
- Change Home toolbar items -> `ContentView.body` `.toolbar { }`; then update `HomeToolbarRules` (SidebarRules.swift) widths.
- Change the Create/Scheduled/Record switcher -> `ContentView.modeSwitcher`, `MeetingMode` in CoordinatorController.swift.
- Change Home dock chips (Share/Camera/Mic/Layout) -> `HomeView.shareChip/cameraChip/micChip/layoutChip`; summary wording in `HomeCalmRules.SetupSummary`; readiness pills `HomeView.readyRow`, `ReadinessSummary`.
- Change Start/Record button -> `HomeView.primaryButton`, `recordControl`, `recordPicker`.
- Home window size / minimum width -> `HomeView.columnHeight/sideMargin`, `ContentView.homeWindowHeight/minimumWindowWidth/defaultWindowWidth`.
- Change the live preview crop / camera drag -> `PreviewFrameRules`, `PreviewCameraDragLayer`, `PreviewOutlineRules`.
- Change sessions grid filters/sort/chips -> `SessionsQuery.swift` (`SessionsShow/Status/Sort`, `SessionChips`), sidebar in `SessionsSidebar`.
- Change a session row/card -> `SessionsRow.swift`, `SessionsContent.swift`.
- Watch page keys (Watch mode only; Edit keeps the editor's own monitor): Space play/pause, Left/Right skip 10s, M mute, F full screen (Esc exits full screen; double-click the picture too). One monitor in `SessionDetailContent.SpaceBarPlayback`, same typing/sheet gating as Space; key map in `PlayerControlRules.action`. Full screen keys are `WatchFullScreen`'s own monitor.
- Change watch page layout -> `SessionDetailContent.SessionDetailPage` + `SessionDetailRules` (when the rail drops under the picture).
- Change the timeline/marks -> `SessionTimeline`, `SessionMarkStyle`.
- Change a menu bar item -> `MenuBarModel.items` (order/titles/shortcuts), drawn by `MenuBarView`; test `Tests/MenuBarModelTests.swift`.
- Change menu bar icon/REC label -> `GreenroomApp.swift` `MenuBarExtra` label.
- Add an island message / change sizes -> `NotchStatusRules.swift` (`IslandMessage`, `IslandContent`, `NotchGeometry`), drawing in `NotchStatusController` (`statusRow/failureLine/countdownRow/toastRow/promptRow`).
- Show a toast / ask an upload question -> `ToastController.show`, `UploadPromptCard.show`.
- Change the floating bar's cells/widths -> `MeetingBarModel.swift` (`IconCell`, `MeetingBarLayout`), `MeetingBarContent`, panel/morph in `MeetingControlBarController` (MeetingControls.swift); placement maths App/MeetingBarPlacement.swift.
- Change the Present/Share menu -> `PresentMenuSpec.swift` (data), `PresentMenuLive.swift` (wiring), `MeetingMenus.ShareMenuState` in MeetingMenuSpec.swift.
- Change the camera bubble -> `PresenceBubble` (panel, strip, handles), `PresenceBubbleInteractionView` (resize/cursor), model `PresenceQuickModel`; geometry `PresenceGeometry` (Tests/PresenceGeometryTests).
- Change recording countdown/border/control bar -> `RecordingChrome.swift`; countdown is island (`NotchStatusController.setCountdown`).
- Edit a layout editor behaviour -> `LayoutCanvas` (drag/resize), `LayoutAddPanel`, `LayoutAppOrdering`, `LayoutSettingsTab.LayoutPageContent`; layout model in App/Layout/.
- Change onboarding pages -> `OnboardingView.SetupPage` (welcome, zoom, layout, permissions, youtube, cues, ready) and `...Step` builders; window `OnboardingWindowController.sync`; placement `OnboardingPlacement.frame`.
- Add a floating panel -> use `GreenroomGlassAppKit.makeBacking` + `.prepare`, non-key `NSPanel`, follow `RecordingChrome`/`DockHintPanel`.
- Add a segmented switch / tile / text field -> `GreenroomSegmented`, `.greenroomTile`, `.textFieldStyle(.greenroom)` (Fields.swift); never new ones.
- Make a window "showable to class" -> `WindowShareController` + `ShareableWindowAnchor`; rules in App/ShareVisibilityRules.swift.
- Brand colours -> `Brand.green/buttonFill/text/name/fill/net/netText` in App/GreenroomApp.swift; accent value in App/Assets.xcassets/AccentColor.colorset.
- Chat window look/behaviour -> `ChatWindowView`, `ChatMessageRow`, grouping rules `ChatGrouping`.

## Gotchas
- DESIGN.md tokens only. Never hardcode a green (use `Brand.green`; green TEXT is `Brand.text`; lime `Brand.fill` is fill only; amber text small = `Brand.netText`; amber = leaves this Mac). App accent stays #5FA83C. DESIGN.md lists `ContentView.brandGreen` as open drift; check "Open drift to fix" before adding visual code.
- Floating surfaces (HUDs, pills, banners, toasts, notes bar) use `.greenroomGlass` / `GreenroomGlassAppKit`; never `.regularMaterial`/`NSVisualEffectView` by hand. Never glass on content. Text on glass: semantic styles.
- No painted window background on pages (no `.windowBackgroundColor` over a page); keep `.scrollContentBackground(.hidden)`.
- Chrome is the system's: toolbar/Back/search/sidebar are system; use `.navigationSubtitle` only, never `.navigationTitle` (window found by id via `MainWindow`).
- Toolbar must never overflow into the "»" chevron: `HomeToolbarRules.need/minWindowWidth` pins it (Tests/SidebarRulesTests.swift). Adding a Home toolbar item means raising those numbers and the window minimum.
- Settings: dependent controls collapse (removed, animated) when their toggle is off, via `Collapsible` + `animatedCollapse()`; not merely greyed. Reduce Motion = instant (`Collapse.animation`).
- Debug UI never ships: Account tab, debug rows (HomeView, CuesSettingsTab, SessionsSidebar, SessionDetailContent, YouTubeSettingsTab, PeoplePopOut debug count, LaunchSplash) stay behind `#if DEBUG`; check release binary with `strings`.
- UI words: "meeting", never "class", in user-visible strings (some old comments/identifiers still say class; do not copy into UI text).
- Pure rules files (`*Rules.swift`, `*Model.swift`, `*Math.swift`, `MeetingMenuSpec`, `PresentMenuSpec`) are compiled by the test target without SwiftUI/AppKit views: keep them free of view code. Tests pinning layout: SidebarRulesTests, HomeCalmRulesTests, PreviewFrameRulesTests, PreviewOutlineRulesTests, SegmentedMathTests, TileAppearanceTests, SessionsQueryTests, SessionSelectionTests, SessionDetailRulesTests, MenuBarModelTests, NotchStatusRulesTests, MeetingBarModelTests, MeetingBarPlacementTests, WindowFrameRulesTests, OnboardingPlacementTests, PresenceGeometryTests, LayoutAppOrderingTests, ChatGroupingTests, PresentMenuTests.
- Greenroom windows are excluded from screen capture by default (StageScreenSource); only windows in `ShareVisibleWindows` are in the picture. New window types must not be added to it by accident; the eye (`WindowShareController`) is the one mechanism.
- Floating panels are non-activating/never key (Control bar `BarPanel`, island, presence bubble): clicks must not steal focus. Use `acceptsFirstMouse` hosts (`FirstMouseHost`, `ClosureButton`).
- Main window is a single `Window` scene (not WindowGroup) so dock reopen works; Home is ordered out, not closed, during a start (state preserved).
- The island replaces alerts and top-centre cards: never show a card inside a Greenroom window for status.
- Segmented switchers use only `GreenroomSegmented` (spring slide, Brand fill, white label); picture choices use tiles, not segmented.
