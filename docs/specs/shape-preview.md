# Shape preview: one owner for the live picture people look at

Terms: `GLOSSARY.md`. Code: `App/Stage/ShapePreviewRules.swift` (pure rules and state), `App/Stage/ShapePreviewController.swift` (the owner). Tests: `Tests/ShapePreviewRulesTests.swift`. Style models: `docs/specs/session-phase.md`, `docs/specs/meeting-surface.md`. Keeps `docs/specs/live-preview-smoothness.md` (frames on their own object, 30 fps outside a live meeting).

## Problem

The live shape preview (Home's card, Settings → Layouts) was about 500 lines inside `CoordinatorController`: who is looking, whether the compositor runs idle for them, when the camera is let go, what is published. The rules were mixed with the sink, the task and the stage, so none of them could be tested without the app. Earlier bugs came from here: Home's old view leaving turned off the new one's camera (hence one id per Home), and closing Settings blanking Home's card.

## Goal

- One owner holds who is looking, whether the picture is attached to a compositor, and what has been published.
- The rules (who keeps the picture alive, when it stops, what counts as a change) are pure and tested.
- The coordinator reports events (a viewer came or went, a session ended, a setting changed) and reads answers. Views read the same names as before.

## Non-goals

- The camera look (director settings, background removal, effects, mirror) stays on the coordinator.
- `StagePreviewSink` and the compositor are untouched.
- No visible behaviour change.

## Words

- **Viewer**: something that wants the picture on screen. Each Home has its own id; Settings → Layouts is one viewer (`layoutsCamera`).
- **Studio**: a Record start wants the picture too. It is not a viewer, so closing Settings does not blank the Record view and the other way round.
- **Wanted**: at least one viewer, or the studio.
- **Attached**: the preview's sink is on the compositor.
- **Camera busy**: a session owns the camera (starting, up of either kind). Then the preview mirrors that picture and never starts or stops the compositor.

## Requirements

### R1. The picture is wanted while any viewer looks

`viewers` is a set. Opening adds, closing removes. The picture is wanted while the set is not empty or the studio wants it. Opening the same viewer twice is one claim. Closing a viewer that never opened changes nothing.

Acceptance:
- Open Home A, open Home B, close A: the picture is still wanted.
- Close a viewer that is not in the set: no outcome, nothing logged.
- Home A and Home B are different viewers; `layoutsCamera` is a third.

### R2. Only the first viewer starts the picture

Opening a viewer while another is already looking asks for nothing more. The first viewer asks to attach.

Acceptance: `open` returns `firstViewer` for the first, `alreadyShown` for the rest.

### R3. Attaching starts the compositor only when no session owns the camera

When attaching with camera free, the compositor is made and started with the chosen look. With camera busy it only adds the sink to the running one. Nothing attaches when nothing is wanted or it is already attached. After attaching, the idle director is synced.

Acceptance: `attachPlan(cameraBusy:)` is `none` when not wanted or already attached, `startStageThenAdd` when camera is free, `addSinkOnly` when busy.

### R4. The last viewer leaving lets the camera go

When the last viewer leaves: pending applies are cancelled; if the studio still wants the picture nothing else happens; otherwise the sink comes off, and when the camera is free the compositor is stopped (the camera light goes off); then the picture is cleared. While others still look, only the log line.

Acceptance: `close` returns `stillShown`, `keptForStudio`, `detach(stopsStage: Bool)`.
- Last viewer leaves, no session: `detach(stopsStage: true)`.
- Last viewer leaves during a session: `detach(stopsStage: false)`.
- Last viewer leaves while the studio wants it: `keptForStudio`.

### R5. A session ending gives the preview back

When a session ends the preview is no longer attached (its stage went away). If a viewer still looks, it attaches again. A studio that no longer wants it does not. The studio alone does not resume it here.

Acceptance: `sessionEnded()` clears `attached` and returns true only when a viewer is present.

### R6. A stalled preview is started again

When the picture is wanted, camera free, and no frames arrive, it restarts. It does nothing while a session owns the picture, while nothing is wanted, or while frames flow: the stage is running, attached, and (a picture has been published or the caller did not insist). `evenIfRunning` (Home waited seconds with no frame) restarts even a stage that says it is running.

Acceptance: `reviveAction(cameraBusy:stageRunning:evenIfRunning:)` returns `none` or `restart` by that table, tested row by row.

### R7. Frames are on their own object; shape is published only on change

Frames and the open mask go to `ShapePreviewFeed`, never to a coordinator `@Published` property. The coordinator publishes the picture's size (`shapePreviewAspect`) and the content rectangle (`shapePreviewContent`) only when they change, never per frame. Content is nil when there is no frame.

Acceptance: `publish(frame size:, content:)` reports `aspectChanged` and `contentChanged` as false for equal repeated values; true on the first, on a change, and on a change to nil (frame cleared).

### R8. Applying a setting is debounced, latest wins

`requestShapeApply` waits 120 ms and cancels any earlier wait. Applying hands the compositor the configuration when the stage is running, a session owns the camera, or a viewer is looking (the studio alone does not count).

Acceptance: `debounceNanoseconds` is 120_000_000; `shouldApply(stageRunning:cameraBusy:)` follows the rule above.

### R9. Choosing a screen asks for the permission once

A rebuilding apply for a share that captures the screen opens the Screen Recording pane when macOS has not allowed it. Otherwise it does not.

Acceptance: `opensScreenPermission(rebuild:, capturesScreen:, granted:)` is true only for rebuild, captures screen, not granted.

## Phases

| Phase | Delivers | Status | Commit |
| --- | --- | --- | --- |
| P1 | This spec | built | this commit |
| P2 | Failing tests, then `ShapePreviewRules` (R1 to R9 pure) | planned | |
| P3 | `ShapePreviewController` owns sink, task, feed; coordinator forwards | planned | |
| P4 | Codemaps, `check.sh` green | planned | |

Not verified in a real session: attach, release and revival need the real compositor, so they are covered by the full suite and a Debug build, then by the owner trying Home and Settings → Layouts by hand.
