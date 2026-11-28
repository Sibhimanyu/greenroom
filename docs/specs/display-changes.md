# Display changes: what happens when a display comes or goes

Terms: `GLOSSARY.md`. Code: `App/Layout/DisplayChangeRules.swift` (pure rules), `CoordinatorController.displaysChanged` (carries them out), `App/Layout/DisplayMonitor.swift` (the settled event). Tests: `Tests/DisplayChangeRulesTests.swift`. Related: `docs/adr/0002-one-arrangement-per-display.md`, `docs/specs/layouts-builder.md` (R45 placement triggers), `docs/specs/meeting-surface.md` (R15 to R21, the same kind of move).

## Problem

What follows a display being plugged in or pulled out was branches inside `CoordinatorController`: what to log, whether to wait for a start, whether to re-tile or leave windows alone. None of it could be tested without the app.

## Goal

- The decisions (the words in the log, defer or act, which trigger, whether it re-tiles) are pure and tested.
- The coordinator reads the answer and does the calls: the stage, the capture display, the rescue of stranded windows, the readiness card, the snap back.
- No visible behaviour change. Quirks are kept and listed.

## Non-goals

- `DisplayMonitor` (settling, rescue, `awaitQuiet`) and `StartChoreography.needsDisplayQuiet` are untouched.
- Which window goes to which display is the layout engine's job (ADR 0002).

## Requirements

### R1. The log line
A change where the set of displays differs says `Displays changed (<parts>). Now: <names>.` where parts are `N unplugged` (when any removed) then `N connected` (when any added), joined by `, `. A change with the same displays says `Display settings changed (resolution or arrangement). Now: <names>.`
Acceptance: removed only, added only, both (unplugged first), and same set each give the exact line. A set change with neither list filled (an order-only difference cannot occur) gives `Displays changed (). Now: ...`.
Status: built.

### R2. What follows a settled change
After the stage, capture display, rescue and readiness card are looked after (always), `DisplayChange.followUp` answers, first match wins:
1. A start or stop is running (`isRunning`): `.deferToStart` (the coordinator notes it for the end of the start).
2. The stage is not live, or Zoom is not joined, or the session arranges no windows: `.nothing`.
3. The trigger is `displaysConnectedOrDisconnected` when the display set changed, else `displaySettingsChanged`. When the trigger is explicit (`LayoutPlacementRules.isExplicit`): `.snapBack(trigger)` (not user initiated). Otherwise `.leaveWindows`, and the coordinator logs that windows stay and Snap Back places the layout again.
Acceptance: each row has a test. A set change re-tiles; the same displays with new settings leave windows alone.
Status: built.

### R3. A display changed while starting
When a display changed during a start, then at the end of the start, if the session arranges windows, it re-tiles with `displaysConnectedOrDisconnected`, whatever the change was. Quirk kept: a settings-only change during a start re-tiles, though the same change outside a start leaves windows alone (R2).
Acceptance: `DisplayChange.snapAfterStart(changedDuringStart:arranges:)` is true only when both are true.
Status: built.

### R4. Is the Meeting still hidden after a re-tile
A re-tile re-resolves the layout. By the person (Snap Back): the Meeting hides if the layout starts it hidden, else shows. Not by the person (a display change, a layout edit): when the layout no longer has a placed Meeting surface, nothing is hidden; otherwise the flag is kept as it was.
Acceptance: `DisplayChange.hiddenAfterRetile(userInitiated:layoutStartsHidden:hasPlacedSurface:wasHidden:)` follows those rows.
Status: built.

## Phases

| Phase | Delivers | Status | Commit |
| --- | --- | --- | --- |
| P1 | This spec and meeting-surface R15 to R21 | built | this commit |
| P2 | Failing tests | built | see git log |
| P3 | `MeetingCollapse` size rules and `DisplayChange` rules; coordinator carries them out | built | see git log |
| P4 | Codemaps, `check.sh` green | built | see git log |

Not verified in a real meeting: plugging a display during a live meeting needs hardware; the full suite and a Debug build cover it, then the owner by hand.
