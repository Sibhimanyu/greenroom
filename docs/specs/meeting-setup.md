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
- D7. Out of scope: the camera look (background, effects, framing, mirror) and camera devices. They stay one for the whole app. The Look as one value is the next piece of work.

## Requirements

**R1. Camera state is saved per layout.** (D3) built in P2 (stored, migrated and exported; nothing reads it yet, P3 does)
- R1.1 `LayoutTemplate` holds a camera state. A layout with no camera piece still has one.
- R1.2 On first launch with this change, every existing layout gets the camera state that was saved for the whole app. Built-in layouts' originals use *Everyone & me*; Restore original puts that back.
- R1.3 The settings file carries the camera state inside each layout. The old app-wide key is import-only: an old file's value is applied to every layout it brings in that has none.

**R2. One module owns the meeting setup.** (D5) planned
- R2.1 A pure module (Foundation only, compiled by the test target) holds, for camera state, camera piece and what's shared: the saved value (from the active layout) and an optional for-this-meeting change. (module built in P1)
- R2.2 It answers, per setting: the value in use (the for-this-meeting change if there is one, else the saved value) and whether a for-this-meeting change is in effect. (module built in P1)
- R2.3 Every change goes through it as one call naming the setting, the new value and whether a meeting is live. It returns what changed: the saved layout, the value in use, or both. (module built in P1)
- R2.4 The coordinator keeps no other stored copy of these three values. Any `@Published` mirror kept for `$` sinks is written only from the module, as `SessionPhase.syncFlags` does for the phase.
- R2.5 When the value in use changes, the Stage gets it. No caller has to call `requestShapeApply()` for these three settings.

**R3. Before a meeting, a change is saved.** (D1) planned
- R3.1 Given no meeting is live, when the camera state, camera piece or share is changed on Home, the present menu, a shortcut or Settings → Layouts, then the active layout's saved value changes and no for-this-meeting change exists. (module built in P1)
- R3.2 Home's camera, share and camera-piece controls show one line naming the active layout, for example "Saved to Raj San Mode". "Only for this meeting" is never shown while no meeting is live.
- R3.3 Settings → Layouts and Home show the same value at all times while no meeting is live.

**R4. During a meeting, a change is for this meeting.** (D2) planned
- R4.1 Given a meeting is live, when the camera state, camera piece or share is changed on Home, the bar, the toolbar or the present menu, then the meeting gets it, and the saved layout does not change. (module built in P1)
- R4.2 Given a meeting is live, when it is changed in Settings → Layouts, then the saved value changes. If there is no for-this-meeting change for that setting, the meeting gets it as well. (module built in P1)
- R4.3 Home's line reads "For this meeting" while a for-this-meeting change is in effect.
- R4.4 Settings → Layouts shows the saved value. Where a for-this-meeting change is in effect for the active layout, it shows one line, for example "For this meeting: Only me", with **Keep** (saves the change into the layout and clears it) and **Reset** (clears it, so the meeting gets the saved value). (Keep and Reset: module built in P1)
- R4.5 The Layouts canvas draws the saved camera piece, never a for-this-meeting change, so its drawing and its rows always agree.

**R5. When for-this-meeting changes end.** (D4) planned
- R5.1 Start, Snap Back, a layout switch (by any route: Home, menu bar, present menu, shortcut, Layouts) and the meeting ending each drop every for-this-meeting change. (module built in P1)
- R5.2 A layout switch brings in the new layout's camera state, camera piece and share. Given a meeting is live, the meeting gets them at once.
- R5.3 The camera's "last on" state (`CameraStateSession.lastOn`) resets to the active layout's on-state at the same moments. (lastOn reset: module built in P1)

**R6. No other copies.** (D6) planned
- R6.1 The no-layout fallback writes for `webcamShape` and `shareTarget` are removed after a search confirms nothing reads them. The old keys become import-only in the settings file.
- R6.2 A drag in Settings → Layouts saves only the camera piece being dragged, never a value taken from a working copy.

## Phases

| Phase | Delivers | Status | Commit |
| --- | --- | --- | --- |
| P1 | The pure Meeting setup module and its tests: R2.1 to R2.3, R3.1, R4.1, R4.2, R5.1 (as module behaviour) | built | 91f9e11 |
| P2 | Camera state per layout, migration, settings file: R1 | built | 811a398 |
| P3 | Wire the coordinator to the module; remove the working copies; layout switch brings the layout in: R2.4, R2.5, R5.2, R5.3, R6 | planned | |
| P4 | Screens: Home's layout line, Layouts' "For this meeting" line with Keep and Reset, canvas from saved: R3.2, R3.3, R4.3 to R4.5 | planned | |

Live checks needed (owner watching): R4.1, R4.2, R5.2 in a real meeting.
