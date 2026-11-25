# Live preview smoothness: Home's picture keeps up with the hand

Branch: sibhimanyu/hi. Code: `App/Stage/StagePreviewSink.swift`, `App/UI/HomeView.swift`, `App/UI/PreviewFrameRules.swift`, `App/UI/PreviewCameraDrag.swift`. Tests: `Tests/PreviewFrameRulesTests.swift`.

## Problem

Home's LIVE PREVIEW is choppy, and the webcam cutout trails the green drag frame by 100 to 200 ms. The drag itself is lean (`CoordinatorController+Presence.swift` `updatePlacement`); the lag is the picture coming back. The compositor ticks at 30 fps, but `StagePreviewSink` keeps about 1 frame in 4 (`framesPerSecond: 8`), on a utility queue, and renders a second full image for the open mask by rerunning the cutout chain at canvas size. Two other things hitch Home: every 2 s `refreshShareLists()` walks the system window list on the main thread, and the mic meter (about 47 updates a second in a live meeting) re-renders all of `HomeView`.

Why 8: it was the first default in `daec004` (the sink's introduction), written for the Settings preview ("a few times a second ... without the compositor doing anything extra"). No measurement or live-meeting reason is recorded. It was a cost guess made before Home dragged the camera in the picture.

## Goals

- The preview moves with the drag: 30 fps on Home, outside a live meeting.
- Less work per preview frame, so a live meeting is not slowed by it.
- No periodic main-thread stall from the share lists; no whole-Home redraw from the meter.
- Numbers, not feel, for the next round (DEBUG log).

## Non-goals

- Changing the camera resolution or Vision quality. That changes the meeting picture; the owner decides later.
- Drawing the live camera directly in the drag layer (the other way to remove the lag). Not for now.
- Any visible change to the preview's look or the mask's shape.

## Requirements

### R1. Preview rate is a rule, 30 fps by default

`PreviewRate.framesPerSecond(meetingLive:)` is 30 outside a live meeting and 15 while one is live (the meeting, the recorder and the preview then share the render machine). `StagePreviewSink` takes its rate from it. The sink cannot see the session, so it has `meetingLive`, set by the coordinator.

Acceptance: pure rule tested (30 / 15); sink default is 30 with `meetingLive == false`; the coordinator sets `previewSink.meetingLive` where the phase changes (needs one line in `CoordinatorController.swift`, owned by another change; until it lands the rate is 30 always).
Tests: `PreviewRateTests` in `Tests/PreviewFrameRulesTests.swift` (red: `PreviewRate` missing; green after).
Status: built (sink and rule); the coordinator line is pending.

### R2. Preview queue at user-interactive QoS

The sink's queue runs at `.userInteractive` so the downscale is not starved behind the compositor and Vision.

Acceptance: `StagePreviewSink` queue QoS is `.userInteractive`.
Status: open.

### R3. Cheaper open mask

The mask is built at preview size: the cameras' alpha is scaled first, then cut out of a white image of the small extent, instead of cutting at canvas size and scaling after. When no camera draws over shared content `coverage` is nil and no mask is made (already so). Same shape as before.

Acceptance: output size and orientation equal the picture's; mask logic reads as scale, then composite.
Status: open.

### R4. No window-list walk on the main thread

`HomeView.refreshShareLists()` runs `ShareTarget.windows()` off the main actor and publishes `windows` only when the list changed.

Acceptance: the 2 s tick does not call `ShareTarget.windows()` on main; no publish when unchanged.
Status: open.

### R5. The mic meter does not re-render Home

The `MicLevelMonitor` observation moves into a small child view, as `ShapePreviewFeed` does for the picture. `HomeView` no longer observes the meter.

Acceptance: `HomeView` holds the monitor without `@StateObject` observation; only the mic chip's meter view redraws on a level.
Status: open.

### R6. DEBUG measurement

Once a second, category `preview-fps`, one line: compositor ticks, preview pictures delivered, camera frames processed (`CutoutPublisher.process`). All inside `#if DEBUG`.

Acceptance: the lines appear in a Debug build and the symbols are absent from Release.
Status: open.

## How to read the log (R6)

    log stream --predicate 'category == "preview-fps"'

Each line is `ticks=30 pictures=29 camera=30` for the last second. Ticks near 30 and pictures well below is the sink (rate, busy drops). Camera well below ticks is the camera or Vision, which this spec does not touch.

## Manual check (owner)

- Home with the preview open and one camera: drag the camera; the cutout stays inside the green frame with no visible trail.
- Same with two cameras and Cutout on.
- Start a meeting; the preview still moves, a little less often; the meeting picture is as smooth as before.
- Open the Share menu repeatedly for 10 s: no periodic hitch.
- Speak in a live meeting: the mic bars move and the rest of Home does not flicker.
- Run the `log stream` line above and read the numbers on Home and in a live meeting.
