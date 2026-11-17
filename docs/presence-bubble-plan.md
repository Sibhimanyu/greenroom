# Presence bubble: the camera you move on your own screen

Status: plan, not started. Branch `rethink-presence`. Decided 2026-11-17.

## The idea

Today the presenter places the camera in Settings (`WebcamPage` / `LayoutCanvas`),
and a mini stage preview in the meeting UI shows what the class sees.

Instead, the camera appears as a floating bubble on the presenter's real screen.
Dragging or resizing it moves the camera for the class, live. What the presenter
sees on their screen is what the class sees, so the mini preview goes away.

## How Recorditor does it (reference: ~/Desktop/ZRecorditor Ref)

- `CameraBubbleWindow.swift` (`CameraBubbleController`): borderless, non-activating
  `NSPanel`, `.floating`, joins all Spaces, 16:9, 10–80% of display width,
  edge-resize via `BubbleInteractionView.swift`.
- The bubble is **excluded** from screen capture (`ScreenRecorder.swift:859-879`).
- `onMoved` / `onResized` feed a normalized origin and scale to the compositor,
  which draws the camera there (`ScreenRecorder.swift:2493-2551`).
- So the bubble is a control, not a capture source. The camera is still mixed in.

We are not capturing the bubble window itself. That would lose the camera on window
shares, drop the camera to screen-capture frame rate, re-scale it through the screen,
fail in talking-head/whiteboard modes, and need a switch to mixing whenever it is hidden.

## Architecture

```
 camera ─► CutoutPublisher ─┐
                            ├─► StageCompositor/StageRenderer ─► ZoomVideoSender (Zoom camera feed)
 screen ─► StageScreenSource┘          ▲                       └► SessionRecorder
                                       │ live placement + visibility
                     PresenceBubble (NSPanel, excluded from all capture)
```

- **One path.** The compositor stays the only way the camera reaches Zoom and the
  recording. No mode switching.
- **PresenceBubble** (new, ported from `CameraBubbleController`):
  - Shows the camera picture already processed by `CutoutPublisher` (effects, cutout,
    mirroring for self-view).
  - `sharingType = .none`, and kept out of `StageScreenSource`'s filter, so it never
    appears in our capture, a native Zoom share, or other apps' captures.
  - On move/resize it writes the placement into `StageLayout` (width fraction and
    insets, already fractions of the canvas), mapped from display points to the
    1920×1080 canvas.
- **Hide (decided: option A).** "Hide camera" in the control bar hides the bubble
  from the presenter's screen only. The class keeps seeing the camera at its last
  placement. Turning the camera off for everyone stays the existing camera-off control.
- **Removed:** the mini stage preview in the meeting UI (`StagePreviewSink` consumers).
  The full meeting window and the control bar remain.
- **Demoted:** the Settings layout editor becomes a default starting placement, not the
  main way to place the camera.

## Steps

1. Port `CameraBubbleController` + `BubbleInteractionView` as `PresenceBubble`
   (copying approved, see `docs/recorditor-integration/`).
2. Feed it frames from `CutoutPublisher`; confirm it stays out of `StageScreenSource`.
3. Map bubble geometry → `StageLayout` live; compositor reads it each frame.
4. Control-bar "Hide camera" toggle (bubble only).
5. Remove the mini stage preview; trim `LayoutCanvas` to a default placement.
6. Verify: drag/resize reflects in Zoom output and recording; hidden bubble keeps
   the camera in output; bubble never shows in any capture.

## Decisions (2026-11-17)

- Multi-display: the bubble lives on the shared display and moves with the share.
- Full-screen apps and Spaces: the bubble follows (`.canJoinAllSpaces`,
  `.fullScreenAuxiliary`).
- Shape: keep Greenroom's camera shapes, resized by dragging edges/corners;
  not Recorditor's fixed 16:9.
- Talking-head and whiteboard modes: the bubble shows over the full meeting window.
- Mirrored like a self-view (as Recorditor does); the meeting and the recording stay
  unmirrored. First chosen unmirrored, then reversed. Switch: `PresenceBubble.mirrorsSelfView`.

- The view to remove is the **Mini** (`App/UI/MeetingVideo/MeetingMini.swift`): the
  floating stage preview with mic, camera, hide, Bigger, Smaller and End. The meeting
  then has two sizes only: the Meeting window and the Control bar. "Smaller" from the
  Meeting window goes straight to the bar; the bar's "Meeting" button goes back.
- The bubble shows whenever the camera is on during a class or a solo recording;
  hidden otherwise.

## Starting a meeting (2026-11-17)

One smooth movement. Decisions live in `App/StartChoreography.swift` (tested).

1. **Click (t=0).** Home steps aside toward where the Control bar will be (0.25 s,
   shrink and fade, instant under Reduce Motion; it is only ordered out, so
   nothing typed is lost). At the same moment the bar fades in, narrow: grip,
   spinner, "Starting..." and Cancel where End will be. Nothing that needs a live
   meeting is drawn. The presence bubble still appears with the first composited frame.
2. **While starting.** The bar is the only status surface. The notch island stays
   shut for a meeting start; it opens only for a failure. There is no wait for the
   island to grow any more. The text changes to "Joining..." when the meeting step begins.
   SDK auth and the host token are warmed when Home appears (`warmUpForStart`); the
   meeting itself is created only after the click.
3. **Display quiet.** The start waits for the screens to be quiet only if it opens
   apps or places a layout. Otherwise it goes straight to the SDK join.
4. **Live.** The bar widens to the live bar (REC if auto-record). The Meeting
   window opens only if someone else is already in; alone, the bar stays the
   surface and the window comes up when the first person joins. The old 0.5 s bar
   delay at start is gone; the 0.5 s debounce on the bar-or-window rule stays,
   because a window that has just opened has not reported its occlusion yet.
5. **Cancel or failure.** The bar fades out and Home comes back where it was, on
   the page it was on. A failure keeps its message on the island with Try again
   and Close, plus the notification, as before.
6. **End.** Unchanged: Home returns on Home.

Layout starts and scheduled meetings use the same bar; a layout keeps its own
window placement after the meeting is live.
