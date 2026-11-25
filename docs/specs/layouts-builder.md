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
| Q4 | Built-in layouts: Teach from a browser, Talk to the meeting, Present, Room + laptop, Leave my windows alone, Raj San Mode. |
| Q5 | The merged tab is called Layouts. The Webcam tab goes away. |
| Q6 | Each built-in layout has Restore original. Reset all stays as a last resort, behind a confirmation. |
| Q7 | Migration copies today's camera spot, size and shape into every layout. Nothing looks different on day one. |
| Q8 | Existing installs: Raj San Mode stays as edited. Teach from a browser and Meeting and chat are replaced; the old Meeting and chat is kept as your own layout. Nothing is deleted. |
| Q9 | Each layout picks its own shared display, Main by default. Room + laptop shares Main and puts the Room screen on Second. |
| Q10 | Room + laptop with no second display uses its one-display version, and Home says "Connect the room display". It never blocks Start. |
| Q11 | Every piece has two badges, 👁 (on your screen) and 📡 (everyone), each a click to flip. 📡 stays amber when on. Hidden from everyone is striped; camera for everyone only is dashed. Only the camera can be "everyone but not me". |
| Q12 | The camera state is one four-way choice: Everyone and me / Only everyone / Only me / Off, in the camera inspector, the bar's camera button and Home's camera tile. |
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
| R9 | Mac editor basics | P6 | built (R9.1 to R9.7) |
| R10 | Devices and General tabs | P7 | built |
| R11 | Camera look in Layouts; Webcam tab gone | P8 | built (needs a live check) |
| R12 | Six built-in layouts, one always active | P9 | planned |
| R13 | Restore original and Reset all | P9 | planned |
| R14 | Built-ins on existing installs | P9 | planned |
| R15 | Room + laptop | P10 | planned |
| R16 | Day one looks the same; downgrade works | P2, P3, P9 | built for P2, P3 (migration keys follow a successful save) |

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
  Only Off closes the camera. Needs a live check (item 10 below).
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
- R8.3 "Second ▾" holds the display picker and Remove two-display version.
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
- R11.1 Selecting the camera piece shows shape, size, camera state, then
  "Camera look · every layout" (background, removal mode, mirror).
- R11.2 The Webcam tab is gone; every "Adjust webcam…" link opens Layouts with
  the camera piece selected.
- R11.3 The camera preview runs only in Preview: Everyone or while the camera
  piece is selected.

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

**R15. Room + laptop.** (Q9, Q10)
- R15.1 Main is shared and the Room screen is on Second.
- R15.2 With no second display, the one-display version runs and Home says
  "Connect the room display". Start is never blocked.

**R16. Day one looks the same; downgrade works.** (Q7)
- R16.1 Each migration runs once, writes its key only after it succeeds, and a
  re-run changes nothing.
- R16.2 Old keys are kept in step for one release, so a downgrade still works.
- R16.3 Older settings files decode with today's values.

**R17. One icon language.** (Q28 to Q33)
- R17.1 The eye means "everyone sees it" and nothing else: `eye` amber (`Brand.netText` / `MeetingTheme.netNS`)
  in the picture, `eye.slash` neutral for only you. No `dot.radiowaves.left.and.right` anywhere.
- R17.2 A piece that starts hidden on the owner's screen (own windows start hidden; other apps open
  minimised) has a dashed outline like the camera's "Only everyone". The toggle is in the inspector
  ("Starts hidden on my screen" / "Opens minimised") and the right-click menu. One icon per piece.
- R17.3 The camera uses Zoom's icons: `video.fill` on, `video.slash` off. Only everyone: `video.fill` and the dashed
  look; Only me: `video.fill` with an `eye.slash` badge; Off: `video.slash`. Never `eye` alone, never `camera`.
  No camera connected is `video` with a `questionmark.circle.fill` badge.
- R17.4 `App/UI/VisibilitySymbols.swift` is the only place these symbol names are spelled; a test greps
  `App/` and fails on strays (allowed: physical `display` glyph, Cues/Zoom/Debug word lists, the Screenroom
  Recording diagram node).
- R17.5 One icon per action: Share `rectangle.on.rectangle` (stop: `.slash`), Show on screen `rectangle.dashed`,
  screen-recording permission `rectangle.dashed.badge.record`, Blur `aqi.medium`, Just my camera `video`,
  hide the meeting window `rectangle.slash`.
- R17.6 Tooltips and VoiceOver say "Everyone sees this" / "Only you" and "Starts hidden on your screen". Never "class".

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

## Phases

| Phase | Delivers | Status | Commit |
| --- | --- | --- | --- |
| P1 One truth for who sees what | R1, R2, R3 | built | f5d4b97 |
| P2 Four-way camera state | R6, R16 | built | f9fe057 |
| P3 Per-layout camera piece and what's shared | R4, R5, R16 | built | 2f1961a (camera follows shared display: c80debb) |
| P4 Other apps' 📡 and 👁 | R7 | built | f50a6cd |
| P5 Direction A canvas | R3, R8 | built | 3f6a68c |
| P6 Basics | R9 | built | |
| P7 Settings reshuffle | R10 | built | f5d4b97 |
| P8 Camera look into Layouts | R11 | built | |
| P9 Built-ins, Leave my windows alone, Restore original | R12, R13, R14, R16 | planned | |
| P10 Room + laptop | R15 | planned | |
| P11 One icon language | R17 | built | |

## Known gaps

- **"Only me" is built as a mirror, unverified live (P8).** It is still stored as
  `noCamera` on plus shown on my screen, but the camera now stays open for the
  owner's bubble (`StageLayout.mirrorsCamera`). Camera switching with Only me
  and Zoom's own video-off state are the parts to watch.
- **Restore original waits for P9.** The ⋯ menu can offer it, but there are no
  restorable built-ins until P9. Reset all in the ⋯ menu is also P9.
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
