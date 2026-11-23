# codemap: App/UI meeting windows (MeetingVideo, ParticipantConsole, meeting window, toolbar, menus)

Greenroom's own meeting UI when Zoom runs in custom-UI mode (the SDK owns no windows). Two surfaces: (1) the single big Meeting window / reference display (`ParticipantGridWindowController`, one 5.2k-line file) with a Zoom-style dark look, top bar, video stage, one side panel (chat or people) and a foot toolbar; (2) separate "view windows" (`MeetingViewWindows`, one per `MeetingView`: Active speaker, Gallery, Multi-speaker, Speaker + strip, Self view, People list, Shared screen, Spotlight person, Hands up) that a layout can place individually. The participant "console" pieces (Live Queue, inspector, self preview, people panel) feed the reference-form rail and the People panel. Main-app screens are in `ui.md`.

## Files

### Meeting window (App/UI)
| path | owns | key types |
|---|---|---|
| UI/ParticipantGridWindow.swift (5259) | The window runtime and almost all its AppKit views | `ParticipantGridWindowController` (static API: `configure`, `refresh(on:session:form:)`, `show/hide/close`, `place(frame:)`, `cycleMeetingView`, `morphSnapshot`, `applyCues`, `applyCameraSwitch`), `Form` (`.reference`, `.meeting(fillsScreen:)`, `.placed(NSRect)`), private `ControlPanel` (NSPanel), `RootView` (all layout), `TileView`, `IconCellButton`, `BarView`, `ToolbarFootView`, `MeetingSplitDivider`, `SelfShareCardView`, `ReadinessView`, `ReadinessHUDController`, `LevelMeterView`, `SwitchCountdownView` |
| UI/MeetingTopBar.swift | Slim top bar in title-bar area: shield/info, name+clock, shrink, View button; info popover | `MeetingTopBarState`, `MeetingTopBarView`, `MeetingBarButton`, `MeetingShrinkTipView`, `MeetingInfoView` |
| UI/MeetingToolbar.swift | Foot toolbar drawn from values | `MeetingToolbarState`, `MeetingToolbarMenus`, `MeetingToolbarActions`, `MeetingToolbarBar` |
| UI/MeetingToolbarLayout.swift | Pure: what fits at a width; rest goes to More | `ToolbarItemID`, `MeetingToolbarLayout.specs/fit`, `.Fit` |
| UI/MeetingControls.swift (1531) | `MeetingControlsModel` (mic/camera/roster counts/side panel, actions, 1 s poll), coordinator-bound `MeetingToolbarView`, and the floating pill/puck | `MeetingControlsModel`, `MeetingSidePanel`, `MeetingToolbarView.menus(for:)`, `MeetingControlBarRoot`, `MeetingControlBarController` |
| UI/MeetingBarModel.swift, MeetingBarContent.swift | Pure cells/menus/help for the floating bar; cell views | `MeetingBarModel`, `MeetingBarSnapshot`, `MeetingBarLayout`, `MeetingBarContent`, `MeetingBarActions` |
| UI/MeetingMenuSpec.swift | Toolbar/bar menus as data | `MenuEntry`, `MeetingMenus` (audio, video, security, share, more, `.Device`, `.ShareMenuState`, `.MoreMenuActions`) |
| UI/MeetingMenuAppKit.swift | `MeetingMenuBuilder.popUp` (above a control) and the `MenuPopUpOverlay` cell overlay; both open a MeetingMenuPanel | `MeetingMenuBuilder`, `MenuPopUpOverlay` |
| UI/MeetingMenuPanel.swift | Every menu in a window that shows while Greenroom is inactive: our own non-activating glass panel (NSMenu shows nothing then). `show(above:)`, `show(for: event)` (right-click), `show(at:in:)`; dismissal monitors, toggle, submenus; no arrow keys | `MeetingMenuPanel.show` |
| UI/MeetingViewsMenu.swift | Views menu as data (checkmark per open view) | `MeetingMenus.ViewsMenuState` |
| UI/MeetingTheme.swift | The meeting window's fixed dark palette/sizes/type | `MeetingTheme`, `MeetingControlStyle`, `.meetingControl` |
| UI/MeetingTileChrome.swift | Name capsule, mute/hand/ring over a tile (AppKit) | `MeetingTileModel`, `MeetingTileChrome` |
| UI/PeoplePopOut.swift | People panel as a small window beside the Control bar | `PeoplePopOutController` (`show(near:)`, `feedWithoutWindow`) |
| UI/ChatWindow.swift (+ChatMessage*, ChatGrouping) | Chat as its own window, or embedded as the window's side panel | `ChatWindowController`, `ChatWindowView` |
| UI/WindowShareController.swift | The eye: show a window to the class | `WindowShareController` |

### MeetingVideo/ (view windows)
| path | owns | key types |
|---|---|---|
| MeetingVideo/MeetingViewWindow.swift (705) | One panel per view; registry and one-second tick; video budget, cover/release rules, black-window fallback, Spotlight pick | `MeetingViewPanel`, `MeetingViewWindowController`, `MeetingViewWindows` (`configure`, open/close, `menuState`, `pickerMenuEntries`, `owns`) |
| MeetingVideo/MeetingViewContent.swift | What a view window draws from a snapshot | `MeetingViewSnapshot`, `MeetingViewSlotPlan`, `MeetingViewContentView`, `ShareChoice` |
| MeetingVideo/MeetingViewRules.swift | Pure: modes, share layouts, split, prefs, tile filter/plan, grid/strip maths | `MeetingViewMode`, `MeetingShareLayout`, `MeetingSplit`, `MeetingViewPrefs`, `MeetingTilePlan`, `MeetingVideoLayout.gallery/strip/multiSpeaker` |
| MeetingVideo/VideoTiles.swift | Tile = SDK video view + chrome; right-click Spotlight | `MeetingViewPerson`, `MeetingVideoTile` |
| MeetingVideo/HandsUpPanel.swift | Hands up list (waiting room on top) | `HandsUpContent`, `HandsUpPanel`, `HandsUpView` |
| MeetingVideo/ShowOnShareViews.swift | The eye switch, one-time toast, amber share border | `ShowOnShareSwitch`, `ShareVisibilityAnnouncer`, `ShareBorderOverlay` |
| Layout/LayoutTemplate.swift (outside UI) | `MeetingView` enum (raw values saved in layouts), `MeetingViewPieces.enabled` flag (`meetingViews.enabled`) | |

### ParticipantConsole/
| path | owns | key types |
|---|---|---|
| ParticipantConsole/ParticipantConsoleState.swift | One derived value: what needs the teacher now | `ParticipantConsoleState`, `.Attention` (waiting / hands / clear) |
| ParticipantConsole/LiveQueueLayout.swift | Fixed-width (320) section arithmetic | `LiveQueueLayout.width/Section` |
| ParticipantConsole/LiveQueueView.swift | Exception panel: waiting, hands, Cues (fixed pool of views) | `LiveQueueView`, `.Actions` |
| ParticipantConsole/ParticipantInspectorView.swift | Drawer for the one selected student | `ParticipantInspectorView` |
| ParticipantConsole/SelfPreviewView.swift | 240pt self-view overlay with mute/stop video | `SelfPreviewView` |
| ParticipantConsole/MeetingPeopleView.swift | Participants panel (dark): search, waiting, raised hands, everyone | `MeetingParticipantsPanel` (SwiftUI), `MeetingPeopleView` (NSView host), `MeetingParticipantRow`, `MeetingWaitingRow`, `MeetingParticipantsActions` |

## How it fits
- Hosting: `ParticipantGridWindowController.refresh` makes/updates one `ControlPanel` (non-activating `NSPanel`, titled, never borderless) holding `RootView`. `Form` decides the look: `.reference` = full-display rail panel on a teacher-only display (header, tile grid, rail with self block, Live Queue, inspector drawer, context bar); `.meeting` = free window; `.placed(frame)` = layout slot, compact (<760x520, `LayoutResolver.isCompactMeeting`) = Speaker view with chrome on hover. A change of form kind = a new window.
- `RootView.setupMeetingForm` (meeting forms) builds `meetingTopBar`, stage, share, side panel (`peopleView` or embedded chat `chatHost`), and the foot toolbar host (`FirstMouseHostingView(rootView: MeetingToolbarView(model: controls, coordinator:))`). Layout in `layoutMeeting`, `layoutSidePanel`, `layoutFilmstrip`, `layoutMultiSpeaker`; view mode `ViewMode`=`MeetingViewMode` (Speaker/Gallery/Multi-speaker), share layouts `MeetingShareLayout`; roster in via `update(roster:...)`, rows via `applyPeople`.
- Controls state: coordinator owns one `MeetingControlsModel` (set as `ParticipantGridWindowController.controls`). The same model drives the foot toolbar (`MeetingToolbarView` -> `MeetingToolbarBar`) and the floating pill (`MeetingControlBarController.install`, shown only when no meeting window carries controls). Pill collapses to a 44pt puck; placement rules App/MeetingBarPlacement.swift; shrink/collapse morphs App/MeetingMorph.swift, App/MeetingShrinkRules.swift, App/MeetingCollapseRules.swift.
- Menus: `MeetingMenus` builds `[MenuEntry]`; `MeetingMenuBuilder.popUp` -> `MeetingMenuPanel` (toolbar, top bar View button); puck, tile right-clicks, rail menus, view-window picker and People "..." too; NSMenu is not used in those windows. `MenuBarStatusItem` turns the same list into an NSMenu submenu for the menu bar (a status-item menu is tracked by the system, so it works while inactive).
- View windows: `MeetingViewWindows.configure(client:log:frameFor:copyInvite:openMeetingWindow:)` is called by CoordinatorController; the layout runtime opens each view piece at its frame; windows open 0.5 s apart; each owns a `WindowShareController` (eye, off per launch).
- Readiness: before connect, the reference/meeting window shows `ReadinessView` (start steps `NotchStep`), or `ReadinessHUDController` floating card; island (NotchStatusController) carries it too.
- `PeoplePopOutController` is the Participants panel in its own window; folds into the window's People panel when the Meeting window is back in view (like chat pop-out).
- Every bar-opened window (views, Meeting window, Chat, People) goes through `NSWindow.comeToThisDesktop(settledBehavior:)` (MeetingViewWindow.swift), new windows too, so it lands on the desktop in view, a full-screen one included. Chat and People are `KeyablePanel`s (`.nonactivatingPanel` from init, `canBecomeKey` true): a plain NSWindow of an inactive app cannot join a full-screen desktop.

## To change X, go to Y
- Change foot toolbar items/order -> `MeetingToolbarLayout.specs` (ids, group, width, `keep` drop order) + `MeetingToolbarBar` (drawing) + `MeetingToolbarState/Actions` + wiring in `MeetingToolbarView.state/actions` (MeetingControls.swift). Update Tests/MeetingToolbarTests.swift.
- Change a toolbar menu (mic/camera/share/security/more) -> `MeetingMenus.*` in MeetingMenuSpec.swift; live fill in `MeetingToolbarView.menus(for:)`.
- Change what fits at width / More overflow -> `MeetingToolbarLayout.fit` (constants cell/caret/divider/gap/clock/end).
- Change the floating Control bar cells -> `MeetingBarModel` (`IconCell`, `RecordPill`, help text), `MeetingBarLayout.width/height`, drawing `MeetingBarContent`, panel/placement `MeetingControlBarController`.
- Change meeting top bar (shield, clock, View button) -> `MeetingTopBarView`, state `MeetingTopBarState`, wiring `RootView.updateMeetingTopBar`/`setupMeetingForm`.
- Change colours/sizes of the meeting window -> `MeetingTheme` only.
- Change tile look (name capsule, mute badge, speaking ring) -> `MeetingTileChrome`; reference-form `TileView` in ParticipantGridWindow.swift.
- Add a view mode / change gallery/strip maths -> `MeetingViewRules.swift` (`MeetingViewMode`, `MeetingVideoLayout`, `MeetingTilePlan`), `RootView.layoutTiles/rebuildPlan`; tests MeetingViewRulesTests.
- Add a new view window type -> `MeetingView` (Layout/LayoutTemplate.swift: title, blurb, raw value never renamed), `MeetingViewContentView` draw case, `MeetingViewWindowController` (keyable?), `MeetingViewSnapshot` data, Add panel entries `MeetingViewPieces.addEntries`.
- Change view-window video budgeting / cover / fallback -> `MeetingViewWindows` (`coverRelease`, `noVideoAfter`, tick); App/Stage + `VideoBudgetTests`.
- Change People/Participants panel -> `MeetingParticipantsPanel`/`MeetingPeopleView` (rows from `RootView.applyPeople`; pop-out `PeoplePopOutController`).
- Change Hands up list ordering/UI -> `HandsUpPanel`, `HandsUpContent`; Tests/HandsUpOrderingTests.
- Change reference-form rail / Live Queue -> `LiveQueueLayout` (sizes), `LiveQueueView`, `ParticipantConsoleState` (priority), `RootView.rebuildRail/layoutRail/placeQueue`.
- Change per-student actions in the inspector -> `RootView.rebuildContextBar` + `ParticipantInspectorView` (arranges buttons only; actions defined in RootView `perform/confirm`).
- Change self-view overlay -> `SelfPreviewView`, `RootView.layoutSelfBlock`.
- Change side-panel behaviour (chat vs people) -> `MeetingControlsModel.toggleChat/togglePeople/showPeople` + `RootView.sidePanelChanged/layoutSidePanel`.
- Change shrink-to-bar behaviour -> `ControlPanel.miniaturize` -> `ParticipantGridWindowController.shrinkInsteadOfMinimize`, `MeetingControlsModel.collapseMeeting/expandToMeetingWindow`, `MeetingControlBarController.morph`.
- Change the bar's two-step End -> state machine `EndConfirm` (App/LiveExitRules.swift: idle, confirming, ending; 6 s timeout; tests EndConfirmTests); driven by `CoordinatorController.confirmAndStop/armExit/disarmExit`; drawn by `MeetingBarContent.endConfirmStrip` (the whole bar becomes the question + Keep going + End for everyone, with `EndCountdownFill`). No popover: a popover is its own window and ate the first click on Confirm. The toolbar's End (`MeetingToolbarBar.endControl`) has the same flow in place, auto-reverting after the same wait.
- Change close confirmation (End/Leave/Shrink sheet) -> `ParticipantGridWindowController.confirmClose` (set by coordinator); rules App/LiveExitRules.swift.
- Change the Views menu -> `MeetingMenus.ViewsMenuState` (MeetingViewsMenu.swift), `MeetingControlsModel.viewsMenu()`; Tests/ViewsMenuTests.
- Change the eye (show on share) wording/visibility -> App/ShareVisibilityRules.swift (rules), `WindowShareController` + `ShowOnShareSwitch` (draw).
- Change Readiness card/steps -> `ParticipantGridWindowController.Readiness`, `ReadinessView`, `ReadinessHUDController`, `NotchStepState` ext.
- Change Present/share-self card -> `SelfShareCardView` (window), `PresentMenu` (menu).

## Gotchas
- Zoom-familiar dark look is a recorded owner decision (DESIGN.md, 2026-11-12) overriding "do not imitate Zoom" for this window only: dark aqua forced, fixed `MeetingTheme` values, SF Symbols only, never Zoom's logo/word as branding. The Zoom-ish greens here are NOT `Brand.green`; the app accent stays untouched elsewhere.
- Meeting windows are real titled windows, never borderless (close button + title bar always). Panels are non-activating (`ControlPanel`, `MeetingViewPanel`, Control bar `BarPanel` never key/main): a click must not pull Greenroom forward over the teacher's slides. `MeetingViewPanel.keyable` only for People list (search).
- Control bar/floating pill: a floating surface, so glass rules apply; anything new on it follows `MeetingBarModel` rules (owner 2026-11-13): non-universal icons carry a word, one timer in the REC pill, End is the only red control, rare actions fold into REC menu / More.
- Toolbar: Mute is never dropped, More is always present (holds Meeting info, Open in Zoom app); Security only for host/co-host; drop order is the `keep` numbers, clock goes before action controls. Never let it squeeze: fit is arithmetic, tested in Tests/MeetingToolbarTests.swift. Home's toolbar chevron rule is separate (`HomeToolbarRules`, see ui.md).
- Video views: an SDK video view has one superview. Speaker stage is not a tile (`stageHost`); render order matters (show panel, lay out, create elements, subscribe once visible). View windows that are minimised or ordered out for >= 3 s release their elements (occlusion and other Spaces do NOT count: that flapped and showed frozen video); a speaker change keeps the element and sets a new `userid`; black-window fallback after 6 s offers "Use the meeting window" (`meetingWindowOnly`).
- Participant console views are fixed pools written in place, never rebuilt per poll (tearing views down races the accessibility tree); Live Queue width is fixed (320) so Cues arriving cannot move the layout. Inspector/Live Queue overlay the grid below `RootView.narrowWidth` (900).
- Everything in ParticipantGridWindow.swift is pure AppKit (frames, no Auto Layout in most paths): `layoutEverything` / `layoutMeeting` own geometry; do not set frames elsewhere.
- UI words: "meeting", not "class" (a few old comments/ids say class; no new user text with it). Greenroom windows are out of screen capture unless the eye adds them (`ShareVisibleWindows`).
- Raw values of `MeetingView` and `MeetingViewMode` persist (saved layouts, UserDefaults): never rename.
- Debug-only: `PeoplePopOutController.debugRowCount` and `MeetingPeopleView` debug hook (line ~295) stay under `#if DEBUG`.
- Tests covering this area: MeetingToolbarTests, MeetingBarModelTests, MeetingBarPlacementTests, MeetingViewRulesTests, MeetingViewFlagTests, HandsUpOrderingTests, ViewsMenuTests, RecentSpeakersTests, VideoBudgetTests, PeoplePopOutPlacementTests, MeetingShrinkRulesTests, MeetingCollapseRulesTests, ShareVisibilityRulesTests, LiveExitRulesTests, PresentMenuTests.
