# Layouts builder

One Layouts tab where the owner arranges windows and the camera piece, and
sees exactly what everyone sees. Words follow [GLOSSARY.md](../../GLOSSARY.md).
The main decision is [ADR 0001](../adr/0001-layouts-own-camera-and-share.md).
Statuses follow [the spec rules](README.md#status).

Sources: the design review page and build plan of 2026-11-25 (scratch, in
`.context/layout-rethink/`), and the commits listed under Phases.

## Problem

Two tabs edited one picture. The Webcam tab placed the camera in a 16:9 preview
and the Layout tab placed it again on the canvas; both wrote the same saved
value, so a change in one silently moved the other. "Behind you: Screen" and
the layout's shared display both chose which display is shared. "Camera off"
meant two different things.

Three places each decided "does everyone see this?" on their own: the
builder's badge, the share choice table, and the capture's exception list. The
Greenroom Browser showed as shared in the builder and was cut from the stream.

The owner switches between set-ups whose camera and share differ, but the
camera box and what's shared were global.

## Goals

- One canvas, one truth: what the owner arranges is what everyone sees, except
  pieces hidden from everyone.
- A layout holds everything the meeting sees: windows, the camera piece, the
  shared display and what's shared.
- One rule for who sees each piece, read by the badges, the preview and the
  capture.
- The same four camera states everywhere.
- A builder that behaves like a Mac editor, with one main action per area.
- Day one on an existing install looks the same.

## Non-goals

- The camera state is not saved per layout. It is one setting for every layout
  (a layout can't start "Only me"). A separate decision if ever wanted.
- The camera look (background, effects, mirror) is not per layout.
- Camera devices are never chosen per layout.
- No second "what everyone sees" canvas.
- No Bring forward / Send back: pieces never overlap.
- No ⌘P for Show on screen.

## Owner decisions

All settled by the owner on 2026-11-25, in the numbered rounds of questions
asked in the planning chat (Q1 to Q27). The review page lists them in a
different order; this table is the authority.

| Q | Decision |
| --- | --- |
| Q1 | One canvas, one truth. What you arrange is what everyone sees, except what you hide. |
| Q2 | Each layout saves its camera piece (spot, size, shape). The camera look is shared by every layout. |
| Q3 | "None" goes. Leave my windows alone replaces it and only places the camera. One layout is always active. |
| Q4 | Built-in layouts: Teach from a browser, Talk to the meeting, Present, Room + laptop, Leave my windows alone, Raj San Mode. **Amended by Q28 (2026-11-26).** |
| Q5 | The merged tab is called Layouts. The Webcam tab goes away. |
| Q6 | Each built-in layout has Restore original. Reset all stays as a last resort, behind a confirmation. |
| Q7 | Migration copies today's camera spot, size and shape into every layout. Nothing looks different on day one. |
| Q8 | Existing installs: Raj San Mode stays as edited. Teach from a browser and Meeting and chat are replaced; the old Meeting and chat is kept as your own layout. Nothing is deleted. |
| Q9 | Each layout picks its own shared display, Main by default. Room + laptop shares Main and puts the Room screen on Second. |
| Q10 | Room + laptop with no second display uses its one-display version, and Home says "Connect the room display". It never blocks Start. |
| Q11 | Every piece has two badges, 👁 (on your screen) and 📡 (everyone), each a click to flip. 📡 stays amber when on. Hidden from everyone is striped; camera for everyone only is dashed. Only the camera can be "everyone but not me". |
| Q12 | The camera state is one four-way choice (renamed 2026-11-26, R44: Everyone & me / Only the meeting): Everyone and me / Only everyone / Only me / Off, in the camera inspector, the bar's camera button and Home's camera tile. |
| Q13 | The canvas has a Preview: My screen / Everyone switch, on My screen by default. |
| Q14 | The glossary's Layout definition says the camera is the one piece that can be in everyone's picture without being on your screen. (Separately, after the live browser bug: Greenroom Browser pieces are always in everyone's picture, so their 📡 is fixed on.) |
| Q15 | The Webcam controls split: camera look global, camera piece per layout, camera device on Home and in the Devices tab. |
| Q16 | A Devices tab holds camera devices, the microphone, the four Recording toggles and other apps' recordings. |
| Q17 | What's shared (Screen / App / Window / Whiteboard / Nothing, plus Follow the slide show) is saved per layout under "Everyone sees this ▾". Home's Share panel changes only the running meeting. |
| Q18 | Direction A: the inspector below the canvas. |
| Q19 | Show on screen is a small button beside the Preview switch. No ⌘P. |
| Q20 | Talk to the meeting shares Nothing, and the camera fills the picture. |
| Q21 | Present puts the camera small in a corner. |
| Q22 | + on Leave my windows alone copies it into a new "My layout" and shows "Made a new layout". |
| Q23 | ⌘D duplicates the layout (pieces are unique, so duplicating a piece makes no sense). |
| Q24 | "During the meeting" settings move to the Zoom tab. |
| Q25 | 👁 off means "starts hidden" for Greenroom windows and "opens minimised" for other apps. |
| Q26 | Other apps' 📡 is a real switch, on by default, built on the one rule plus an exclusion in the capture filter. |
| Q27 | Anonymous usage analytics moves to General > Privacy. |
| Q28 | Owner, 2026-11-26. Amends Q4 and Q8. The built-in set is three: **Leave my windows alone** (first card, and the one active after Reset), **Raj San Mode** and **Room + laptop**, in that order. Teach from a browser, Talk to the meeting and Present are no longer built in. On an existing install they stop being built-ins and become the owner's own layouts, unchanged. |

## Requirements

| R | Requirement | Phase | Status |
| --- | --- | --- | --- |
| R1 | One rule for who sees what | P1 | built; the camera answers through it too (`cameraEveryoneSees`) |
| R2 | One eye per piece (was two badges; superseded by Q28 to Q29) | P1 | built; single-eye model with R17 |
| R17 | One icon language | P11 | built |
| R3 | Preview: My screen / Everyone | P1, P5 | built |
| R4 | Each layout owns its camera piece | P3 | built; new layouts own a camera from creation |
| R5 | Each layout owns what's shared and its shared display | P3 | built; Layouts is the only writer (Webcam tab gone in P8) |
| R6 | Four-way camera state everywhere | P2 | built; "Only me" is a mirror (P8, needs a live check) |
| R7 | Other apps' 📡 and 👁 | P4 | built; existing app pieces migrated to 📡 on once |
| R8 | Direction A canvas | P5 | built |
| R9 | Mac editor basics | P6 | built (R9.1 to R9.7); review fixes: one undo step per Size drag, camera state and look undoable, the editor follows an undo, VoiceOver follows the camera state and share |
| R10 | Devices and General tabs | P7 | built |
| R11 | Camera look in Layouts; Webcam tab gone | P8 | built (Mirror is back, R22); the Webcam tab's live picture, corner and Reset are back in the inspector (the S/M/L sizes were superseded by owner, 2026-11-26: size is a drag on the canvas) (needs a live check) |
| R12 | Built-in layouts, one always active (six, then three by R39) | P9, P15 | built (needs a live check); the set is R39 |
| R13 | Restore original and Reset all | P9 | built |
| R14 | Built-ins on existing installs | P9 | built (key `layoutLibrary.builtInsV2Migrated`); an unedited Teach is compared on every saved field (R14.2); a former None user's camera and share go to Leave my windows alone (R14.3) |
| R15 | Room + laptop | P10 | built: Room + laptop ships (R15.1); Home's "Connect the room display" / mirrored note (R15.2, `RoomDisplayNote`) |
| R16 | Day one looks the same; downgrade works | P2, P3, P9 | built (migration keys follow a successful save) |
| R18 | Notes bar: drag, spot per display | none (owner fix) | built, 55f524c; resting display added with the review fixes |
| R19 | Full-display Meeting is adjustable | P11 | built, 71a76b5 |
| R20 | Faded pieces on My screen stay editable | P6 | built, 6cb548a |
| R21 | The camera move note says who the move reaches | P6 | built, 7e94902 |
| R22 | Mirror my camera: the bubble only | P8 | built, 2834566 |
| R23 | Home's preview row: second-display note and Show on screen | none (owner fix) | built, 06a7f30; hidden when no windows are tiled (review fixes) |
| R24 | Room screen is true full screen when the piece fills the display | P10 | built, fb70689 (needs a check on the real big screen) |
| R25 | One arrangement per display: the model ([ADR 0002](../adr/0002-one-arrangement-per-display.md)) | P12 | built |
| R26 | One display connected: main only, the second's pieces ignored | P12 | built |
| R27 | Migration of existing layouts to one arrangement per display | P12 | built |
| R28 | Built-ins fit the model (Raj San Mode, Room + laptop) | P12 | built |
| R29 | Editor: main canvas full width, a dashed strip adds the second, both side by side | P12 | built |
| R30 | Remove second display (SECOND menu, confirmed, undoable) | P12 | built |
| R31 | Display crossing, Preview, badges, camera, Home and the Room screen keep working | P12 | built |
| R32 | One share pop-out for Home (this meeting) and Layouts (at start) | P13 | built; tested as pure rules, rendered off screen |
| R33 | Camera shape tiles shared by Home's Look and the camera inspector | P13 | built |
| R34 | Canvas honesty: Shared tag and Not shared hint on My screen | P13 | built |
| R35 | Every piece inspector: header, at most two rows, no hint paragraphs | P13 | built |
| R36 | Home says when the share is not the whole screen; the Screen tile uses the pop-out's short names | P13 | built |
| R37 | Preview: Everyone draws the meeting's real picture | P14 | built; rects tested against the renderer (needs a live look) |
| R38 | Bug list: the solid backdrop follows light / dark | bug list | built |
| R39 | Three built-ins: Leave my windows alone, Raj San Mode, Room + laptop (Q28) | P15 | built |
| R40 | Existing installs: Teach, Talk and Present become the owner's own, once | P15 | built (key `layoutLibrary.threeBuiltInsMigrated`) |
| R41 | The Leave my windows alone card draws an empty display with the camera | P15 | built (rendered off screen) |
| R42 | The card strip fades at a scrolling edge and keeps the chosen card in view | P15 | built (rendered off screen) |
| R43 | Rounded camera by default (Raj San Mode: Cutout) | P15 | built |
| R44 | Camera state names and canvas captions | P15 | built (rendered off screen) |
| R45 | Bug list: a layout places windows once; only Snap re-places; never steals focus | bug list | built; rules tested, not driven live |
| R46 | The Room screen is a real macOS window, native full screen included | owner, 2026-11-26 | built; rules tested (needs a live check on the room display) |
| R47 | Show my camera, per Room screen | owner, 2026-11-26 | built; rules and codec tested (needs a live look) |
| R48 | A meeting starts on the Bar unless the layout places a Meeting window piece | owner, 2026-11-26 | built; model tested (needs a live start) |
| R49 | Stop video: Zoom's own full video off, apart from the camera state | owner, 2026-11-26, option A | built; rules and matrix tested, rendered off screen (needs a live check: the name tile, Start video) |

**R38. Bug list: the solid backdrop follows light / dark.** (`SolidSheet`, App/UI/SolidSheet.swift)
- R38.1 The solid sheet under a window the class sees re-resolves its dynamic colour (`windowBackgroundColor`)
  whenever its appearance changes, so a light/dark switch never leaves white text on a white sheet.

**R45. Bug list: placed once, only Snap re-places, never steals focus.** (`LayoutPlacementRules`, App/Layout/LayoutPlacementRules.swift; owner, 2026-11-26: "it should only snap back into place when I tell it to ... It should not play tug of war and suddenly change window focus")
- R45.1 A layout places windows at Start, when the owner switches layouts (Apply now, a Use-layout shortcut, the
  Present menu) and when the owner asks (the Snap shortcut, the menu bar's Snap Windows Back). Those passes put
  every window back, one the owner moved included.
- R45.2 Nothing else moves a window that is up: not an edit to the running layout (kept for the next Snap Back),
  not the Meeting coming back from the bar or the speaker-tile shortcut, not the one-second loop, not a
  resolution, arrangement or Dock change. A window that appears later (an app that launched late, a view that
  never opened) is placed once, when it first appears.
- R45.3 The neighbour that grows into the Meeting's gap stays where the owner put it if they moved it. Dragging
  the Greenroom Browser by the empty parts of its tab strip or toolbar is such a move (`BrowserChromeDrag`).
- R45.4 Placing never activates an app or takes keyboard focus. The one hand-off is the end of Start (the largest
  app on the main display). Only a pass the owner asked for orders placed windows front.
- R45.5 A display plugged in or pulled out keeps today's behaviour: everything is placed again and ordered front
  (no app is activated).
- R45.6 Coming back to a desktop keeps Greenroom's windows stacked exactly as the owner left them: a view window
  put over the Greenroom Browser stays over it. Greenroom orders nothing front on a desktop switch; the order it
  remembered is put back without activating or taking key, unless the owner clicked or typed first. A window we
  hid that must come back (the meeting window's safety check) goes back above the window that was under it, not
  to the front (`WindowStackRules`, `WindowStackKeeper`; owner, 2026-11-26: Self view went behind the browser).
- R45.7 The stranded-window rescue moves only a window whose frame touches no listed screen, checked once the
  displays have been quiet for 1.5 s (a newer change restarts the wait); a window on a screen still listed never
  moves. Each rescue logs the window, its frame and every listed screen (`StrandedWindowRule`; owner's log,
  2026-11-26: AirPlay renegotiating moved windows between two listed screens).

**R1. One rule for who sees what.** (Q1, Q14)
- R1.1 `Visibility.everyoneSees` and `Visibility.onMyScreen` are the only place
  that decides a piece's badges. The switch over piece kinds has no `default`.
- R1.2 The capture's exception list (`ShowOnShare.exceptionIDs`,
  `ShareVisibleWindows`) is built from the rule, not from its own table.
- R1.3 For every piece kind × share target × badge state, the rule's answer
  equals what the capture filter lets through (the table test).
- R1.4 The Greenroom Browser is fixed on in a whole-display share.

**R2. One eye per piece.** (Q11, Q25, Q28, Q29; replaces the two-badge model)
- R2.1 Every piece shows one icon, the eye (`everyoneSees`). A click flips it when it can change.
  "Starts hidden on my screen" is no icon: the piece is drawn with a dashed outline, and the
  switch is in the inspector and the right-click menu.
- R2.2 An eye the current share target can't honour is drawn fixed, with its
  reason as hover help, and is never clickable.
- R2.3 A window that starts hidden is not in everyone's picture; turning the eye on makes it start shown.
- R2.4 Only the camera can be in everyone's picture and off the owner's screen;
  it then has a dashed outline. Pieces hidden from everyone look hidden.

**R3. Preview: My screen / Everyone.** (Q13, Q19)
- R3.1 The shared canvas has the switch, on My screen when the tab opens.
- R3.2 In Everyone, pieces hidden from everyone are not drawn.
- R3.3 Show on screen sits beside the switch.

**R4. Each layout owns its camera piece.** (Q2, Q7)
- R4.1 A layout saves the camera's shape, spot and size (`LayoutTemplate.camera`).
- R4.2 Two layouts with different cameras each show their own at Start.
- R4.2a With no meeting running, an edit in Settings to the active layout's camera or share reaches
  the working copy and the live picture at once (`LayoutPieceAdoption.forLibraryEdit`); an edit to
  another layout never does.
- R4.3 A drag on Home, the bubble or in the meeting changes only the running
  meeting, never the saved layout.
- R4.4 The camera piece is drawn on the shared display's canvas (Second when
  that is shared and connected, else Main).

**R5. Each layout owns what's shared and its shared display.** (Q9, Q17)
- R5.1 A layout saves what's shared (`LayoutTemplate.share`: kind, window,
  follow the slide show) and its shared display.
- R5.2 Home's Share panel and the bar change only the running meeting.
- R5.3 Start and Snap Back load the active layout's share again. A share chosen
  on Home before Start is kept for that meeting only.

**R6. Four-way camera state everywhere.** (Q12)
- R6.1 The same four words and meanings appear in Settings > Layouts, the bar's
  camera menu and Home's camera tile.
- R6.2 Settings holds the saved default used at each Start. A change from the
  bar or Home is for the running meeting and never writes the default.
- R6.3 Start and Snap Back drop the live change.
- R6.4 Off and Only me hide the camera from everyone whatever else is set,
  camera switching included. The one exception is Just my camera (share
  Nothing): the camera is then the whole picture and stays in.
  `Visibility.cameraEveryoneSees` is the only place that decides it.
- R6.5 Only me keeps the camera open for the owner's bubble while the Stage leaves it out
  of everyone's picture (`Visibility.cameraMirrorOnly`, `cameraRuns`; `StageLayout.mirrorsCamera`).
  Only Off closes the camera. Needs a live check (item 10 below). Other apps' recorders never
  record the bubble in Only me (`PresenceRecorderRules`; the recordings switch no longer exists).
- R6.6 (2026-11-25) One camera button on the bar and the Meeting window toolbar (the second, bubble cell is
  gone). A click toggles the camera for everyone: any "on" state goes Off, and Off returns as the last "on"
  state (Only everyone comes back as Only everyone); with nothing shared a click does not turn it off. A small
  arrow opens the four states (the toolbar's also lists the cameras); outside a meeting the arrow does nothing.
  For the running meeting only, never the saved default. The "last on" state lives with the live camera state
  (`CameraStateSession.lastOn`, `clickTarget`, `turnOnTarget`), so the bar, the toolbar and Home's camera tile
  follow one rule; Start and Snap Back reset it to the layout default's on-state (R6.3).
  `MeetingBarModel.cameraClickTarget`, `MeetingBarLayout.camera`.
- R6.7 (2026-11-25) Whether the owner's camera bubble shows is decided only by `Visibility.cameraOnMyScreen`
  (fed to `PresenceVisibility` as `hiddenByPresenter`), for every share kind (Whole screen, A window,
  Whiteboard, Just my camera). The share kind decides only where it sits: a whiteboard or Just my camera
  uses the visible frame of the whiteboard's display, else the main display.
- R6.8 (2026-11-26) Every control that turns the owner's camera on or off goes through the camera state: the bar and
  toolbar button, Home, the camera shortcut (its toast names the state: "Camera: Off") and the "You" tile's hover button.
  Zoom's own video mute for the owner (`setMyVideo`) is called only by Stop video (R49; a source scan allows that one call). Home's camera
  chip names the state when the camera is out of the picture ("Only me", not "Off"). The owner's own People row is
  struck when the camera is out of the picture (`SelfViewRules.ownRowCameraOff`). A layout switch mid-meeting keeps the
  live camera state (the state is not part of a layout; owner confirmed, 2026-11-26, option A); Start, Snap Back and the end drop it (R6.3).
  `Tests/CameraMatrixTests.swift` holds the whole matrix.
- R6.9 (owner, 2026-11-26, option (a)) The Meeting window's "You" tile shows Zoom's render of the owner's own video,
  which is the Stage: what everyone sees. In Off and Only me the Stage leaves the camera out, so the tile shows the
  shared picture alone, with a small corner mark (top left): the camera state's icon (`VisibilitySymbol.camera`) and its
  name as tooltip and VoiceOver label. Everyone & me and Only the meeting get no mark. A "Camera off" placeholder is
  prepared (`SelfViewContent.placeholder`, `SelfViewRules.showsPlaceholderWhenCameraIsOut`), not shown.
- The Devices tab holds devices only: it has no "No camera" card.

**R7. Other apps' 📡 and 👁.** (Q25, Q26)
- R7.1 An app piece's 📡 is on by default. Off keeps that app out of a
  whole-display share, recordings and the Room screen.
- R7.2 A hidden app that launches or quits after Start is caught within about
  a second.
- R7.3 An app piece with 👁 off opens minimised.
- R7.4 The Greenroom Browser stays fixed on.
- R7.5 An app that launches and is not yet listed by ScreenCaptureKit is retried
  on the next one-second tick, not recorded as excluded.

**R8. Direction A canvas.** (Q18, Q19, Q23)
- R8.1 The inspector sits below the canvases and shows only for a selection;
  its empty state is the layout's description.
- R8.2 Each canvas has its own +. A ghost "+ Second display" canvas adds the
  two-display version.
- R8.3 "Second ▾" holds the display picker and Remove two-display version (superseded by R30: Remove second display).
- R8.4 One ⋯ menu holds Rename, Duplicate (⌘D) and Delete.
- R8.5 Every canvas header is one line. The shared canvas's holds "Everyone sees this ▾",
  which also marks it as the shared display (no separate SHARED tag); the Preview switch and
  Show on screen sit on the layout's title row beside One display / Two displays, and fit at
  Settings' 760pt width.

**R9. Mac editor basics.**
- R9.1 ⌘Z and ⇧⌘Z undo and redo every committed edit; a drag is one step; the
  Edit menu shows them.
- R9.2 Delete removes the selection; on the camera it says "Your camera can't be
  removed. Hide it on your screen instead."
- R9.3 Esc deselects and cancels a drag in progress.
- R9.4 Right-click menus on pieces and cards.
- R9.5 Tab continues to the other canvas and the camera piece.
- R9.6 Tiles show a 1pt hover outline.
- R9.7 VoiceOver names the canvases, the camera piece and the hidden state.
- Built: Delete, Esc and Tab within a canvas (a7e3082, `LayoutKeyRules`); ⌘D is a
  real shortcut while the Layouts tab is on screen; the rest is P6.

**R10. Devices and General tabs.** (Q16, Q24, Q27)
- R10.1 Devices holds cameras, the microphone, the four Recording options and
  other apps' recordings.
- R10.2 General > Privacy holds analytics. "During the meeting" is on the Zoom tab.
- R10.3 Home's links open the right tab. Every saved key stays the same.

**R11. Camera look in Layouts; Webcam tab gone.** (Q5, Q15)
- R11.1 Selecting the camera piece shows a header (live thumbnail, ⋯ menu for the corner and
  Reset size and position), who sees it (camera state), shape (size is a drag on the canvas; the S/M/L tiles were superseded by owner, 2026-11-26), then
  "Camera look · every layout" (background, removal mode, mirror), folded. (Owner, 2026-11-25:
  two rows at rest, no hint paragraph; this replaces "shape, size, camera state".)
- R11.4 "Mirror my camera" is a plain toggle in the Camera look group and in Home's Camera panel
  (tooltip: "Flips your camera on your screen only. The meeting and Greenroom's recordings always see you
  the right way round."). It flips only the owner's bubble, in every layout and in Only me
  (`CameraLookRules.mirrorsBubble`); the Stage, Greenroom's recordings and the Room screen are never
  flipped (`stageMirrors == false`). Other apps' screen recordings may show the flipped bubble
  (accepted, owner 2026-11-25). It has no "off while other apps can record" condition. Undo: "Change Mirror".
- R11.2 The Webcam tab is gone; every "Adjust webcam…" link opens Layouts with
  the camera piece selected.
- R11.3 The camera preview runs only in Preview: Everyone or while the camera
  piece is selected (`LayoutEditorRules.runsCameraPreview`).

**R12. Six built-in layouts, one always active.** (Q3, Q4, Q20, Q21, Q22)
- R12.1 The six built-ins of Q4 exist, each with its camera and share.
- R12.2 There is no None. Exactly one layout is active, everywhere it is chosen.
- R12.3 Leave my windows alone moves no windows and resets the share choice as
  None did.
- R12.4 + on it makes "My layout" and shows "Made a new layout".

**R13. Restore original and Reset all.** (Q6)
- R13.1 Restore original puts back one built-in and leaves every other layout alone.
- R13.2 Reset all layouts asks first.

**R14. Built-ins on existing installs.** (Q8)
- R14.1 Raj San Mode is untouched. An edited Teach from a browser is kept as your
  own layout. Meeting and chat becomes yours. Nothing is deleted.
- R14.2 "Edited" means any saved field differs from the old shipped Teach: its name, a piece's
  kind, place or eye, its share or its camera. A renamed Teach, or one with its eye or share
  changed, is kept as "My Teach from a browser", never replaced.
- R14.3 A library with no active layout (None) gets Leave my windows alone as its active layout,
  carrying that install's own camera spot, size and shape and its share (`legacyCamera`,
  `legacyShare`), so day one looks the same (Q7). It runs once, with the key set after a
  successful save.

**R15. Room + laptop.** (Q9, Q10)
- R15.1 Main is shared and the Room screen is on Second.
- R15.2 With no second display, the one-display version runs and Home says
  "Connect the room display". Start is never blocked. **Built:** Home's preview footer shows
  the note in amber (`RoomDisplayNote`, tested), with the hint "Set the room's screen as an extended
  display (not mirrored) in System Settings → Displays." and an Open Displays settings link. A mirrored
  second display (`CGDisplayIsInMirrorSet`) says "Your room display is mirrored. Set it to extended to
  use the Room screen." It goes when a display connects.

**R16. Day one looks the same; downgrade works.** (Q7)
- R16.1 Each migration runs once, writes its key only after it succeeds, and a
  re-run changes nothing.
- R16.2 Old keys are kept in step for one release, so a downgrade still works.
- R16.3 Older settings files decode with today's values.

**R18. Notes bar: drag, spot per display.** (owner, 55f524c)
- R18.1 The notes bar is dragged by its background; on release it is kept fully on the display it
  was dropped on and the spot is saved for that display (`NotesBarPlacement`).
- R18.2 At the next show it rests on the display it was last dropped on when that display is
  connected, else on the main display (`NotesBarPlacement.restingDisplay`).

**R19. Full-display Meeting is adjustable.** (owner, 71a76b5)
- R19.1 A Meeting window that fills its display shows its handles. Moving or resizing it turns
  fill off, in one undo step; the "Fill this display" toggle says what changes.

**R20. Faded pieces stay editable.** (owner, 6cb548a)
- R20.1 On My screen every piece can be selected, dragged, resized and moved by key, faded or not,
  on a display that is not connected too. Only Preview: Everyone is read-only
  (`LayoutEditorRules.piecesAreInteractive(previewEveryone:)`).

**R21. The camera move note.** (owner, 7e94902)
- R21.1 Dragging the camera says who the move reaches, from the camera state, never a fixed
  "moves for everyone" (`LayoutEditorRules.cameraMoveNote`).

**R22. Mirror my camera: bubble only.** (owner, 2834566)
- R22.1 See R11.4: the toggle is back, in the Camera look and Home's Camera panel; it flips only
  the owner's bubble. R11.1 lists it in the Camera look group.

**R23. Home's preview row.** (owner, 06a7f30)
- R23.1 Under the live preview: the second-display note on the left, Show on screen on the right.
- R23.2 The whole row is hidden, with its height kept, when the active layout tiles no windows:
  no pieces, or Leave my windows alone (it moves none, even with pieces in it). The camera is
  not a piece (`PreviewSecondDisplayRules.row(for:)`).

**R24. Room screen true full screen.** (owner, fb70689)
- R24.1 A Room screen piece set to fill the display covers the display's whole frame, above the
  menu bar and Dock, picture aspect fit on black. A smaller piece stays a normal window at its rect.
  Replaced by R46: the full piece now uses native full screen.

**R46. The Room screen is a real macOS window.** (owner, 2026-11-26)
- R46.1 It is a normal titled window (title bar see-through over the picture): it can be dragged,
  resized and moved to another display during the meeting.
- R46.2 A piece that fills the display goes into macOS full screen on that display: the title bar
  shows on hover, the green button and ⌃⌘F leave full screen. A smaller piece is a window at its rect
  (`RoomScreenRules.placeSteps`).
- R46.3 Once the owner moves, resizes or changes its full screen by hand, Greenroom leaves it where
  they put it for the rest of the meeting (`RoomScreenRules.Ownership`).
- R46.4 Other apps' captures still see it (default sharingType); Greenroom's own share and recordings
  still leave it out with the whole app.

**R47. Show my camera, per Room screen.** (owner, 2026-11-26)
- R47.1 The Room screen inspector has one row at rest, a Toggle "Show my camera" with a tooltip
  (`PieceInspectorRules.rows`: `[.showMyCamera]`; no hint paragraph).
- R47.2 It is saved per layout on the piece (`LayoutPiece.showsMyCamera`), on by default; layouts saved
  before it decode as on.
- R47.3 Off, the Room screen shows what everyone sees without the owner's camera: the same content and
  layout, the camera's place left empty (`StageCompositor.addCameralessSink`). The compositor renders
  that second picture only while such a Room screen is attached and a camera is drawn: one more
  compose and 1920x1080 render per frame, after the meeting's frame. Without a camera it is the same
  frame. Without a running compositor the Room screen's own capture never has the camera.

**R48. A meeting starts on the Bar unless the layout places a Meeting window piece.** (owner, 2026-11-26: "The
control bar is what should be the default, unless the Zoom-like UI was set in the layout settings"; meeting-surface R3)
- R48.1 At go-live the surface is the Bar, whoever is in the meeting, unless the active layout resolves a Meeting
  window piece (`LayoutEngine.placesMeeting`, decided by `MeetingSurface.wentLive(layoutPlacesMeeting:)`). Leave my
  windows alone has none, so it starts on the Bar; a layout of apps or views alone starts on the Bar too.
- R48.2 A layout with a Meeting piece opens the Meeting window where the piece says (rectangle or full display).
- R48.3 Someone joining does not open the window. The Bar's Meeting button and ⌃⌥⌘H open it on demand.

**R49. Stop video.** (owner, 2026-11-26, option A: "nothing goes to the meeting, not even the screen"; amends R6.6, R6.8, R17.3)
(`StopVideoRules`, App/UI/StopVideoRules.swift; `CoordinatorController+StopVideo.swift`)
- R49.1 Camera state Off still only takes the camera out of the picture; everyone keeps the shared screen. The four
  camera states stay exactly as they are and keep working while video is stopped. Stop video is separate: Zoom's own
  video mute for the owner (`setMyVideo`), so nothing is sent and everyone sees the owner's name or avatar.
- R49.2 "Stop video" is its own row at the bottom of the camera menu, after a divider, everywhere the menu appears:
  the floating bar's camera arrow, the Meeting toolbar's camera caret (after the cameras) and, while live, Home's
  camera tile. Its note: "Everyone sees your name. Nothing is sent, not even your screen." While stopped it reads
  "Start video" ("Everyone sees your picture again."). `MeetingBarModel.cameraMenu`, `StopVideoRules.menuRow`.
- R49.3 While stopped, the camera button wears Zoom's red, filled `video.slash.fill` (`VisibilitySymbol.videoStopped`,
  tint `.stopped`); the Meeting toolbar's caption reads "Start video". Camera state Off now wears the quiet outline
  `video.slash` (tint `.neutral`, as R17.3 always said), no longer red: red means "the meeting gets nothing from you"
  (a muted microphone, stopped video), and Off still sends the screen. Shape and colour both differ, so colour is
  never the only sign. Home's chip says "Video stopped" with the same mark.
- R49.4 A press on the camera button while stopped starts the video again, back as the camera state that is active;
  it is not a camera-state change. Otherwise the click keeps R6.6. The camera shortcut is unchanged (it still changes
  the camera state). `StopVideoRules.press`, `CoordinatorController.pressCameraButton`.
- R49.5 Zoom's own state is the truth: `videoStopped` is written only from the SDK's video-status callback for the
  owner (`onVideoStatusChange` -> `OwnVideoStatus`), so a stop by a co-host or by Zoom shows correctly. If the SDK
  refuses, a session-log line ("Stop video: Zoom refused. Nothing changed.") and the UI stays as it was.
- R49.6 What keeps running while video is stopped: the local stage, the recording and the Room screen, because they
  are local and never go through Zoom. The camera bubble follows Zoom's video as before (`PresenceVisibility`'s
  `cameraOn`), so it hides while video is stopped.
- R49.7 The Meeting window's "You" tile shows Zoom's video-off look: the owner's name centred on the tile colour
  (`SelfViewRules.content` -> `.placeholder`, drawn by `SelfPreviewView`, as `MeetingTileChrome` draws others), with
  the R6.9 corner mark in Stop video's icon and "Video stopped" as tooltip and VoiceOver label. The owner's own People
  row is struck (it follows Zoom's flag, `SelfViewRules.ownRowCameraOff`).
- R49.8 A layout switch, Snap Back or a camera-state change never starts the video by itself. Start begins with video
  on, as today; the end of the meeting clears it (`StopVideoRules.videoStopped(after: Moment)`).
- R49.9 `SourceScanTests` allows exactly one `.setMyVideo(` call, in `CoordinatorController+StopVideo.swift`, with its
  reason. Every other control still goes through the camera state (R6.8).
- Tests: `Tests/StopVideoRulesTests.swift` (state x stopped table), `Tests/CameraMatrixTests.swift` (videoStopped
  dimension). Render: `scripts/render/stop-video.sh`.

**R17. One icon language.** (Q28 to Q33)
- R17.1 The eye means "everyone sees it" and nothing else: `eye` amber (`Brand.netText` / `MeetingTheme.netNS`)
  in the picture, `eye.slash` neutral for only you. No `dot.radiowaves.left.and.right` anywhere.
- R17.2 A piece that starts hidden on the owner's screen (own windows start hidden; other apps open
  minimised) has a dashed outline like the camera's "Only everyone". The toggle is in the inspector
  ("Starts hidden on my screen" / "Opens minimised") and the right-click menu. One icon per piece.
- R17.3 The camera uses Zoom's icons: `video.fill` on, `video.slash` off. Only everyone: `video.fill` and the dashed
  look; Only me: `video.fill` with an `eye.slash` badge; Off: `video.slash`. Never `eye` alone, never `camera`.
  No camera connected is `video` with a `questionmark.circle.fill` badge.
  The one camera button (R6.6) shows the current state with these icons; tooltip and VoiceOver use the state name.
- R17.4 `App/UI/VisibilitySymbols.swift` is the only place these symbol names are spelled; a test greps
  `App/` and fails on strays (allowed: physical `display` glyph, Cues/Zoom/Debug word lists, the Screenroom
  Recording diagram node).
- R17.5 One icon per action: Share `rectangle.on.rectangle` (stop: `.slash`), Show on screen `rectangle.dashed`,
  screen-recording permission `rectangle.dashed.badge.record`, Blur `aqi.medium`, Just my camera `video`,
  hide the meeting window `rectangle.slash`.
- R17.7 Three more meanings have their own symbol: `nobodyInCamera` (`person.fill.questionmark`, the
  "Can't see you" chip; never the eye), `twoDisplays` (`display.2`, a layout with a second display;
  never Share's glyph) and `noPieces` (`rectangle.dashed`, an empty layout or canvas, "Nothing moves").
- R17.6 Tooltips and VoiceOver say "Everyone sees this" / "Only you" and "Starts hidden on your screen". Never "class".

**R25. One arrangement per display.** ([ADR 0002](../adr/0002-one-arrangement-per-display.md), owner, 2026-11-25)
- R25.1 A layout holds a main arrangement and, optionally, a second-display arrangement. There is no
  separate one-display and two-display version. The main arrangement is stored under the old key
  `oneDisplay`; the second is `twoDisplays.second` (with its display choice and "Everyone sees").
  `twoDisplays.main` no longer exists. `LayoutSlot` has two cases, `.main` and `.second`.
- R25.2 `pieces(for: .main)` is the main arrangement; `.second` is the second (empty when there is none).
  `placedPieces`, `pieceCount`, `firstAppBundleID`, the Meeting-starts-hidden flag and the app swap
  walk both arrangements once each.
- R25.3 `addSecondDisplay()` adds an empty second arrangement (nothing is copied or moved from main);
  `removeSecondDisplay()` drops it with its pieces. Both are no-ops when there is nothing to do.
- R25.4 A file saved by an older build still loads: its `oneDisplay` is the main arrangement, its
  `twoDisplays.second` is the second, its old `twoDisplays.main` is read (decode only, never written)
  so R27 can keep it.
- R25.5 Meeting and Chat limits ("one Meeting, one Chat, up to four apps") count across both arrangements.

**R26. One display connected.**
- R26.1 With one display connected, `LayoutResolver.resolve` places the main arrangement on the main
  display and nothing from the second: no frame, no window, no note about a missing display.
- R26.2 With two connected, main goes on the main display and second on the second display (the saved
  one, else the first that is not main).
- R26.3 A Meeting that sits only on the second arrangement, with no second display, places no Meeting
  window (the owner accepted this).
- R26.4 `substitutingMeetingForActiveSpeaker` counts only the arrangements that are placed: with no
  second display connected, a Meeting on second does not stop main's Active speaker standing in.
- R26.5 The Room screen, the shared display and the camera slot are second-display things: with no
  second display connected they resolve to nothing, to main and to main.

**R27. Migration.** (its own key, run once)
- R27.1 One time, with its own key `layoutLibrary.oneArrangementMigrated`, set only after the library
  saved: each layout keeps `oneDisplay` as main and `twoDisplays.second` as second.
- R27.2 If the old `twoDisplays.main` differs from `oneDisplay` in pieces (kind, rectangle, eye) or
  settings (camera and share are shared by both, so the pieces are what can differ), it is saved as the
  owner's own layout named "<name> (old two-display)" straight after the original: its main is that old
  main, its second is the same second, its camera and share are the original's, `starter` is nil.
- R27.3 An identical main makes no copy. A layout with no second display makes no copy.
- R27.4 An untouched Raj San Mode as the last build shipped it becomes the new Raj San Mode in place
  (same id, no copy); an edited one follows R27.2.
- R27.5 A second run does nothing, even if the library has changed in between. A failed save leaves
  the key unset, so the next launch tries again.
- R27.6 A brand-new install has nothing to migrate and has the key set.

**R28. Built-ins.**
- R28.1 Raj San Mode: main is the browser (9/12), the Active speaker top right (3/12 x 5/12) and Chat
  below it (3/12 x 7/12), as it was one display; second is the Meeting filling the display. Laptop only,
  the speaker is the meeting surface. Adding an Active speaker on main beside a Meeting on second is allowed.
- R28.2 Room + laptop: main is the browser and Chat; second is the Room screen, Main shared.
- R28.3 Leave my windows alone has a main arrangement and no second (Teach, Talk and Present are no longer built in, R39).
- R28.4 `isAsShipped` compares both arrangements and the shared slot.

**R29. Editor canvases.**
- R29.1 There is no One display / Two displays toggle. The main canvas always shows.
- R29.2 With no second arrangement, the main canvas fills the panel's width and its height follows the
  display's aspect, so no empty band is left on its right (the view; `canvasWidths` is for two canvases only).
- R29.3 Also then, a dashed strip (owner, 2026-11-26: 120 to 140pt, `LayoutEditorRules.stripWidth(panelWidth:)`,
  18% of the panel; at 760pt the main canvas is more than 3.5 times its width) as tall as the canvas sits at
  the main canvas's right edge. Centred and stacked it holds a +, "Second display" and "For a room screen or
  another monitor", with the tooltip "Add a second display"
  (`LayoutEditorRules.showsAddSecondStrip(hasSecondDisplay:)`, true only without a second).
  Clicking it adds an empty second arrangement. It shows on every layout, Leave my windows alone included:
  that one cannot take pieces, so the strip, like +, first makes "My layout" from it and adds the second there
  (`LayoutLibrary.addSecondDisplayToActive`). It highlights on hover. The main canvas's own + sits at the
  canvas header's right edge over the canvas, never over the strip.
- R29.4 With a second arrangement the strip is gone and the two canvases sit side by side, both fully
  visible; the main canvas shrinks so both fit the panel width (`canvasWidths` sums to the width minus
  the gap, each follows its own display's aspect).
- R29.5 Preview, the "Everyone sees this" tag, per-canvas + and the camera are unchanged.

**R30. Remove second display.**
- R30.1 The SECOND menu has "Remove second display" (`LayoutEditorRules.secondMenu`); the old
  "Remove two-display version" is gone.
- R30.2 If the second arrangement has pieces, a confirmation comes first
  (`LayoutEditorRules.removeSecondNeedsConfirmation`); an empty one goes without asking.
- R30.3 Removing it is one undo step named "Remove Second Display"; Undo brings the pieces back.
  Adding is "Add Second Display".
- R30.4 After removal the editor shows main alone with the strip, and the active canvas is main.

**R31. Everything else keeps working.**
- R31.1 Dragging a piece to the other canvas and Option-left/right still send it across (R9.x), and
  need a second arrangement: with none, there is no other display to drop on.
- R31.2 Badges, Preview: My screen / Everyone, the camera overlay and "Everyone sees" behave as before.
  The camera sits on the shared canvas: second only when shared and connected, else main.
- R31.3 Home's preview, thumbnails and the two-display badge read the second arrangement; the
  second-display note and Show on screen (R23) follow it. Home's picture shows the main arrangement.
- R31.4 The Room screen can be added only to the second arrangement; the Add panel says to add a second
  display first when there is none.

**R32. One share pop-out.** (owner, 2026-11-25, `.context/layout-rethink/next-ui-refine.md` item 1)
- R32.1 Home's Share pop-out is one shared view (`SharePopout`) with a `context`: `.thisMeeting` (Home, live) or
  `.atStart` (Layouts, saved with the layout). Both are built in `HomeTileMetrics` (width, padding, tile gap).
- R32.2 The header says which: "Screen · this meeting" or "Screen · at start" (`SharePopoutRules.title`).
  At start only saves to the layout: while a meeting runs, an edit made there (the share, the shared display)
  changes the live meeting only through Apply now (`LayoutTemplate.adoptingEdit` keeps the running shared display).
- R32.3 Sections (`SharePopoutRules.sections`): the share tiles always; with a second display and `.atStart`, the
  Main / Second shared-display choice straight after them, only while Whole screen is the share (the shared
  display is what a whole-screen share captures); the windows list for One window or while browsing; the
  slide-show switch for One window. `.atStart` never lists the capture displays or the "isn't open" and
  permission notes (nothing is live); `.thisMeeting` never lists the shared-display choice.
- R32.4 Tiles map to a saved share (`SharePopoutRules.applying`): Whole screen, Whiteboard and Just me set the
  kind and keep the rest; A window sets nothing until a window is picked (nil: the list opens). Picking a window
  (`picking`) sets kind, app, name and title, and keeps "Follow the slide show". A saved One app reads back as the
  whole screen (`readBack`).
- R32.5 At start the window list is the apps (a saved share names an app, not a window): each row is an app with
  no title, chosen when its bundle id is the saved one (`isChosen(.atStart, ...)`, whatever window title the
  share kept), with no app heading above it. Live (`.thisMeeting`) a window row is also told apart by its
  title, since two windows of one app are separate choices.
- R32.6 In Layouts "Everyone sees this" opens this pop-out as a popover, replacing the text menu
  (`LayoutEditorRules.sharedMenu` is gone). Home uses it as before.
- R32.7 Every control in it is one undo step in Layouts (it writes the layout's share and shared display), has a
  VoiceOver label, and its sections fold with `Collapse` (instant with Reduce Motion).

**R33. Camera shape tiles.**
- R33.1 Home's Look tiles (Rounded, Circle, Square, Cutout, Presenter) are one shared view (`CameraShapeTiles`),
  used by Home's Look pop-out and by the camera inspector in place of the Shape picker.
- R33.2 ~~In the inspector the S / M / L tiles sit beside them.~~ Superseded by owner, 2026-11-26: the tiles, `sizePresets`
  and `sizing` are gone; the row is the shape tiles alone, and sizing is a drag on the camera's corner. The ⋯ menu's
  corner picker stays (`isAdjustable`).
- R33.3 Picking a shape is one undo step; the tile's tooltip and VoiceOver label are the shape's name.

**R34. Canvas honesty.** (My screen only; Preview: Everyone is another change)
- R34.1 With One window shared, the chosen window's piece wears a small "Shared" tag (eye, `VisibilitySymbol.everyoneSees(true)`)
  and every other piece fades and shows a "Not shared" hint on hover (`CanvasShareRules.mark`).
- R34.2 With Whiteboard or Just me, every window piece fades and shows "Not shared" on hover; none has a Shared tag.
- R34.3 With Whole screen, no tag and no hint: the piece's own eye says it (R1, R17).
- R34.4 The fade is only a look: pieces stay selectable and editable (R20). The fade is the rule's answer
  (`CanvasShareRules.fades` equals "the meeting does not see it").
- R34.5 The tag and the hint use `VisibilitySymbol` for their icons and say "Shared" / "Not shared" to VoiceOver.

**R35. Every piece inspector is simple.** (owner, item 3d)
- R35.1 One structure for every kind (camera, Chat, Meeting window, views, apps, Room screen): a header (icon, name,
  one quiet readout, a ⋯ menu for secondary actions), then at most two rows at rest
  (`PieceInspectorRules.maxRowsAtRest`, `rows`). A notice (an app missing, Accessibility not granted) may add a
  row while it is true; it is not at rest.
- R35.2 Rows: camera `[whoSees, shape]`; Chat and Room screen none; Meeting window `[startsHidden]`, plus
  `fillDisplay` first on the second display; a view `[startsHidden]`; an app `[app, opensAtStart]`.
- R35.3 Secondary actions live in the ⋯ menu (`PieceInspectorRules.menu`), ending with Remove (also ⌫): an app's
  "Close when the meeting ends", "Opens minimised" (not for the Greenroom Browser, whose eye is fixed), and for the
  Greenroom Browser "Reopen last tabs" and "Search suggestions". The camera's menu keeps the corners and Reset.
- R35.4 No hint paragraphs: what a paragraph said is a tooltip (`PieceInspectorRules.tooltip`, never empty for a
  kind that had a paragraph). The header readout is one value (`readout`: the size in points); columns and rows are its tooltip.
- R35.5 The camera's who-sees choice is a 4-icon segmented control using `VisibilitySymbol.camera(state)`, each with a
  tooltip (the state's name and detail) and a VoiceOver label (the state's name). The "Camera look" fold opens from the
  same row as it, as a quiet button, so there are still two rows.
- R35.6 Every change to the layout is one undo step; folds use `Collapse`; DESIGN.md tokens only. The two
  Greenroom Browser rows in the ⋯ menu ("Reopen last tabs", "Search suggestions") are global browser
  settings, not layout settings: they apply in every layout, are not part of the layout's undo (switching
  them back is the undo), and say so in their tooltip. They stay in this menu (R35.3).

**R36. Home: a quiet hint when the share is not the whole screen.** (owner, 2026-11-25)
- R36.1 While the live share is Just me, Whiteboard or One window, the Layout tile is unchanged (the layout still
  arranges the owner's screen). Its pop-out and the live preview footer show one quiet line
  (`ShareHintRules.hint`): "Arranges your screen. The meeting sees just you." / "...the whiteboard." / "...<app name>."
  (without a name, "one window"). Whole screen has no hint. Secondary caption text, no new chrome.
- R36.2 In the preview footer one note shows at a time, in this order: the room-display note, then this hint,
  then the second-display note (`ShareHintRules.footerNote`).
- R36.3 The Screen tile's label uses the pop-out's short names (`ShareHintRules.tileLabel`): Whole screen / the
  window's app name, cut cleanly with an ellipsis at the end (A window when none is chosen) / Whiteboard / Just me.
  Never "Nothing behind you". The longest label fits one dock tile at the minimum width (`ShareHintRules.maxTileChars`).
**R37. Preview: Everyone draws the meeting's real picture.** One pure function, `StageFrame.contentRect`
(App/Stage/StageFrame.swift), places the shared content on the 1920x1080 output; `StageRenderer.compose` and the
Layouts tab's Preview: Everyone both call it, and both place the camera with `PresenceGeometry.cameraRect`
whose `bounds` is that rect, so the camera never leaves the drawn content.
- R37.1 Whole screen and Whiteboard: margin 0; the source is aspect-fitted in the whole output. A 1512x884
  display (aspect 1.71) is drawn 1847.3 x 1080, centred.
- R37.2 One window or app: a 4.5% margin of the output height on every side, the window alone fitted in what
  is left. Owner's case: a 1134x884 browser is drawn about 1260.7 x 982.8 at (329.6, 48.6).
- R37.3 Presenter look (the camera's shape is Presenter, the camera drawn for everyone, and content): the
  decision is `StageFrame.usesPresenterPanel`, read by the renderer and the preview alike; the content is a panel 78% of the
  output, 2.5% of the width from the right, centred vertically, the source fitted inside it.
- R37.4 Just me: no content rect (nil); the camera is the picture, a square full frame unless the look needs
  removal (`StageFrame.cameraShape`, `cameraFillsFrame`, `fullFrameCameraRect`: the one place for this fallback).
- R37.5 The camera rect is `PresenceGeometry.cameraRect` with `bounds` the content rect. Owner's case with the
  default circle: about x 1129 to 1590, y 554 to 1015, inside the browser.
- R37.6 Preview: Everyone is a 16:9 picture of the output scaled to the canvas width: the #101828 backdrop;
  Whole screen draws the pieces the meeting sees (R3) at their place in the content rect; One window draws
  only the chosen window's piece, filling the content rect; Whiteboard draws a white card and no pieces;
  Just me draws neither; the camera (when everyone sees it) at its rect from R37.5. It is read-only.
- R37.8 Implemented by 58fd53b (the preview and `StageFrame`), with fdebb5a's follow-ups.
- R37.7 For every share kind the preview's content and camera rects equal the renderer's (a test composes a
  real frame and compares `lastContentRect` and the camera's coverage with the preview's numbers).

## Guarantees

- **One truth.** The 👁 and 📡 badges, Preview: Everyone and the capture's
  exception list all come from `Visibility` (`App/Layout/Visibility.swift`). No
  call site keeps its own rule. A new piece kind does not compile until the
  rule has an answer for it.
- **The table test.** `Tests/ShareVisibilityTruthTests.swift` runs every piece
  kind × share target (whole screen, a window chosen or not, whiteboard, just
  me) × badge state, and checks the rule against a pure model of the capture
  filter. Its sample list is an exhaustive switch, so it breaks when a kind is
  added.
- **The DEBUG cross-check.** In DEBUG builds, turning Preview to Everyone while a
  capture is live compares the rule, asked about the capture's own share kind
  (`Visibility.Target(captureKind:)`), with `ShareVisibleWindows.effectiveNumbers`,
  the list the capture really uses. A disagreement is logged and hits
  `assertionFailure`. With no capture running it does nothing.

**R39. Three built-ins.** (Q28; amends Q4, R12.1, R13)
- R39.1 `LayoutLibrary.builtIns()` is Leave my windows alone (`leave-alone`), Raj San Mode (`raj`), Room + laptop
  (`room-laptop`), in that order, each with its camera and share. The strip shows them first, and the
  New layout card is always last.
- R39.2 Reset to defaults gives exactly those three, with Leave my windows alone active.
- R39.3 Restore original and `isAsShipped` work for each of the three; a layout that began as Teach, Talk or
  Present has no original to restore.
- R39.4 Leave my windows alone is still never deleted and still forks on + (R12.3, R12.4).

**R40. Existing installs: the removed three.** (Q28)
- R40.1 One time, with its own key `layoutLibrary.threeBuiltInsMigrated`, set only after the library saved
  (R16.1). Teach from a browser, Talk to the meeting and Present lose their built-in tag and are the owner's own
  layouts, unchanged (same id, name, pieces, camera and share). Nothing is deleted and `activeID` is kept.
- R40.2 The order after it is the built-ins that are in the library (Leave my windows alone, Raj San Mode, Room + laptop)
  first, then every other layout in the order it had. A deleted Raj or Room stays deleted; Leave my windows alone is
  always present.
- R40.3 It runs after the earlier migrations. The P9 migration no longer replaces Teach or adds Talk and
  Present: an install that never ran it ends the same as one that did. A fresh install has the key set and the
  three built-ins. A second run changes nothing.

**R41. The Leave my windows alone card.** (Q28)
- R41.1 Its picture is the same thumbnail the other cards use: an empty display with the camera at its saved
  spot and shape (`LayoutStripRules.thumbnailCamera(for:)`, `LayoutThumbnailRules.cameraRect`), no "no entry" sign.
  Other cards draw their pieces as before.

**R42. The card strip scrolls with a sign of more.** (Q28, DESIGN.md)
- R42.1 A soft fade shows at the left edge only when more is scrolled out that way, and at the right edge only
  when more lies that way (`LayoutStripRules.fades`). No fade when everything fits.
- R42.2 The chosen card scrolls into view when it is chosen and when the tab opens.

**R43. Rounded camera by default.** (owner, 2026-11-26; Raj corrected the same day)
- R43.1 Leave my windows alone and Room + laptop ship with the Rounded camera shape and keep their spot and size.
  Raj San Mode ships with the Cutout (height 0.4 of the picture, right inset 0.02: bottom right, clear of the top
  of Chat where its caption sits). Restore original and Reset to defaults bring these back.
- R43.2 A new blank layout is Rounded (`LayoutCamera.rounded`). A fork or duplicate keeps the camera it was copied
  from. `LayoutCamera()` and decoding still say Circle, so layouts already saved are not changed and no migration
  touches a shape.

**R44. Camera state names and canvas captions.** (owner, 2026-11-26; amends R6, R17)
- R44.1 The four names, one place (`CameraState.name`), used by the inspector, the bar menu and Home: *Everyone &
  me*, *Only the meeting*, *Only me*, *Off*. Four labelled segments measured about 550pt and did not fit the
  inspector's row at 760pt, so the inspector shows a compact menu: the current icon and name, the four choices
  inside, each with its icon; tooltips keep the long line (`detail`). The bar menu and Home's tile use the same names.
- R44.2 The camera piece on the canvas has its own caption and icon per state (`CameraCaptionRules.caption(for:)`):
  Everyone & me "Your camera"; Only the meeting "Hidden on your screen", dashed; Only me "Only you see this" with
  the struck-eye badge; Off "Camera off" with video.slash and the whole piece dimmed. Preview: Everyone draws
  "Your camera" plainly.

## Phases

| Phase | Delivers | Status | Commit |
| --- | --- | --- | --- |
| P1 One truth for who sees what | R1, R2, R3 | built | f5d4b97 |
| P2 Four-way camera state | R6, R16 | built | f9fe057 |
| P3 Per-layout camera piece and what's shared | R4, R5, R16 | built | 2f1961a (camera follows shared display: c80debb) |
| P4 Other apps' 📡 and 👁 | R7 | built | f50a6cd |
| P5 Direction A canvas | R3, R8 | built | 3f6a68c |
| P6 Basics | R9 | built | 6f13f42 (review fixes: 7e94902) |
| P7 Settings reshuffle | R10 | built | f5d4b97 |
| P8 Camera look into Layouts | R11 | built | 19cf8e0 (review fixes: 7e94902) |
| P9 Built-ins, Leave my windows alone, Restore original | R12, R13, R14, R16 | built | f4222d7 |
| P10 Room + laptop | R15 | built (Room + laptop; Home's "Connect the room display" note) | |
| P11 One icon language | R17 | built | 71a76b5 |
| P12 One arrangement per display (ADR 0002) | R25 to R31 | built | 3aa720a (review fixes: this commit) |
| P13 Refined share and inspectors | R32 to R36 | built (rules tested; rendered off screen, not driven live) | cb8fdd5 (review fixes: this commit) |
| P14 Preview: Everyone is the real picture | R37 | built | 58fd53b, fdebb5a (review fixes: this commit) |
| P15 Three built-ins; strip fade; wider second-display strip (Q28) | R39 to R42, R29.3 | built | this commit |

## Known gaps

- **"Only me" is built as a mirror, unverified live (P8).** It is still stored as
  `noCamera` on plus shown on my screen, but the camera now stays open for the
  owner's bubble (`StageLayout.mirrorsCamera`). Camera switching with Only me
  and Zoom's own video-off state are the parts to watch.
- **P9 is unverified live.** Leave my windows alone moving no window, + making "My layout", Restore
  original and the one-time migration are tested as pure rules; the Start path and the Layouts tab
  are not driven. The layout cards strip scrolls horizontally; it now fades at a scrolling edge (R42), checked off screen only.
- A Present built-in has no slide-show window of its own to share (the share is the screen).
- **The header fit at 760pt is unverified** (R8.5). Check the shared canvas
  header with two displays at Settings' fixed width.
- **Nothing is verified live.** Every status above is "built" at most.
- No per-phase flags exist. The build plan asked for `App/LayoutsV2Flags.swift`;
  the phases shipped without it.

## Verified live checklist

Run in a real Zoom meeting, with a second person (or a second device) watching
what everyone sees. Record the date and the R numbers against each line.

1. Whole-screen share, Chat 📡 off: Chat is missing for everyone; turn it on and
   it appears. (R1, R2)
2. The Greenroom Browser is in the stream and in the recording. (R1.4)
3. Preview: Everyone matches what the other person sees, piece for piece. (R3)
4. Start with layout A, then layout B with a different camera spot and shape:
   each shows its own camera. (R4.2)
5. Drag the bubble during the meeting, stop, open Settings: the layout's saved
   camera is unchanged. (R4.3)
6. Change what's shared from Home's Share panel, then Snap Back: the layout's
   share returns. (R5.2, R5.3)
7. Each of the four camera states from the bar menu: the other person sees the
   camera only for Everyone and me and Only everyone; your screen shows it only
   for Everyone and me and Only me. (R6)
8. Safari piece with 📡 off: Safari is on your screen, missing from the stream,
   the recording and the Room screen; a new Safari window is missing too. (R7)
9. Share Second in a two-display layout: the camera sits on Second in the
   picture. (R4.4)

10. Only me: the other person sees no camera, you still see your bubble with live
    video (mirrored if Mirror is on). Switch to Off: the bubble goes. Switch back
    to Everyone and me: the camera returns without a reopen gap. (R6.4, R6.5)
11. Settings > Layouts, camera piece > Camera look: Background, Remove automatically
    / Green screen (with Cutout or Presenter) and Mirror change the picture for
    every layout. Home's Look or Share "More..." opens Layouts with the camera
    selected and the look open. (R11)
12. Stop video from the bar's camera menu: the other person sees your name tile, not
    the screen; the button turns red, the "You" tile shows your name with the mark.
    Press the button: your picture comes back in the camera state you had. Have a
    co-host stop your video: the button shows stopped too. (R49)

## Contradictions found while merging

- Test name: the build plan says `VisibilityRuleTests.swift`; the page and
  f5d4b97 use `ShareVisibilityTruthTests.swift`.
- P2: the plan stores a new `cameraState` key with a `cameraStateMigrated`
  migration. f9fe057 keeps `noCamera` and `cameraShownOnMyScreen` as the stored
  truth, kept in step.
- P4: the plan excludes other apps by window id (`excludingWindows`). f50a6cd
  excludes whole apps (`excludingApplications`) with a one-second watcher.
- Hidden-from-everyone look: the page says striped; f5d4b97 says faded.
- Per-phase flags were planned and not built.
