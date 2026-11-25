# Meeting surface: one owner for which control surface shows

Branch: sibhimanyu/hi. Code: `App/Meeting/MeetingSurface.swift`. Tests: `Tests/MeetingSurfaceTests.swift`. Style model: `App/SessionPhase.swift`. Existing rules it will replace in part: `App/MeetingCollapseRules.swift` (`MeetingSurfaces`, `MeetingCollapse`, `MeetingSurfacePlan`), `App/LiveExitRules.swift` (`LiveExit.reopenTarget`).

## Terms (also for GLOSSARY.md)

- **Meeting window**: the one titled Greenroom window that shows the meeting and carries its own controls (`ParticipantGridWindowController`).
- **Bar**: the floating control bar (`MeetingControlBarController`) that holds all the controls when the Meeting window is not up.
- **Surface**: one of those two. A live meeting always has exactly one that is the answer to "where are the controls".
- **Settle**: the 0.5 s wait after a cover or desktop change before the surface switches.
- **Morph**: the shrink or expand animation between Meeting window and Bar.

## Problem

Which surface shows is decided in several places that each hear only some events. `MeetingControlBarController.reconcile` shows or hides the Bar from `MeetingSurfaces.barVisible(windowShowing:)`, where "window showing" means visible, not minimised, on the active desktop and not fully covered. It runs on occlusion, minimise, restore, will-close, screen change, desktop switch and open/close calls, with a 0.5 s debounce, and is skipped during a morph. Because events are missed, `healIfNeeded` re-checks once a second from the coordinator's follow loop, and that loop stops once the user closes the window.

Known gaps:

- Zero surfaces: a real minimise when the window cannot shrink (not live, or no Bar); an arranged session whose Bar was never installed because `meetingControls` was nil at install.
- Reopen (Dock, menu bar `bringLiveSessionForward` via `LiveExit.reopenTarget`) uses `meetingWindowIsHidden`, which ignores covered and other-desktop, so it can name a different surface than the Bar's own rule.
- The repair loop is a once-a-second poll that hides missed events and stops after close.

## Decisions (owner)

- D1. A Meeting window fully covered by other apps hands over to the Bar (as today).
- D2. Hiding the window through the speaker tile hands over to the Bar.
- D3. While a meeting is live there is always exactly one control surface: the Meeting window or the Bar. Never zero. The model makes zero unrepresentable while live. The existing zero cases are fixed in the wiring step (R14), as their own labelled commit.
- D4. The 0.5 s settle stays for desktop switch and cover changes. Both surfaces may show only during that settle or during a morph.
- D5. The once-a-second repair is replaced by the model hearing every event. A cheap safety check stays and in DEBUG logs whenever it had to correct something. The model answers "does the screen match?" in one call.
- D6. Out of scope: layout view windows (never a surface) and screen sharing (no rule).

## Requirements

### R1. Not live means no surface
Before a meeting starts and after it ends, the model shows nothing, owes no morph, and has no close question open. Environment events (covered, desktop, minimise, tile) are ignored while idle.
Acceptance: a fresh model has no surface and an empty visible set; every environment event leaves it unchanged; `sessionEnded` from any state returns to that.
Status: built.

### R2. Starting shows the Bar
From `startBegan` until `wentLive`, the surface is the Bar.
Acceptance: after `startBegan` the surface is Bar.
Status: built.

### R3. Going live
`wentLive(alone: true)` with start-small on stays on the Bar; with others present, or with start-small off, the Meeting window shows. `someoneJoined` grows the Bar to the window (a morph) only when the model started small by itself, grow-on-join is on, and the user has not touched collapse, expand or toggle since.
Acceptance: the four combinations behave as listed; a user collapse before someone joins stops the grow.
Status: built.

### R4. Never zero, exactly one outside settle or morph
At every reachable state while live, the surface is Window or Bar, never nil, and the visible set has one member, except during a settle or a morph, when it is the old and the new surface (one or two members).
Acceptance: a search over every reachable state and every event (all event orders, not a bounded length) finds no violation on any transition.
Status: built.

### R5. Collapse, expand, toggle
Collapse goes to the Bar, expand to the Window, toggle to the other. Each is a morph that ends with `morphFinished`. Expand also clears minimised, hidden-by-tile, covered and other-desktop (the window is brought to where the person is). Toggle clears the "started small by itself" mark.
Acceptance: after expand the surface is Window whatever came before; after morphFinished both surfaces are no longer shown together.
Status: built.

### R6. Covered, then uncovered
Window fully covered: the Bar after the settle. Uncovered: the Window after the settle. During the settle the old surface may still be showing with the new one. Same for moved to another desktop and back.
Acceptance: `covered` then `settleElapsed` gives Bar; `uncovered` then `settleElapsed` gives Window; before `settleElapsed` the visible set holds both.
Status: built.

### R7. Speaker-tile hide
Hidden through the speaker tile: the Bar, at once (no settle). Shown again: the Window.
Acceptance: `tileHidden` gives Bar and a visible set of the Bar alone; `tileShown` returns the Window unless something else still keeps it down.
Status: built.

### R8. Minimise and restore
Minimise gives the Bar (a morph). Restore gives the Window unless something else still keeps it down.
Status: built.

### R9. Closing the window
`closeRequested` raises the question; the surface does not change while it is open. Answers: end or leave: session over (none). Shrink: collapse. Cancel: question gone, surface unchanged. `windowClosedByCode` (closed with no question) leaves the Bar, no morph, until expand.
Acceptance: after `closeRequested` the surface is unchanged and `closePromptUp` is true; each answer lands as listed.
Status: built.

### R10. Reopen brings the window forward unless you chose the Bar
`reopenTarget` is the Bar when the person chose it (collapse, close then shrink, toggle to the Bar, the speaker-tile hide, or started small while alone), else the Window: a Bar showing only because the window is covered, on another desktop, minimised, or closed by code (or never opened) still reopens to the Window, as the Dock always did. It is nil only when not live (while starting it is the Bar). The `reopen` event, when the target is the Window, brings it forward: it clears covered, other-desktop, minimised and the code close (the surface becomes the Window at once). When the target is the Bar it changes nothing.
Acceptance: covered, other desktop and minimised each reopen to the Window; each chosen way reopens to the Bar; `reopen` from a covered Bar gives the Window surface; `reopen` of a chosen Bar changes nothing.
Status: built.

### R11. Session end
`sessionEnded` from any state, mid-morph or mid-question included, gives no surface, no morph and no question.
Status: built.

### R12. The screen-match check
`screenMatches(_ onScreen: Set<Surface>)` is true when, live, the set is not empty and is within the visible set, or, not live, the set is empty. One call; the caller decides what to do and logs.
Acceptance: Window alone while the target is Bar outside a settle does not match; both during a settle matches; empty while live never matches.
Status: built.

### R13. Wiring: the controllers report events
The existing functions listed under Wiring send events to the model and draw what it says.
Status: planned.

### R14. Wiring: the zero-surface fixes
As their own labelled commit: (a) a real minimise when the window cannot shrink goes to the Bar, installing it if needed; (b) an arranged session installs the Bar even if `meetingControls` was nil at install time, by installing on `wentLive`.
Acceptance: neither case leaves zero surfaces while live; checked by the model's `screenMatches` in DEBUG.
Status: planned.

## Wiring (later, after the Zoom-window-mode deletion lands)

Calls into the model (each is one `apply`, then draw `visible`):

- `MeetingControlBarController.reconcile` / `morph`: stop deciding from `barVisible(windowShowing:)`; apply the event, show or hide from `surface` and `visible`.
- `ParticipantGridWindowController` occlusion, minimise/restore, will-close, screen change, desktop switch handlers and the speaker-tile hide: send `covered`/`uncovered`, `minimised`/`restored`, `closeRequested`/`windowClosedByCode`, `movedToOtherDesktop`/`backOnDesktop`, `tileHidden`/`tileShown`.
- `ParticipantGridWindowController.meetingWindowIsShowing` / `meetingWindowIsHidden`: replaced by `surface == .window`.
- `LiveExit.reopenTarget` callers (`bringLiveSessionForward`, Dock click): use `reopenTarget`.
- `CoordinatorController` start, `startSmallWhileAlone`, `growIfSomeoneJoined`, stop: `startBegan`, `wentLive`, `someoneJoined`, `sessionEnded`.
- The close sheet answers (`LiveExitChoice`): `closeAnswered`.
- `MeetingControls` collapse/expand/toggle: the three events; `morph` completion: `morphFinished`; the 0.5 s debounce timer: `settleElapsed`.

Deleted when wired:

- `MeetingControlBarController.healIfNeeded` and its once-a-second call in the coordinator follow loop (replaced by a DEBUG-logging check with `screenMatches`).
- The `pending` debounce in `reconcile` (the model carries the settle).
- Test-only rules that become redundant: `MeetingSurfaces.barVisible`, `visibleCount`, `isSound`, `wayBack`, `MeetingCollapse`, and their tests, once nothing outside tests calls them; `MeetingSurfacePlan.barVisible` stays until the chrome decision reads the model.

## Manual check (owner)

Run the Debug build from DerivedData (after wiring) and try:

- [ ] Start a meeting alone: a Bar. Someone joins: it grows to the window. Collapse first, then someone joins: it stays a Bar.
- [ ] Cover the Meeting window fully with another app: after half a second the Bar shows; uncover: the window returns.
- [ ] Move the window to another desktop and switch: the Bar shows on yours; switch back: the window.
- [ ] Hide the window with the speaker tile: the Bar shows at once; show it: the window returns.
- [ ] Press the yellow light: the window shrinks to the Bar. Click the Dock icon: you land on the Bar. Expand: the window.
- [ ] Close the window: the question appears and the window stays. Cancel keeps everything; Shrink gives the Bar; End and Leave end the meeting.
- [ ] At no point during the above is there no control surface at all.

### Verification state

The model is built and unit tested (`Tests/MeetingSurfaceTests.swift`, 25 tests, plus the full suite). Nothing is wired or verified live. R13 and R14 stay planned.
