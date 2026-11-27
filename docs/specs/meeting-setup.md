# Meeting setup: one owner for the layout's camera and share

Branch: sibhimanyu/source-of-truth. Decision: [ADR 0004](../adr/0004-before-a-meeting-home-edits-the-layout.md). Style model: `App/SessionPhase.swift`, `App/Meeting/MeetingSurface.swift`. Replaces parts of [layouts-builder.md](layouts-builder.md) R4.3, R5.2, R5.3, R6.2 and R6.3 (marked there).

## Terms (in GLOSSARY.md)

**Meeting setup**, **Saved**, **For this meeting**, **Camera state** (now saved per layout).

## Problem

Three settings can be changed on Home, from the bar, the toolbar or the present menu, and in Settings → Layouts. Each is stored its own way (survey of 1.10.9, 2026-11-27):

- **Camera state**: one saved value for the whole app plus a live value (`CameraStateSession`). Layouts shows the saved value and every other screen shows the live one. A Home pick made before a meeting is dropped at Start, although Home says "Only for this meeting".
- **Camera piece** (spot, size, shape): saved in the layout plus a working copy (`webcamShape`, bubble fractions). The Layouts canvas draws the working copy while its shape row shows the saved value. A drag in Layouts saves Home's pick into the layout.
- **What's shared**: saved in the layout plus a working copy (`shareTarget`). A Home pick made before a meeting carries into the next meeting.

Also: `webcamShape` and `shareTarget` write a no-layout fallback on every change, and a layout switch (`applyLayoutNow`) may not bring in the new layout's camera piece or share.

The owner saw Home say *Only me* while Layouts said *Everyone & me* (2026-11-27).

## Decisions (owner, 2026-11-27)

- D1. With no meeting live, a change from any screen changes the saved value in the active layout. Home names the layout it changes. (ADR 0004)
- D2. While a meeting is live, a change from Home, the bar, the toolbar or the present menu is for this meeting. Settings → Layouts always edits the saved value.
- D3. Camera state is saved per layout, like the camera piece and what's shared.
- D4. A layout switch brings in the new layout's camera state, camera piece and share in full, and drops any for-this-meeting change. Start, Snap Back and the meeting ending drop them too.
- D5. One module, the Meeting setup, owns all three settings: the active layout's saved values and any for-this-meeting changes. Every screen reads the value in use from it, and every change goes through it.
- D6. The no-layout fallback is deleted (exactly one layout is always active), once a check confirms nothing reads it.
- D8. A camera turned Off for this meeting stays Off across a layout switch; every other for-this-meeting change is dropped (owner, 2026-11-27).
- D7. Out of scope: the camera look (background, effects, framing, mirror) and camera devices. They stay one for the whole app. The Look as one value is the next piece of work.

## Requirements

**R1. Camera state is saved per layout.** (D3) built in P2 (stored, migrated and exported), read by the Meeting setup since P3
- R1.1 `LayoutTemplate` holds a camera state. A layout with no camera piece still has one. (review fix 2026-11-27: `addBlank` now ships Everyone & me, so a new blank layout has one too; test `testANewBlankLayoutIsEveryoneAndMe`)
- R1.2 On first launch with this change, every existing layout gets the camera state that was saved for the whole app. Built-in layouts' originals use *Everyone & me*; Restore original puts that back.
- R1.3 The settings file carries the camera state inside each layout. The old app-wide key is import-only: an old file's value is applied to every layout it brings in that has none. (review fix 2026-11-27: the layout an old file with no library brings in carries the FILE's camera state, camera piece and share, via `SettingsImportRules.completingOldFileLayout`, and so is complete when it becomes active; if no such layout becomes active the file's piece and share are a saved edit of the active layout, never for this meeting)

**R2. One module owns the meeting setup.** (D5) built (P1 module, P3 wiring)
- R2.1 A pure module (Foundation only, compiled by the test target) holds, for camera state, camera piece and what's shared: the saved value (from the active layout) and an optional for-this-meeting change. (module built in P1)
- R2.2 It answers, per setting: the value in use (the for-this-meeting change if there is one, else the saved value) and whether a for-this-meeting change is in effect. (module built in P1)
- R2.3 Every change goes through it as one call naming the setting, the new value and whether a meeting is live. It returns what changed: the saved layout, the value in use, or both. (module built in P1)
- R2.4 The coordinator keeps no other stored copy of these three values. Any `@Published` mirror kept for `$` sinks is written only from the module, as `SessionPhase.syncFlags` does for the phase. (built in P3: `CoordinatorController.meetingSetup`; `cameraState`, `webcamShape`, the bubble fractions and `shareTarget` are computed reads, their setters are the Home door; no mirror was needed because the one `$` sink reads `$meetingSetup`)
- R2.5 When the value in use changes, the Stage gets it. No caller has to call `requestShapeApply()` for these three settings. (built in P3: `applySetupEffect`; `requestShapeApply` stays only for the Look and the display pick)

**R3. Before a meeting, a change is saved.** (D1) R3.1 built (P3); R3.2, R3.3 built (P4)
- R3.1 Given no meeting is live, when the camera state, camera piece or share is changed on Home, the present menu, a shortcut or Settings → Layouts, then the active layout's saved value changes and no for-this-meeting change exists. (module built in P1, wired in P3)
- R3.2 Home's camera, share and camera-piece controls show one line naming the active layout, for example "Saved to Raj San Mode". "Only for this meeting" is never shown while no meeting is live. (built in P4: `MeetingSetupLine.home`, shown by `HomeTilePanel.setupLine`; the static "Only for this meeting." is gone)
- R3.3 Settings → Layouts and Home show the same value at all times while no meeting is live. (built in P4 as a property: with no meeting every change saves and clears the change, so value in use == saved; `MeetingSetupLineTests`)

**R4. During a meeting, a change is for this meeting.** (D2) R4.1, R4.2 built (P3); R4.3 to R4.5 built (P4)
- R4.1 Given a meeting is live, when the camera state, camera piece or share is changed on Home, the bar, the toolbar or the present menu, then the meeting gets it, and the saved layout does not change. (module built in P1, wired in P3; needs a live check)
- R4.2 Given a meeting is live, when it is changed in Settings → Layouts, then the saved value changes. If there is no for-this-meeting change for that setting, the meeting gets it as well. (module built in P1, wired in P3: a library edit is followed as a saved edit; needs a live check)
- R4.3 Home's line reads "For this meeting" while a for-this-meeting change is in effect ("For this recording" during a Record session; review fix 2026-11-27). (built in P4; a meeting up with no change reads "From <layout>", so the panel keeps one height and the person is told before they pick that it will not be saved)
- R4.4 Settings → Layouts shows the saved value. Where a for-this-meeting change is in effect for the active layout, it shows one line, for example "For this meeting: Only me", with **Keep** (saves the change into the layout and clears it) and **Reset** (clears it, so the meeting gets the saved value). (Keep and Reset: module built in P1; P4: `ForThisMeetingLine` under the camera-state row, the shape row and the shared display's header, buttons call `keepForThisMeeting` / `resetForThisMeeting`, folds with `Collapsible`; only the active layout is ever shown in the editor)
- R4.5 The Layouts canvas draws the saved camera piece, never a for-this-meeting change, so its drawing and its rows always agree. (built in P4: `LayoutSettingsTab.cameraModel` reads `savedStageLayout` and the saved share; before P4 it drew `stageLayout`, the value in use. A drag in Layouts that leaves a for-this-meeting piece in effect puts the Stage back)

**R5. When for-this-meeting changes end.** (D4, D8) built (P3; needs a live check)
- R5.1 Start, Snap Back, a layout switch (by any route: Home, menu bar, present menu, shortcut, Layouts) and the meeting ending each drop every for-this-meeting change. The one exception is R5.4: a camera turned Off for this meeting survives a layout switch. (module built in P1, wired in P3)
- R5.2 A layout switch brings in the new layout's camera state, camera piece and share. Given a meeting is live, the meeting gets them at once. (built in P3: the library's active layout changing is the one door, `followLibraryChange`; Apply now also selects the layout it applies)
- R5.3 The camera's "last on" state (`CameraStateSession.lastOn`) resets to the active layout's on-state at the same moments. (built: module in P1, events wired in P3)

- R5.4 Given a camera turned Off for this meeting, when the layout is switched, then the camera is still Off and every other for-this-meeting change is dropped. Start, Snap Back and the meeting ending still drop it. (D8; built in P3, module and tests)

**R6. No other copies.** (D6) R6.1 and R6.2 built
- R6.1 The no-layout fallback writes for `webcamShape` and `shareTarget` are removed after a search confirms nothing reads them. The old keys become import-only in the settings file. (built in P4: a Record session now holds the active layout like Start; no normal path leaves no active layout, so `writeSavedSetup` writes only into the layout. The old keys are still READ at launch for a layout that saves nothing and for a library with no active layout, never written. A damaged file with no active layout keeps changes in memory only. See the finding below.)
- R6.2 A drag in Settings → Layouts saves only the camera piece being dragged, never a value taken from a working copy. (built in P3: `LayoutCamera.placing`, `savedEditCameraPiece`)

## Phases

| Phase | Delivers | Status | Commit |
| --- | --- | --- | --- |
| P1 | The pure Meeting setup module and its tests: R2.1 to R2.3, R3.1, R4.1, R4.2, R5.1 (as module behaviour) | built | 91f9e11 |
| P2 | Camera state per layout, migration, settings file: R1 | built | 811a398 |
| P3 | Wire the coordinator to the module; remove the working copies; layout switch brings the layout in: R2.4, R2.5, R5.2, R5.3, R5.4, R6.2 (R6.1 left, see finding) | built | 789663d |
| P4 | Screens: Home's layout line, Layouts' "For this meeting" line with Keep and Reset, canvas from saved, Record holds the layout and the fallback writes go: R3.2, R3.3, R4.3 to R4.5, R6.1 | built | f1c4010 |

Live checks needed (owner watching): R4.1, R4.2, R5.2, R4.3, R4.4 (Keep, Reset) in a real meeting, and a Record start (Home's layout tile names the layout).

## Finding: R6.1, "No layout" was reachable (fixed in P4)

Home's layout tile reads "No layout" when `CoordinatorController.layoutChoiceName` (CoordinatorController.swift, `layoutChoiceName`) answers "None", mapped at `HomeView.swift:934` and `HomeTilePanelRules.headerValue`. That happens whenever a session is up (`layoutChoiceLocked` = `phase.isInMeeting`) and `sessionTemplate` is nil. Only `start()` sets `sessionTemplate`; `startRecordingFlow()` never does, and a Record start is `isRunning`, so Home shows "No layout" while a Record session is starting. Separately, `layoutLibrary.active` is nil in a library with no Leave my windows alone (`ensureActive` keeps it nil there), which the normal flows cannot produce but a damaged file could. Because of this the no-layout fallback keys stay (read at launch for a layout that saves nothing, written only while no layout is active). P4 fixed it: `startRecordingFlow` sets `sessionTemplate = layoutLibrary.active` (and `sessionArranges = false`, since Record places no windows; `tearDownRecordingScene` clears it), and the fallback writes are deleted. What remains: a damaged file with no active layout still reads "No layout" and keeps changes in memory only.

## Needs a live check (P3 wiring, no test can reach it)

Home pick before a meeting lands in the layout and Layouts shows it; a bar or toolbar pick in a meeting leaves the layout alone and ends with the meeting; Apply now, a card pick in Layouts mid-meeting and the present menu's layout item each bring the new layout's camera, shape and share in at once while a camera turned Off stays Off; Snap Back drops a for-this-meeting share or camera spot; a bubble drag in a meeting is for this meeting; a drag in Layouts saves only that piece; a Record session start and end.
