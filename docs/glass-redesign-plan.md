# Glass audit: Greenroom on macOS 26 (2026-11-13)

What the owner asked: "The styling of this page kind of feels unrelated to the rest of the UI styling. The entire app's UI should align with the macOS glass feel."
Plus: a clear hover state on every clickable card, a quieter selection, and the session page rethought.
Deployment target is macOS 14. Everything below works on 14 and 15, and only looks fully "glass" on 26.

Rule used throughout: **the system draws navigation and controls (sidebar, toolbar, search, back, sort/filter, inspector), and we draw content.** On 26 the system gives glass to sidebars, toolbars and toolbar items by itself. Every custom piece of chrome we draw is a piece that will not.

## 1. Inventory

| Screen | Files | How it is built today | What clashes with the 26 look |
|---|---|---|---|
| Home | `App/UI/ContentView.swift`, `GreenroomApp.swift` (`Window("Greenroom")`) | No toolbar. An 88pt logo row with plain `?` and gear buttons in the page. "Sessions" is a large tinted button in the Start row. The page change is hand-made (ZStack layers, pinned frames, animated window resize). | Window-level actions (Help, Settings, Sessions) live in the page instead of the toolbar, so there is no glass toolbar. |
| Sessions | `App/UI/SessionsContent.swift` (`SessionsLayout`, `SessionCard`, `SessionsFilterRow`, `BackButton`), `App/UI/RecordingsView.swift` (`grid`) | Hand-made 244pt `HStack` column: capsule "< Home" `BackButton`, "Sessions" title, a home-made search field (`RoundedRectangle` 10% fill), RasanAI-metric rows with a custom selected fill and count pills, a storage footer. The content area has an in-page "Newest first" menu and opaque `controlBackgroundColor` cards; the selected card gets a 2pt `Brand.green` stroke and a 10% green fill. | Everything. No split view, so no floating glass sidebar. Search, back and sort are not in the toolbar. Single-click calls `selection = id; onOpen(id)`, so the selection only shows after Back, which is why it reads as "already selected". Cards have no hover. |
| A session's page | `RecordingsView.swift` `detailPage` / `stage` / `work`; `SessionsContent.swift` `SessionInspector`, `StatusTile`, `SessionClipsList` | A "< Back" pill row, then an 800pt centred column: `AVPlayerView` (`.floating` controls, hidden until hover), a custom `ClipTimeline`, title, meta, a "Playing" picker, a tiny ⋯ menu, three `StatusTile`s, a "How to analyse…" link, a segmented control, and a fixed 300pt `detail()` area. | Dead space at the sides. Page actions are tiles, not toolbar items. Play controls are hidden. The tab area is 300pt tall, so it is mostly empty. |
| Report | `App/Screenroom/ScreenroomReportView.swift`, `ScreenroomExportMenu.swift` | `BackButton` row plus Divider plus a ScrollView of `controlBackgroundColor` cards. | In-page Back, and Export sits in the page. The cards themselves are fine (content). |
| Record / Get Ready | `App/UI/RecordStudioView.swift` (on Home's layer) | In-page "Record" title, a Done button, the picture, controls, and a bottom bar with timer, Pause and a `.borderedProminent` Record. | Done and the title belong in the toolbar. Record and Pause are control-layer buttons that could be glass on 26. |
| Settings | `App/UI/SettingsView.swift` (`TabView` + `tabItem`) and the `*SettingsTab.swift` files, `SettingsKit.swift` (`ChoiceTile`), `LayoutSettingsTab.swift` (`LayoutCard`), `CameraSwitchSection.swift` (`CameraCard`/`NoCameraCard`), `WebcamPage.swift` shape tiles, `CuesSettingsTab.swift` `SampleCard`, `ScreenroomSettingsTab.swift`, `LayoutAddPanel.swift` | **Native already.** The Settings scene's TabView gives a toolbar tab strip, which is glass on 26. Forms are grouped. | Only the tiles: five copies of "selected = 12% green fill + 2pt green stroke" and no hover anywhere. |
| Chat | `App/UI/ChatWindow.swift` (an `NSWindow` made by hand) | Two looks: inside the meeting it is `MeetingTheme` dark (decided 2026-11-12); standalone it uses system colours. The composer is docked. | Minor. The standalone composer could be a floating glass capsule (like Messages). |
| Editor | `App/Editor/EditorView.swift`, `EditorTheme.swift`, `TimelineView.swift` | Its own `Window("Editor")` with no toolbar. A home-made `toolbarRow` (mode picker, Undo, effects, Cancel/Export) sits above the timeline, and a 290pt side panel has an Info/Assistant segmented control. `EditorCardStyle`. One popover is forced dark (`preferredColorScheme(.dark)`, about line 735). | Window actions are drawn in the page. The side panel should be an `.inspector`. The forced-dark popover is wrong. |
| Meeting window and pill | `App/UI/ParticipantGridWindow.swift`, `MeetingTopBar.swift`, `MeetingToolbar*.swift`, `MeetingTheme.swift`, `MeetingControls.swift`, `App/MeetingMorph.swift` | Forced dark, Zoom look (decided 2026-11-12). The pill already uses `.greenroomGlass`. | Nothing to change. A recorded decision covers it. |
| Participant grid / reference panel, meeting-view windows | `ParticipantGridWindow.swift`, `MeetingVideo/MeetingViewWindow.swift`, `ParticipantConsole/*` | Docked dark chrome, `underPageBackground` (a recorded exception). | Leave as is. |
| Floating HUDs, toasts, banners, upload prompt, recording bar | `WindowBanner.swift`, `Toast.swift`, `UploadPrompt.swift`, `RecordingChrome.swift` | Done in the glass pass (`.context/glass-pass.md`). | Done. |
| Menu bar extra | `MenuBarView.swift` (`.menuBarExtraStyle(.menu)`) | A native NSMenu, so 26 draws it. | Nothing. |
| Onboarding | `App/UI/OnboardingView.swift` (a sheet, 680×700) | Hand-made header and footer, step dots, and `LayoutCard`. | Sheets get glass on 26 by themselves. Only the tiles (through the shared card) and standard default/cancel buttons are left. |

## 2. Changes per screen

### Main window (Home and all pages): give it a real toolbar
- In `GreenroomApp.swift`, add `.windowToolbarStyle(.unified)` to the `Window("Greenroom")` scene. The toolbar exists on every page, so the title bar height never changes during the Home ↔ Sessions motion.
- Home toolbar (`ContentView.swift`): set `.toolbar` with `ToolbarItemGroup(placement: .primaryAction)` holding Sessions (`film.stack`), Setup guide (`questionmark.circle`) and Settings (`gearshape`). Remove them from the header. Keep the logo row: it is the brand, not chrome. Hide the duplicate "Greenroom" title with `.toolbar(removing: .title)` on 15+; on 14, leave it.
- **Do not use `.navigationTitle` on pages** until C10 lands. `NSApp.windows.first { $0.title == "Greenroom" }` is used in `ContentView.window` and `CoordinatorController.swift` (about lines 3738, 3749, 4131 and 4286). Use `.navigationSubtitle("Sessions")` instead; it sets `NSWindow.subtitle`, not `title`.
- Back: a single `ToolbarItem(placement: .navigation)` with `Button { coordinator.goBack() } label: { Label(backLabel, systemImage: "chevron.backward") }` and `.keyboardShortcut("[", modifiers: .command)`. Delete the hidden zero-size ⌘[ button in `ContentView.body` so only one control holds the shortcut. Keep `onExitCommand` for Esc.

### Sessions (grid)
- **Structure:** `SessionsLayout` becomes `NavigationSplitView(columnVisibility:) { sidebar } detail: { grid }` with `.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)`. The 180 floor comes from the 2026-09-18 sidebar-width decision.
- **Sidebar:** `List(selection: $show) { Section("Show") { ForEach(SessionsShow.allCases) { Label(o.rawValue, systemImage: o.symbol).badge(count).tag(o) } } }.listStyle(.sidebar)`. Use `.badge(0)` to hide a zero count (the same behaviour as today). The storage line goes in `.safeAreaInset(edge: .bottom)` as `.footnote`, `.secondary`, as a `Button(.plain)` that reveals the folder in Finder.
- **Status filter** leaves the sidebar, because a single-selection List cannot combine it with Show. It becomes a toolbar `Menu` (`line.3.horizontal.decrease.circle`, filled while a filter is on) with an inline `Picker` of None / Not uploaded / On YouTube / Analysed. Keep the counts in the menu item labels ("On YouTube · 4"). Keep the colour meanings: the YouTube glyph in `Brand.net`.
- **Search:** `.searchable(text: $search, placement: .toolbar, prompt: "Search sessions")`. On 26 this is the glass search field at the trailing end. Delete the home-made field.
- **Sort:** a toolbar `Menu` (`arrow.up.arrow.down`) with an inline `Picker` (Newest/Oldest). On 26, use `ToolbarSpacer(.fixed)` between the filter/sort group and Search; skip it on 14/15.
- **Header:** delete the in-page "Sessions" title and the "Everything · Analysed" headline; the subtitle and sidebar say it. Keep the week headings in the grid as `Section` headers, using `.headline`, `.secondary`, sentence case ("This week"), not uppercase eyebrows.
- **Space warning:** stays in the content, as an inline row at the top of the grid. It is content, so no glass.
- **Empty state:** `ContentUnavailableView(show.emptyLine, systemImage: show.symbol, description:)` (macOS 14). Use `ContentUnavailableView.search` when a search is active.
- **Cards:** `SessionCard` uses the shared `GreenroomTile` (see §3). There is no box: the 16:9 thumbnail (radius 10) is the card, with the title and meta under it, the way Photos and Music grids look. Hover draws a rounded `.quinary` backdrop behind the whole tile, lifts it 1pt and adds a soft shadow. `KindBadge` and `PictureChip` use `.greenroomGlass(in: Capsule())` on 26 (they float over a picture) and keep the black capsule before 26.
- **Selection: recommend no lasting selection.** Today a single click already opens the session, so a lasting selection is only ever seen after Back, which reads as a default. Keep `selectedID` internally as "last opened", but only to restore the scroll position. Draw a selection ring **only while the grid has keyboard focus**: drop `.focusEffectDisabled()`, make each tile `.focusable(interactions: .activate)` with `@FocusState`, and draw the accent ring from the focus state, not from `selection`. Return opens the focused tile, Delete trashes it, and the context menu still works on any tile.

### A session's page (rethought)
Keep the 2026-09-18 rule: the picture and scrubber stay on screen while you work in the tabs. Also keep 2026-09-18 "Screenroom borrows the Console's shape: media first, a fixed column beside it". That decision is the precedent for putting the work beside the video.

```
┌ toolbar (glass on 26) ─────────────────────────────────────────────────────────────────────┐
│ (‹ Sessions)  Monday class            [Take 2 ▾]  (⇪ Upload)(✦ Analyse)(✂ Edit) (⋯)  [⊟]  │
│               Class · Today 09:02 · 48 min (subtitle)                                  │
├───────────────────────────────────────────────────────────┬────────────────────────────────┤
│                                                           │ [Clips │ Notes │ Transcript │ Links] │
│                                                           │────────────────────────────────│
│        AVPlayerView  (.inline controls: always visible,   │  18:40  1 min · marked 9:48  ✓ │
│        system play/scrub/volume/fullscreen; black stage)  │  31:02  2 min · marked 22:10 ✂ │
│                                                           │  …                             │
│                                                           │                                │
├───────────────────────────────────────────────────────────┤  (empty state, centred:        │
│ ▮▮  ▮      ▮▮▮        ▮      marks lane (clips + notes)    │   glyph · one line · action)   │
├───────────────────────────────────────────────────────────┤                                │
│ ✦ Analysed · On this Mac · 2 h ago — "Steady pace…"  Open report → │                       │
│ ⇪ On YouTube · Unlisted · youtu.be/…  Copy  Open             │  [Export all] (Clips footer) │
└───────────────────────────────────────────────────────────┴────────────────────────────────┘
          player column flexes (min 480)                       .inspector 300–480, ideal 340
```

- **Container:** the page's detail column with `.inspector(isPresented: $showWork) { workTabs }.inspectorColumnWidth(min: 300, ideal: 340, max: 480)` (macOS 14+). It folds away with a toolbar button (`sidebar.right`). On 26 the inspector is drawn by the system.
- **Player:** `AVPlayerView.controlsStyle = .inline`. Controls are always visible (this fixes "no visible play controls"), and AVKit draws them in the system style on each OS. `ClipTimeline` becomes a **marks lane** (clip blocks and note ticks, click to seek), not a second scrubber. Two scrubbers is the one thing this layout must avoid. The picture fills the column width; letterboxing only shows when the aspect differs, on a black stage (a recorded exception).
- **Toolbar:** Back, take `Picker` (`.menu`, only when there are 2+ takes), and the actions as toolbar buttons with labels: Upload, Analyse, Edit, plus ⋯ (`Menu`: Rename…, Show in Finder, Move to Trash…). Group them with `ToolbarItemGroup(placement: .primaryAction)`; on 26 each group becomes one glass capsule. Buttons carry their state through glyph and label: "Upload" → "Uploading…" with `ProgressView` → "On YouTube ✓" (a `Menu`: Open, Copy link, Rename…, Upload again, Delete…). "Analyse" → "Analysing 2/4…" (click shows Stop) → "Report" (opens it).
- **Push-back on "leaves this Mac as hover help only":** DESIGN.md's semantic rule ("anything that reaches the network reads amber… honour it in status text") is the trust argument of the whole product. A tooltip alone weakens it. Proposal:
  - Tint the Upload glyph and the Analyse-with-agent glyph `Brand.net` in the toolbar.
  - Keep the `.help` text.
  - Show a one-time confirmation on first upload ("This sends the recording to YouTube. It leaves this Mac."), remembered per Mac.
  - Keep amber `Brand.netText` in the status strip under the player ("On YouTube · Unlisted").
  - Drop the amber subtitle *on the buttons*.
- **Status strip** (under the marks lane, `.callout`): one line per thing that happened (analysis verdict plus "Open report →", YouTube link plus Copy/Open, the running analysis step with stderr's last line). It replaces `StatusTile`, `howToAnalyse` (moves into the Analyse button's menu as "How to analyse…") and `uploadLine`.
- **Tabs:** a segmented `Picker` at the top of the inspector, the same four flat tabs (2026-09-18 flat-tabs decision). The content fills the inspector's full height instead of 300pt. Every tab gets a real empty state, `ContentUnavailableView` with its action: Clips "No clips marked" plus the shortcut hint; Notes "No notes yet" with the field ready to type; Transcript "No transcript" plus an Analyse button; Links "Cues was off in this class".
- **Narrow windows:** at the 900pt page minimum, the player gets about 540 and the inspector 340. Below about 820 the inspector should fold itself away (`showWork = false`) rather than squeeze the player.
- **Alternative considered and rejected:** keeping one centred column with the tabs under the player. It satisfies the 2026-09-18 rule but leaves the dead space the owner pointed at, and notes have to be read below the fold.

### Report
- `ScreenroomReportView` with an `onBack`: drop the `BackButton` row. Toolbar: Back plus `ScreenroomExportMenu` as a toolbar `Menu` (`square.and.arrow.up`). The `paged` (PDF) path stays free of chrome; `ImageRenderer` must never see a toolbar.
- Cards stay content (`controlBackgroundColor` or the shared card fill). There are no hover states, because nothing in them is clickable except rows that already have their own.

### Record / Get Ready
- Toolbar: Done (`ToolbarItem(.cancellationAction)`, `xmark`), with "Record" plus the folder as the subtitle. Delete the in-page title row.
- The bottom bar stays docked content. On 26 the Record button uses `.buttonStyle(.glassProminent)` with `.tint(.red / Brand.green)` and Pause uses `.glass`, through the helper in §3; 14/15 keep `.borderedProminent`/`.bordered`. Note: `RecordStudioView.windowHeight` (780) must be measured again once a toolbar is present.

### Settings
- The TabView stays as it is (already native). Swap `ChoiceTile`, `LayoutCard`, `CameraCard`/`NoCameraCard`, `SampleCard`, the Webcam shape tiles, the Screenroom model tiles and the `LayoutAddPanel` items to the shared tile. They get hover, and "chosen" becomes a 2pt accent ring plus a `checkmark.circle.fill` in the corner, **without the 12% green wash**. The Settings density rule is unchanged (40pt targets, same sizes).

### Editor
- A window `.toolbar`: Undo/Redo (`.navigation`); the mode `Picker` (`.segmented`, `.principal`); an Effects menu; Cancel (`.cancellationAction`); Save (`.confirmationAction`, `.glassProminent` on 26 / `.borderedProminent`). Delete `toolbarRow`'s chrome; the `MODE` caption goes.
- The side panel becomes `.inspector` (290 → `inspectorColumnWidth(min: 260, ideal: 300, max: 400)`) with Info/Assistant segmented at its top.
- The timeline stays docked content. Remove `preferredColorScheme(.dark)` on the popover. `EditorCardStyle` becomes the shared card. `EditorRoundControlButtonStyle` becomes `.glass` circles on 26 (the transport is a control).

### Chat (standalone only)
- The composer becomes `.safeAreaInset(edge: .bottom)` holding a capsule field with `.greenroomGlass(in: Capsule(), interactive: true)` over the scrolling transcript. Under `zoom == true` (the meeting form) nothing changes (2026-11-12 decision). Low priority.

### Onboarding
- Footer: Next gets `.keyboardShortcut(.defaultAction)` and stays `.borderedProminent`. Layout cards come through the shared tile. Nothing else.

### Meeting window, pill, participant grid, menu bar extra
- No change. The forced-dark Zoom look (2026-11-12) and the morph (2026-11-12) stay as recorded.

## 3. Shared building blocks

| Add | Where | What it does |
|---|---|---|
| `GreenroomTileStyle` (ButtonStyle) and `.greenroomTile(role: .browse/.choice(selected:), radius:)` | new `App/UI/Tiles.swift` | **Rest:** browse = no box; choice = `.quinary` fill (or `controlBackgroundColor`, owner to choose) with a hairline. **Hover:** fill one step stronger (`.quaternary`), `offset(y: -1)`, `shadow(.black.opacity(0.12), radius: 6, y: 2)`, `.easeOut(0.15)`. **Pressed:** `scaleEffect(0.98)`. **Choice selected:** 2pt `Brand.green` `strokeBorder` plus a checkmark badge, no fill wash. **Keyboard focus:** native focus ring (never `focusEffectDisabled` on tiles). **Reduce Motion:** fill change only. No cursor change (macOS buttons do not get a hand cursor). Use `.contentShape` on the whole tile. VoiceOver: `.isButton`, plus `.isSelected` for choice only. |
| `.greenroomGlassButton(prominent:)` | `App/UI/Glass.swift` | `.buttonStyle(.glass / .glassProminent)` on 26, `.bordered / .borderedProminent` before. Only for in-content controls on a control bar (Record view, transport). |
| `.pageToolbar(back:subtitle:)` | new `App/UI/PageChrome.swift` | The navigation Back item plus ⌘[ plus `navigationSubtitle`. Replaces `BackButton`. |
| `MainWindow.current` | new `App/UI/MainWindow.swift` | Finds the main window by the scene identifier rather than by title. Callers switch over in C10. |
| `ContentUnavailableView` | system | Replaces the home-made empty states in Sessions and the session tabs. |

**Delete:** `BackButton`, `SessionsFilterRow`, `SessionsLayout.eyebrow` and the in-page search field (all in `SessionsContent.swift`), `StatusTile`, the ⌘[ hidden button in `ContentView`, the five copies of the tile selection styling (`SettingsKit`, `LayoutSettingsTab`, `CameraSwitchSection` ×2, `WebcamPage`), `EditorCardStyle` (folded into the shared style), and the Editor's `toolbarRow` chrome.

## 4. Proposed DESIGN.md edits (owner approval needed)

**Add, under macOS App Mapping, a "Chrome is the system's" section:**
- Navigation and window actions live in the window toolbar: Back (⌘[ / Esc), page title as the subtitle, search (`.searchable`), sort and filter menus, and page actions.
- Collections with filters use `NavigationSplitView` with a `.sidebar` List, `Section` headers and `.badge` counts. A page's secondary work goes in an `.inspector`.
- Never hand-draw a back button, search field, sidebar row, segmented tab bar or window toolbar.
- On 26 the system gives these glass; we add none of our own.

**Add a "Cards and tiles" section:**
- One style (`App/UI/Tiles.swift`), and every clickable tile has a hover lift.
- Browse grids (Sessions) have no lasting selection, only a keyboard focus ring.
- Choice tiles (Settings, onboarding) show "chosen" with an accent ring and a checkmark, never a green wash.

**Replace:**
- "No painted window background": add that a system sidebar or inspector draws its own material, and that counts as the window's backdrop.
- Glass: "Content surfaces (… side panels …) never use glass" becomes "we never apply glass to content. System sidebars, inspectors and toolbars draw their own; in-content control bars may use `.greenroomGlassButton`."
- "Cards, tiles and grouped-form boxes sit on it in `controlBackgroundColor`": browse tiles are borderless; choice tiles and form boxes keep `controlBackgroundColor` (or `.quinary`, owner to choose).

**Decisions log entries this reverses, partly or fully (owner to approve each):**
1. **2026-11-11** "A session is one page rather than grid plus a 400pt inspector". The page stays a page, but the work tabs move into a 300–480pt inspector beside the player.
2. **2026-11-12** "Cards keep `controlBackgroundColor`" (decision 470): reversed for browse grids only.
3. **Commit 5d744db** "a RasanAI-style Sessions sidebar" (44pt rows, 15pt labels, custom fill). Not in the log, but shipped on purpose; replaced by a system sidebar.
4. **2026-11-13 Glass** "side panels never use glass": changed so that system-drawn panels are allowed.
5. **The amber subtitle on the Upload tile:** not reversed in spirit. Amber moves to the glyph, the status strip and a first-time confirmation. Listed so the owner sees it.

**Kept, not reversed:** 2026-09-18 picture and scrubber always on screen; 2026-09-18 flat tabs; 2026-09-18 "an empty pane is centred, with its action in it"; 2026-11-12 meeting window forced dark; 2026-11-12 Home ↔ Sessions motion; 2026-09-04 window grows downward from an anchored top edge; Settings density.

**Already out of step with the log (worth noting):** the log says Sessions filters are "All / Greens / Screens" (2026-09-19) and "two lists behind one toggle" (2026-09-18). The code has Everything/Classes/Recordings/Presentations plus a Status group. Write a log entry recording what actually ships.

## 5. Risks

| Risk | Mitigation |
|---|---|
| The main window is found by `title == "Greenroom"` (`ContentView.window`, `CoordinatorController` about lines 3738, 3749, 4131, 4286). A `.navigationTitle` silently breaks resize, show-window and window-ordering logic. | Use `navigationSubtitle` only until C10 switches callers to `MainWindow.current`. |
| Adding a toolbar changes the title bar height. `homeWindowHeight` (392), `RecordStudioView.windowHeight` (780) and `pageHeight` (760) were measured without one. | The toolbar is present on every page (constant height). `settledFrame` already adds `titleBar` dynamically. Measure the Home and Record heights again from the Accessibility tree. Add a `WindowFrameRulesTests` case for the toolbar offset. |
| The page-change motion: toolbar items swap during the 0.40s change; a `NavigationSplitView` inside a pinned overlay layer under a `GeometryReader` root is not a window-root split view, so on 26 the floating sidebar's top inset depends on the title-bar safe area being kept. | Swap toolbar content at the fade-out point. Check that the sidebar's top edge sits under the toolbar on 14, 15 and 26. Fallback: make `ContentView`'s root a `NavigationSplitView` with Home as detail-only (`columnVisibility = .detailOnly`, `.toolbar(removing: .sidebarToggle)`). That is a larger change. |
| Window minimum sizes: page minimum 900×600 must hold sidebar 180 + grid 480, and on the session page player 540 + inspector 300. | Fold the inspector away below about 820 of detail width. Keep `pageMinWidth` at 900. |
| Esc: a focused `.searchable` field takes Esc first. | Expected. `onExitCommand` already skips while an `NSText` is first responder. |
| Some APIs are 26-only: floating glass sidebar, toolbar glass, `.glass` button styles, `ToolbarSpacer`, `backgroundExtensionEffect`, scroll edge effects. Some are 15-only: `.toolbar(removing: .title)`, `.pointerStyle`. | Wrap in `#available` inside helpers. 14 and 15 get the classic vibrant sidebar and a plain unified toolbar, which is acceptable and still native. |
| `.inline` AVPlayerView controls plus the marks lane: users might expect the marks lane to be draggable. | Click to seek only. Hover help: "Marked clips and notes. Click one to jump there." |
| MeetingMorph and the meeting window. | Not touched by any chunk. Nothing in this plan edits `ParticipantGridWindow`, `MeetingControls` or `MeetingMorph`. |
| Tile hover inside a `LazyVGrid` with `@State` per tile, and thumbnails refreshing. | Hover state lives in the ButtonStyle (`configuration` plus `onHover` in the style), not in the grid. Thumbnails are static images. |

**QA (no `screencapture` from the shell):**
- **Structure:** dump the Accessibility tree (an AXUIElement walk, or `osascript` with System Events `entire contents` of window 1). Assert toolbar items (Back, Search, Sort, Filter, Upload, Analyse, Edit), sidebar rows with their badges, and that no "Back" button sits inside the content.
- **Grid and tiles:** keep `SessionsLayout` and the new `SessionDetailContent` taking plain values, so `.context/sr/go.sh` (and a matching `.context/wr`-style harness) still render them off screen.
  - Toolbars, `.searchable`, inspectors and glass do **not** render through `ImageRenderer`/`cacheDisplay`, because they are not in the content view and glass needs the window backdrop. The harness checks content only.
  - Render each tile state (rest/hover/focus/chosen) by passing them in as parameters.
- **Look on 26:** the owner (or a 26 machine) takes screenshots in light, dark, and on top of a busy wallpaper. Check: sidebar floats, toolbar glass groups, no opaque slab behind the sidebar, hover visible in both appearances.
- **Unit tests:** move the filter, count and sort logic out of `SessionsLayout` into a pure `SessionsQuery` and test it, so the sidebar and filter counts cannot drift.

## 6. Order of work

| # | Chunk | Files touched | Depends on | Parallel? |
|---|---|---|---|---|
| C0 | DESIGN.md edits and log entries (after owner OK) | `DESIGN.md` | owner approval | first |
| C1 | Shared blocks | new `App/UI/Tiles.swift`, new `App/UI/PageChrome.swift`, new `App/UI/MainWindow.swift`, `App/UI/Glass.swift` (add helper) | C0 | first |
| C2 | Main window toolbar and Home | `App/GreenroomApp.swift`, `App/UI/ContentView.swift` | C1 | yes (with C3, C5–C8) |
| C3 | Sessions grid: split view, sidebar, search/sort/filter, borderless tiles, focus-only selection, `SessionsQuery` plus tests | `App/UI/SessionsContent.swift` (layout/card part), `App/UI/RecordingsView.swift` (`grid`, toolbar), new `Tests/SessionsQueryTests.swift`, `.context/sr/*` | C1 | yes |
| C4 | Session page: inspector, toolbar actions, inline player, marks lane, status strip, empty states | `App/UI/RecordingsView.swift` (`detailPage`/`stage`/`work`), `App/UI/SessionsContent.swift` (inspector part), new `App/UI/SessionDetailContent.swift` | **after C3** (same two files) | no |
| C5 | Report toolbar | `App/Screenroom/ScreenroomReportView.swift`, `App/Screenroom/ScreenroomExportMenu.swift` | C1 | yes |
| C6 | Settings and onboarding tiles | `App/UI/SettingsKit.swift`, `App/UI/LayoutSettingsTab.swift`, `App/UI/CameraSwitchSection.swift`, `App/UI/CuesSettingsTab.swift`, `App/Screenroom/ScreenroomSettingsTab.swift`, `App/UI/LayoutAddPanel.swift` | C1 | yes |
| C7 | Editor toolbar and inspector | `App/Editor/EditorView.swift`, `App/Editor/EditorTheme.swift` | C1 | yes |
| C8 | Onboarding footer, standalone chat composer | `App/UI/OnboardingView.swift`, `App/UI/ChatWindow.swift` | C1 | yes |
| **Last, after the drawing agent lands** | | | | |
| C9 | Record view toolbar and glass Record/Pause | `App/UI/RecordStudioView.swift` (hosts `ShareTargetSettings`, `CameraSwitchSection`; next to `RecordingChrome`) | C2 | after drawing |
| C10 | Window lookup switched to `MainWindow.current`; drop the subtitle-only workaround and allow `.navigationTitle` | `App/CoordinatorController.swift`, `App/UI/ContentView.swift` | C2, drawing agent done (it is editing `CoordinatorController`) | after drawing |
| C11 | Webcam page tiles to the shared tile | `App/UI/WebcamPage.swift`, `App/UI/ShareTargetSettings.swift` | C1 | after drawing |

No chunk touches `RecordingChrome.swift`, `MeetingControls.swift`, `ShortcutModel.swift` or the `Stage/` files.

## 7. Segmented switchers (Home mode switcher, session tabs, editor)

**Rule (add to DESIGN.md → macOS App Mapping):** Every segmented switcher is `GreenroomSegmented` (App/UI/Segmented.swift): the native `Picker(...).pickerStyle(.segmented)` with the app's green tint removed, so the system draws the selection. On macOS 26 that selection is a Liquid Glass piece that slides between segments; 14 and 15 draw the standard raised segment. Never fill the selection with brand green, and never hand-build a segmented control. A row of picture choices (ChoiceTile rows) is not a segmented control; it follows the tile rule (§3).

**Why it is green today:** `GreenroomApp.swift` applies `.tint(Brand.green)` at every scene root (needed so a System Settings accent cannot turn Start blue). On macOS a tinted segmented control fills its selected segment with the tint. `GreenroomSegmented` applies `.tint(nil)` (or a neutral tint if nil falls back to the user's accent) to the picker only, so Start, links and toggles stay green. Check this on 14, 15 and 26 before rolling it out.

**Shared control (built in C1, App/UI/Segmented.swift):**
- `GreenroomSegmented<Value: Hashable>(_ title: String, selection: Binding<Value>, options: [Value], label: (Value) -> Text)`: native segmented Picker, `.labelsHidden()`, `.fixedSize()`, tint cleared. Picture/symbol labels use `Label` inside the native picker.
- `GlassSegmented`: specified, **not built until a call site needs it** (none does today). Only for a truly custom look (icons over captions, unusual sizes). On 26: an `HStack` of plain buttons inside `GlassEffectContainer`, with one selection capsule `.glassEffect(.regular.interactive(), in: Capsule())` + `.glassEffectID("selection", in: ns)` placed behind the selected segment, so it slides between segments. Before 26: the same capsule through `.greenroomGlass(in: Capsule())` with `matchedGeometryEffect(id: "selection", in: ns)`. Motion `.spring(response: 0.3, dampingFraction: 0.85)`; Reduce Motion → no slide, 150ms crossfade (DESIGN.md Motion). Selected label `.primary` semibold, others `.secondary`; hover lifts the label to `.primary`; no brand fill. Accessibility: `.accessibilityRepresentation { Picker(...) }` so VoiceOver hears a real picker; arrow keys move the selection with `onKeyPress(.leftArrow/.rightArrow)`.

**Every segmented or tab control, and what replaces it:**

| file:line | What it is today | Becomes | Chunk |
|---|---|---|---|
| App/UI/ContentView.swift:677-683 | Home mode switcher (New / Join / Record), native, tinted green | `GreenroomSegmented` | C2 |
| App/UI/SessionsContent.swift:748-757 | Session page tabs (Clips / Notes / Transcript / Links), native, tinted | `GreenroomSegmented` at the top of the new inspector | C4 |
| App/Editor/EditorView.swift:244-250 | Editor side panel Info / ✦ Assistant | `GreenroomSegmented` at the top of the `.inspector`; drop the ✦ glyph from the label (use `Label("Assistant", systemImage: "sparkles")`) | C7 |
| App/Editor/EditorView.swift:385-392 | Timeline mode (Trim / Cut) | `GreenroomSegmented`, moved into the window toolbar (`.principal`) | C7 |
| App/Editor/EditorView.swift:~1140-1146 | Segmented in an editor popover/panel | `GreenroomSegmented` | C7 |
| App/Editor/EditorTheme.swift:135-180 | `EditorSegmented`: custom, solid `accentDeep` fill + matchedGeometryEffect, **no callers** | Delete | C7 |
| App/UI/LayoutSettingsTab.swift:~542-547 | Settings → Layout segmented | `GreenroomSegmented` | C6 |
| App/UI/OnboardingView.swift:~536-541 | Onboarding camera-shape segmented | `GreenroomSegmented` | C8 |
| App/UI/WebcamPage.swift:~195-200, ~439-444 | Settings → Webcam segmented pickers | `GreenroomSegmented` | C11 (late: drawing agent is editing this file) |
| App/UI/ParticipantGridWindow.swift:613, 3703 (`FirstClickSegmented: NSSegmentedControl`) | Meeting window Gallery / Speaker, AppKit, forced-dark Zoom look | **No change**: native AppKit already, inside the recorded 2026-11-12 meeting-window decision | none |
| App/UI/SettingsView.swift:42 (`TabView`) | Settings tabs | No change: native toolbar tabs | none |

**Not segmented controls (left to the tile rule, listed so nobody converts them):** the ChoiceTile picture rows `ShareKindPicker` (WebcamPage.swift:~574, C11), YouTube upload mode (YouTubeSettingsTab.swift:~240, C6), Screenroom agent kind (ScreenroomSettingsTab.swift:~330, C6), camera transition (CameraSwitchSection.swift:~276, C6), Webcam shapes and background presets (WebcamPage.swift:~400, ~464, C11); the onboarding step dots (OnboardingView.swift:~760, a pager); and AnnotationToolbar's tool palette (AnnotationToolbar.swift:79-139: the drawing agent's new file, a tool palette, out of scope).

**QA:**
- Accessibility tree: every switcher shows as `AXRadioGroup`/segmented with the right selected value.
- Off-screen render: neutral selection in light and dark (no green).
- On 26, by eye: the glass selection slides; with Reduce Motion on, it does not.
