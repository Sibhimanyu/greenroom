# codemap: App/UI (main app surfaces)

Everything the person sees outside a live meeting's video windows lives in `App/UI/`: the one main window (Home, Sessions, a session's watch page, the report, the editor as pages), the Settings window, the menu bar menu, the setup guide, the "island" that grows from the notch, the floating Control bar, the camera bubble, recording chrome and shared building blocks (glass, tiles, segmented switcher, fields). Meeting-window, view-window and participant-panel code is in `ui-meeting.md`. Most files are split "pure rules/model" (testable, no views; compiled by the test target) vs "view/controller". Design rules: `DESIGN.md` (read before any visual change).

## Files

### Main window shell
| path | owns | key types |
|---|---|---|
| App/GreenroomApp.swift (outside UI) | Scenes, `Brand` tokens | `Window("Greenroom", id:"main")`, `Settings{}`, `enum Brand` |
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
| UI/HomeTilePanels.swift | Shared shell for tile popovers: `HomeTilePanel` (header: LABEL, value, one-line summary, optional art; footer "More ... settings..." link), `HomeTileSection`, `HomeTileChoiceRow` (choice tiles), `HomeTileList` + `HomeTileListRow` (devices, trailing detail + check), `HomeTileToggleRow` + `HomeTileDependents` (collapse when off), `.homeTileKeys` (arrows move, Return picks, Esc closes). Popover itself is the system's glass | `HomeTilePanel`, `HomeTileChoiceRow`, `HomeTileListRow` |
| UI/HomeCameraPanel.swift | Camera tile popover: camera rows (check, cut order number), "No camera", switch-to-facing toggle, Switching (delay, Cut/Crossfade) only with 2+ chosen, footer to Settings -> Webcam | `HomeCameraPanel` |
| UI/HomeScreenPanel.swift | Screen tile popover: SHARE choice tiles (whole screen, a window, whiteboard, just me; Just me turns the camera on when it is off by setting, disabled only with no camera device), DISPLAYS (2+), WINDOWS grouped by app with icons, Follow slide shows, gone/permission notes, footer to Settings -> Webcam | `HomeScreenPanel` |
| UI/HomeLayoutPanel.swift | Layout tile popover: tiles with `LayoutThumbnail` diagrams (None first), Show on screen / Open this layout's apps, locked-while-live note with choices disabled, footer "Edit layouts..." to Settings -> Layout; header note + tile badge when a layout has a two-display version (`LayoutPanelRules.twoDisplayNote`) | `HomeLayoutPanel` |
| UI/HomeMicPanel.swift | Mic tile popover: microphone rows (System default, devices, "Saved microphone (not connected)"), "Record the Mac's sound" toggle, footer to Settings -> Webcam. No live meter: MicLevelMonitor opens the mic, which Home only does while live | `HomeMicPanel` |
| UI/HomeRecordPanel.swift | Auto-rec tile popover: With the meeting / When I press it choice tiles, clip-buffer toggle (length folded under it), Documents/Greenroom with Show in Finder, footer to Settings -> Webcam | `HomeRecordPanel` |
| UI/HomeMorePanel.swift | More tile popover: 4x2 grid of tiles that open each Settings tab (`.showSettingsTab`; Cues wears `CuesBetaBadge`), Help row (Setup guide), footer "All settings..." | `HomeMorePanel` |
| UI/HomeTilePanelRules.swift | Pure: which sections show, camera tap/selection/order rules, `CameraTileRules` (Look tile and Just me: on / offBySetting / noDevice; a tap on offBySetting turns the camera on via `noCamera = false` + `previewCamerasChanged()`), header value, arrow-key movement; mic, record and More-tab rules. Tests: HomeTilePanelRulesTests | `CameraPanelRules`, `ScreenPanelRules`, `LayoutPanelRules`, `MicPanelRules`, `RecordPanelRules`, `MorePanelRules`, `HomeTileKeyRules` |
| UI/DockHint.swift | Hover card with mini visual on dock chips | `DockHintPanel`, `DockHintCard`, `.dockHint` |
| UI/PreviewCameraDrag.swift | Drag layer over live preview (move camera in output) | `PreviewCameraDragLayer`, `CroppedLivePicture` |
| UI/PreviewFrameRules.swift / PreviewOutlineRules.swift | Preview crop, camera rules, outline placement (pure) | `PreviewFrameRules`, `LayoutCameraRules`, `PreviewOutlineRules` |
| UI/LayoutChoiceMenu.swift | "Layout: name" menu under Start, also in menu bar | `LayoutChoiceItems/Line` |
| UI/NewScheduledMeetingSheet.swift | New scheduled meeting sheet | `NewScheduledMeetingSheet` |
| UI/AnalysisSetupPanel.swift | "Feedback settings" sheet (More settings... target, Done only) | `AnalysisSetupPanel` |
| UI/AnalysisProgressViews.swift | Get feedback popover: Ready (steps, choices, Start) crossfading to progress; ring | `AnalysisRunPopover`, `AnalysisReadyView`, `AnalysisProgressPopover`, `AnalysisRing` |

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
| UI/TranscriptEditRules.swift (pure, tested) | Transcript rows with raw indexes for both writers (Cues `stamp<TAB>text`, Analyse `[m:ss] text`), one-row rewrite/delete keeping comments/noise/order, stamp seconds, current line, `.original` name/copy decision, stale-summary and auto-scroll rules | `TranscriptEditRules` |
| UI/SessionNotesBar.swift | Floating notes bar during any session | `SessionNotes.shared`, `SessionNotesBarContent` |

### Settings window (9 tabs, 10 in Debug with Account; SettingsView.swift)
| path | owns |
|---|---|
| UI/SettingsView.swift | `TabView`, tab order/heights, Cmd-1..9 (then Cmd-0), notifications `.showWebcamSettings` / `.showSettingsTab` |
| (rule) Settings pages clip below the toolbar | `SettingsContentClip` (SettingsView.swift) masks the Settings window's whole contentView to `contentLayoutRect` (the toolbar is a sibling view, so only scrolled-up content is cut; the frost stays). A SwiftUI mask per page did NOT hold once scrolled. Each tab only adds `.settingsPageClip()` (= hard top scroll edge). DEBUG tour `scroll y=<pt>` scrolls the Settings page to check | `SettingsContentClip`, `DebugTour.scroll` |
| UI/WebcamPage.swift (+ WebcamShapePreview, ShareTargetSettings) | Webcam tab (camera look and camera piece only; merges into Layouts in P8): `WebcamSettingsTab` feeds `WebcamPageContent`; `BubbleDragLayer` |
| UI/DevicesSettingsTab.swift (+ CameraSwitchSection, MicrophoneSection) | Devices tab (`devices`): camera cards and the two-camera cut, microphone, the four Recording toggles, "Other apps" recordings (`VisibleToRecordersRow`). Home's Camera, Microphone and Record panels' "More" open it via `.showSettingsTab` "devices" |
| UI/GeneralSettingsTab.swift | General tab (`general`): Privacy, anonymous usage analytics (`analyticsEnabled`) |
| `SettingsTabs` (in UI/HomeTilePanelRules.swift, pure) | Tab order for Settings and the Home More panel, `shortcutKey(at:)` (Cmd-1..9, Cmd-0) |
| UI/LayoutSettingsTab.swift (+ LayoutCanvas, LayoutAddPanel, LayoutAppOrdering, LayoutScreenPreview) | Layout creator: `LayoutSettingsTab`/`LayoutPageContent`, `LayoutCanvas`, `LayoutPieceTile`, `LayoutAddPanel` |
| UI/ShortcutsSettingsTab.swift | `ShortcutRecorderField` |
| UI/ZoomSettingsTab.swift (also "During the meeting": copy invite link, open notes, hide my own tile; moved from Layout; Zoom account section, then a folding "Use your own Zoom apps (advanced)" row holding the pasted SDK and Server-to-Server fields, each with a Marketplace link, numbered steps and "Show the step-by-step guide"; text and URL in `Zoom/ZoomMarketplaceGuide.swift`, kept in step with `OnboardingView.manualZoomSetup`), UI/ZoomSignInSection.swift (`ZoomSignInSection`: Sign in with Zoom / Signed in as / Sign out, shared with onboarding; `AdvancedDisclosure`: the animated fold), YouTubeSettingsTab.swift, CuesSettingsTab.swift, TransferSettingsTab.swift (import result: one badge plus a `.waiting` badge per note from `SettingsImportReport`) | other tabs; `Cues*` rows reused by onboarding |
| UI/AccountSettingsTab.swift | DEBUG only (mock Thriveni account) |
| UI/SettingsKit.swift | Shared Settings parts: `Collapsible`, `Collapse`, `ChoiceTile`, `PictureChip`, `StatusBadge` |

### Menu bar, island, floating surfaces, onboarding, chat
| path | owns | key types |
|---|---|---|
| UI/MenuBarModel.swift / MenuBarStatusItem.swift | Pure menu items from state; AppKit `NSStatusItem` whose click builds `[MenuEntry]` and shows them in `MeetingMenuPanel` below the button (NSMenu is invisible while inactive after a desktop switch), label, action handling, `MenuBarLog` (~/Library/Logs/Greenroom-menubar.log), `SwiftUIActions` bridge | `MenuBarModel.items`, `MenuBarState`, `MenuBarStatusItem`, `MenuBarActionBridge` |
| UI/NotchStatusController.swift / NotchStatusRules.swift | The island (one pill: failure > countdown > status > FIFO of prompts/toasts). It is the only surface while a meeting starts: step words, ring and a Cancel button (`NotchInput.cancellable`, `model.onCancelStart`; clickable, never key); no-notch Macs use the same pill under the menu bar. Start pacing (`StepPacer`, pure): the island DISPLAYS a paced phase, not the real one. It opens on "1/N", holds each step 0.7 s (the first from the end of the 0.35 s expand), advances one step at a time, never skipping and never ahead of the real start, shows "N/N" full ring for one hold once the start finished, then Live (`liveHold`). Failure, cancel and hide pass at once and reset it. Start steps (words): Workspace "Opening your apps", Picture "Getting your camera and screen ready", Creating meeting "Creating the meeting on Zoom" (REST create, or the scheduled host-key fetch; skipped, so not counted, when a warm host key exists), Meeting "Connecting to Zoom" (SDK connect until InMeeting), Recording, Tiling windows. A fast 3-step start is on screen about 2.45 s before Live. The controller keeps `realPhase` and one `paceTask` | `NotchStatusController.shared`, `NotchStatusModel`, `IslandQueue`, `IslandRules`, `NotchGeometry`, `StepPacer` |
| UI/Toast.swift, UploadPrompt.swift | Facades into island | `ToastController.show`, `UploadPromptCard.show` |
| UI/MeetingControls.swift | Floating Control bar (pill/puck) panel + `MeetingControlsModel`. First installed when the meeting is live (never during start; its Starting state / `finishStarting` is now dormant) | `MeetingControlBarController`, `MeetingControlBarRoot` |
| UI/MeetingBarModel.swift, MeetingBarContent.swift | Pure bar cell rules; cell views | `MeetingBarModel`, `MeetingBarLayout`, `MeetingBarContent` |
| UI/RecordingChrome.swift | Record-only bar + border while recording | `RecordingChrome`, `RecordingControlBarController`, `RecordingBorderController` |
| UI/RecorderVisibility.swift | Registers each recordable window with its `WindowKind` and keeps its `sharingType` live from the switch | `RecorderVisibility.track(_:as:)` |
| UI/PresenceBubble.swift, PresenceBubbleInteractionView.swift | Floating camera bubble that drives the picture | `PresenceBubble`, `PresenceFeed`, `PresenceQuickModel`; panel `sharingType` follows Settings -> Webcam "Show Greenroom on screen in other apps' recordings"; Mirror my camera is greyed while that is on (WebcamPage, HomeCameraPanel) |
| UI/OnboardingView.swift, OnboardingWindow.swift, OnboardingPlacement.swift | Setup guide: own window, 7 pages | `OnboardingView`, `OnboardingWindowController.shared` |
| UI/ChatWindow.swift (+ChatGrouping, ChatMessageRow, ChatMessageField) | Chat window | `ChatWindowController`, `ChatWindowView`, `ChatGrouping` |
| UI/WhiteboardViews.swift, AnnotationToolbar.swift | Whiteboard/annotation (Recorditor port) | `WhiteboardWindowController` (`Mode`: `.presented` share target, `.local` from the tools), `AnnotationToolbarView` |
| UI/WindowShareController.swift | Per-window "show to the meeting" eye; layout-placed windows start shown (`LayoutPiece.defaultShowsToEveryone` = true, 2026-11-25), the rest hidden; no amber edge | `WindowShareController`, `ShareableWindowAnchor`, `LayoutShareChoice` |
| UI/PresentMenuSpec.swift, PresentMenuLive.swift | Present menu as data + live wiring | `PresentMenu`, `CoordinatorController.presentMenu` ext |

### Shared components / tokens
| path | owns |
|---|---|
| UI/GreenroomPopover.swift | `.greenroomPopover(isPresented:content:)`: the one popover, our own anchored child NSPanel built the native way (not NSPopover, which flips sides when its content grows). Borderless, clear, non-opaque, `hasShadow` (the window shadow follows the rounded glass; `invalidateShadow()` after each resize); the panel frame IS the rounded body, no notch, no transparent margin, no SwiftUI shadow. contentView: layer-backed container (radius 16, continuous, masksToBounds) > `GreenroomGlassAppKit.makeBacking` (NSGlassEffectView on 26) > NSScrollView (overlay scroller, elastic, 8 pt top/bottom insets) > flipped document > NSHostingView of the content. Always 8 pt below its button, never flips; height = min(content fitting size + insets, room under the anchor via `PopoverPlacement`); measured from the size `PopoverRoot` reports (`onGeometryChange` on the fixed-size content, before the filling frame; `fittingSize` only before the first report, since it can answer with the host's current frame), debounced to the next run-loop turn, never while scrolling; after each resize the clip origin is clamped to the new range (top on open), so content that grows while open (Share > A window) still scrolls from the very top to the last row. One scroll per popup (no ScrollView/List inside content). Key rule: the panel takes key only when `NSApp.isActive` and the anchor window is key; it is a `.nonactivatingPanel`, never calls `NSApp.activate`, never joins all Spaces (1.8.3 full-screen lesson; MeetingMenuPanel is separate). Call sites (Home dock, Session detail, Settings > Layout) are all in windows of an active app; none in the meeting window, view windows or bar. Closes on outside click (anchor press toggles via `justDismissed`), Esc, window close/miniaturise/Space change, or isPresented false; one open at a time. Environment objects are not forwarded: capture them. DEBUG: `PopoverDebug` counts content layout passes for DebugTour `popupScroll` | `greenroomPopover` |
| UI/Glass.swift | `.greenroomGlass(in:interactive:)`, `.greenroomGlassButton`, `GreenroomGlassAppKit.makeBacking/host/prepare` |
| UI/Tiles.swift + TileAppearance.swift | `.greenroomTile(role:radius:)`, `GreenroomTileStyle`, pure `TileAppearance` |
| UI/Segmented.swift + SegmentedMath.swift | `GreenroomSegmented` (the segmented switcher) and `GreenroomUnderlineTabs` (underline tabs, the watch page side panel only) |
| UI/Fields.swift | `GreenroomFieldStyle`, `FieldFocusRelease` |
| UI/ParticipantAvatar.swift | `ParticipantAvatar` |
| UI/ClosureButton.swift | NSButton with closure, answers first click |

## How it fits
- Scenes (GreenroomApp.swift): main `Window("Greenroom", id:"main")` hosts `ContentView` with `.tint(Brand.green)`, `LaunchSplashCover`, `FrostedWindow`; `Settings { SettingsView }`; the menu bar icon is an AppKit `NSStatusItem` (`MenuBarStatusItem`), not a scene, because `MenuBarExtra` stopped opening after Space switches. Everything else is an AppKit controller (below). Sessions/report/editor are NOT scenes: they are pages (`CoordinatorController.MainPage`: home, sessions, detail(id), report(id), editor(id)) rendered by `ContentView.pageLayers` (`HomeView` and `RecordingsView` overlaid, crossfaded by `changePage`).
- Main toolbar (ContentView `.toolbar`): on Home: `modeSwitcherItem` (principal `GreenroomSegmented` bound to `coordinator.meetingMode`), Sessions icon, fixed `ToolbarSpacer`, Setup guide + Settings group. On pages: `.pageToolbar` Back + subtitle.
- State: `CoordinatorController` (App/CoordinatorController.swift, `@EnvironmentObject`) feeds all views; pure `*Rules`/`*Model` files are called by the views and by Tests/.
- AppKit windows opened by static controllers: island (`NotchStatusController.shared`, non-activating panel over menu bar), Control bar (`MeetingControlBarController.install`), onboarding (`OnboardingWindowController.sync`, called from ContentView on `coordinator.showOnboarding`), chat (`ChatWindowController.show`), whiteboard, recording chrome, presence bubble (driven from App/CoordinatorController+Presence.swift: `startPresenceBubble`, `refreshPresenceBubble`), dock hint (`DockHintPanel`).
- Pages meant to render off-screen take plain values/bindings (`WebcamPageContent`, `LayoutPageContent`, `CuesSetupContent`, `MeetingBarContent`, toolbar) and have thin coordinator-fed wrappers (`WebcamSettingsTab`, ...).

## To change X, go to Y
- Add a Settings tab -> `SettingsView.tabOrder`, `TabView` item + `.tag`, `height(for:)`; update Cmd-N hint (count) and `.showSettingsTab` users.
- Add a Settings row -> the tab's `*PageContent` (e.g. `WebcamPageContent`, `ZoomPageContent`, `TransferPageContent`); use `SettingsKit` parts; wrap dependent controls in `Collapsible(hidden:)` with `Binding.animatedCollapse()`.
- Change Home toolbar items -> `ContentView.body` `.toolbar { }`; then update `HomeToolbarRules` (SidebarRules.swift) widths.
- Change the Create/Scheduled/Record switcher -> `ContentView.modeSwitcher`, `MeetingMode` in CoordinatorController.swift.
- Popovers: always below their button, one scroll per popup (never a ScrollView inside the content), scroll when tall; use `greenroomPopover`, never a bare `.popover` (SessionDetailContent share card is the one `.top` exception: anchored to the whole page).
- Add or change a tile popover (Look, Camera, Screen, Mic, Layout, Auto-rec, More all done) -> build it on `HomeTilePanel` (HomeTilePanels.swift), rules in `HomeTilePanelRules.swift`; once a tile has a panel, drop its `.dockHint(...)` and keep a `.help` (see `lookControl`, `cameraChip`). Hover-card art/text live in `DockHintVisual` (DockHint.swift) and each tile's `DockHintContent` in HomeView.
- Change Home dock chips (Share/Camera/Mic/Layout) -> `HomeView.shareChip/cameraChip/micChip/layoutChip`; summary wording in `HomeCalmRules.SetupSummary`; readiness pills `HomeView.readyRow`, `ReadinessSummary`.
- Change Start/Record button -> `HomeView.primaryButton`, `recordControl`, `recordPicker`.
- Home window size / minimum width -> `HomeView.columnHeight/sideMargin`, `ContentView.homeWindowHeight/minimumWindowWidth/defaultWindowWidth`.
- Change the live preview crop / camera drag -> `PreviewFrameRules`, `PreviewCameraDragLayer`, `PreviewOutlineRules`.
- Change sessions grid filters/sort/chips -> `SessionsQuery.swift` (`SessionsShow/Status/Sort`, `SessionChips`), sidebar in `SessionsSidebar`.
- Change a session row/card -> `SessionsRow.swift`, `SessionsContent.swift`.
- Watch page keys (Watch mode only; Edit keeps the editor's own monitor): Space play/pause, Left/Right skip 10s, M mute, F full screen (Esc exits full screen; double-click the picture too). One monitor in `SessionDetailContent.SpaceBarPlayback`, same typing/sheet gating as Space; key map in `PlayerControlRules.action`. Full screen keys are `WatchFullScreen`'s own monitor.
- Watch page toolbar (watching): Get feedback (`SessionAnalyseButton`, which also anchors the one Ready/progress popover as a `.background`, so no width change) is its own glass capsule, then a fixed `ToolbarSpacer`, then Share… / More / side-panel toggle as one capsule; editing has just the one group.
- Change watch page layout -> `SessionDetailContent.SessionDetailPage` + `SessionDetailRules` (when the rail drops under the picture).
- Change the timeline/marks -> `SessionTimeline`, `SessionMarkStyle`.
- Change a menu bar item -> `MenuBarModel.items` (order/titles/shortcuts), drawn by `MenuBarStatusItem`; test `Tests/MenuBarModelTests.swift`.
- Change menu bar icon/REC label -> `MenuBarStatusItem.renderLabel()`.
- Add an island message / change sizes -> `NotchStatusRules.swift` (`IslandMessage`, `IslandContent`, `NotchGeometry`), drawing in `NotchStatusController` (`statusRow/failureLine/countdownRow/toastRow/promptRow`).
- Show a toast / ask an upload question -> `ToastController.show`, `UploadPromptCard.show`.
- Change the floating bar's cells/widths -> `MeetingBarModel.swift` (`IconCell`, `MeetingBarLayout`), `MeetingBarContent`, panel/morph in `MeetingControlBarController` (MeetingControls.swift); placement maths App/MeetingBarPlacement.swift.
- Change the Present/Share menu -> `PresentMenuSpec.swift` (data), `PresentMenuLive.swift` (wiring), `MeetingMenus.ShareMenuState` in MeetingMenuSpec.swift.
- Change the camera bubble -> `PresenceBubble` (panel, strip, handles), `PresenceBubbleInteractionView` (resize/cursor), model `PresenceQuickModel`; whether other apps' recordings capture it (`sharingType`), its mirror, feed size and chrome -> `PresenceRecorderRules` (Tests/PresenceRecorderRulesTests; Greenroom's own capture excludes it by filter regardless, see stage.md); geometry `PresenceGeometry` (Tests/PresenceGeometryTests).
- Change recording countdown/border/control bar -> `RecordingChrome.swift`; countdown is island (`NotchStatusController.setCountdown`).
- Edit a layout editor behaviour -> `LayoutCanvas` (drag/resize), `LayoutAddPanel`, `LayoutAppOrdering`, `LayoutSettingsTab.LayoutPageContent`; layout model in App/Layout/.
- Change the Sign in with Zoom block or the advanced fold -> `ZoomSignInSection.swift` (`live(_:)` feeds it from the coordinator); the Zoom step of the setup guide is `OnboardingView.credentialsStep`.
- Change onboarding pages -> `OnboardingView.SetupPage` (welcome, zoom, layout, permissions, youtube, cues, ready) and `...Step` builders; window `OnboardingWindowController.sync`; placement `OnboardingPlacement.frame`.
- Add a floating panel -> use `GreenroomGlassAppKit.makeBacking` + `.prepare`, non-key `NSPanel`, follow `RecordingChrome`/`DockHintPanel`.
- Transcript tab (`SessionTranscriptView`): click a line (or its stamp) seeks via `scrub` (play state unchanged); the current line gets a `Brand.green` 14% wash and scrolls into view while playing unless the reader scrolled in the last 3s (`TranscriptScrollProbe`); double-click or Return on the selected line edits inline (Return/click-away saves, Esc cancels, blank deletes with "Line removed - Undo"). `TranscriptEditor` rewrites the one RAW row atomically in the file the line came from, copies `<name>.original.txt` before the first edit, offers Revert in the summary row's ellipsis menu, and registers every write with the window `UndoManager` (Command-Z). `SessionSummary.Line.rawIndex` maps a displayed line to its file row. Rows no longer allow text selection (it ate double-click). A cached summary older than the transcript shows "Transcript edited since this summary" with Summarise again.
- Wording: the one action is "Get feedback" (button), "Getting feedback" (pill and popover title), "Stopping", "Report" (done); never Analyse/Analysing in user-facing text. The watch page's Transcript empty state offers Transcribe (primary) and Get feedback.
- Add a segmented switch / tile / text field -> `GreenroomSegmented`, `.greenroomTile`, `.textFieldStyle(.greenroom)` (Fields.swift); never new ones.
- Make a window visible/hidden to other apps' recorders (QuickTime, Loom, OBS) -> add a `WindowKind` to `PresenceRecorderRules` and call `RecorderVisibility.track`; never set `sharingType` by hand. Rule: other apps record Greenroom as you see it, except credentials (setup guide: always `.none`); Greenroom's own picture excludes every Greenroom window by filter regardless. Covered: annotation canvas/toolbar/chrome, MeetingMenuPanel, recording control bar and border, whiteboard, camera bubble and strip. Windows that set no sharingType (and so are already visible to other apps): main/Home, Settings (holds masked SecureFields for client secrets), meeting bar, notch island, meeting chat/participants/meeting windows, browser.
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
- Segmented switchers use only `GreenroomSegmented` (spring slide, Brand fill, white label), except the watch page side panel, which uses `GreenroomUnderlineTabs` (sliding 2pt Brand green underline, hairline); picture choices use tiles, not segmented.
