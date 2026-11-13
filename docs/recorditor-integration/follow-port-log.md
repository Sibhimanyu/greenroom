# Phase 6: presentation follow

Built 2026-11-13 on `rethink-presence`. Debug build, zero errors; GreenroomTests 308 tests, 0 failures (19 new, `Tests/SlideShowFollowTests.swift`).

## What it does

With the share target set to **One window**, a slide show of the same app (Keynote or PowerPoint play mode, a browser's Present, a PDF presentation mode) opens as a new full-screen window. The Stage capture moves to it, and moves back to the chosen window when the show ends. It works in meetings and in record-only mode, recording or not, because the Stage feeds both.

## What was copied

Nothing verbatim. The idea and the order of checks come from Recorditor `ScreenRecorder.checkTrackedWindow` and `retargetWindow` (ZRecorditor @7210322, `native/MacRecorder/Recording/ScreenRecorder.swift` lines ~938-1000, timer at ~1714). Greenroom's version is rewritten around its own Stage, so there is no ported-file header. `SlideShowFollow.swift` says where it comes from.

## Changes against upstream

| Upstream | Greenroom |
|---|---|
| Follows only when the tracked window is NOT on screen (Safari puts the show on its own Space) | Also follows when the chosen window is still on screen but a same-app window as big as a display is IN FRONT of it (Keynote and PowerPoint play mode leave the editor window on screen). A full-screen window BEHIND the chosen one is ignored. |
| "Fullscreen-sized": width within 4 pt, height at least display minus 40 | Frame equal to a display frame within 2 pt on every side (`SlideShowFollow.isFullScreen`). Stricter: a window maximised under the menu bar is not a show. |
| Same PID, layer 0 | Same, plus the chosen window's PID is read from ScreenCaptureKit at Start. Another app's window is never followed. |
| Returns when the original is on screen again | Returns when the show window is gone, or is off screen while the original is back on screen. A show on another Space while the original is also away is kept. |
| One look decides | A move must be seen on two looks in a row (about 2 s) before the capture moves. |
| Retargets with `updateContentFilter` only | `updateContentFilter` then `updateConfiguration`, so the pixel size follows the new window (a show is a different shape from an editor). |
| Timer on the recorder; only while recording | A task on the capture source (1 s), so it runs whenever the Stage has a window capture, in meetings, record-only, and the idle preview. |
| Polls `CGWindowListCopyWindowInfo`; asks ScreenCaptureKit when moving | Same. No permission is needed for the polling. |
| No setting | `ShareTarget.followsSlideShow`, default on. Turning it off mid-show returns to the chosen window at once. |
| Retarget rewrites the target list and border | Greenroom has no target list; `StageScreenSource.capturedWindowID` is updated under its lock. The drawing marks (`ScreenAnnotationController.capturedFrame`) and the phase-2 click mapping (`StageCompositor.videoPosition`) both read `capturedFrame()`, so they follow the new window with no change. |

Never moves while the person is choosing: if a share picker (Settings, Record studio) is on screen AND Greenroom is the front app, the look does nothing. When the show starts, Keynote or the browser is in front, so the picker being open behind it does not block following.

## Seams (Greenroom file:line)

- `App/Stage/SlideShowFollow.swift`: the pure rule (`isFullScreen`, `slideShowWindow`, `decide`).
- `App/Stage/StageScreenSource.swift:53` `followsSlideShow` closure, `:58` `pickersOnScreen`, `:265` starts the look loop after capture starts, `:270` `makeConfiguration(for:)` (factored out of `start()`), `:420` `startFollowing`, `:435` `followLook`, `:470` `retarget`. `stop()` cancels the task.
- `App/Stage/StageCompositor.swift:40` `StageStatus.followingApp`, `:508` wires the live setting and the callback, `:296`/`:468`/`:564` clear it on stop, restart, new capture.
- `App/Stage/ShareTarget.swift:66` the setting; `:74` a decoder that gives saved targets without the key the default (on). It travels in settings export and import with `shareTarget`.
- `App/CoordinatorController.swift:1259` mirrors `followingApp` into `followingSlideShowApp`.
- `App/UI/ShareTargetSettings.swift:123` the toggle, shown only for One window (folds away with `.animation`), and the quiet line "Following Keynote's slide show" (caption, `.secondary`). It appears on both the Webcam page and the Record studio, which share this view.
- `project.yml`: `SlideShowFollow.swift` added to the test target.
- `App/Debug/DebugTour.swift`: DEBUG-only `cmd=shareKind kind=window` for the background tour; `restore` puts the saved kind back.

## Detection rule

On each 1 s look: take the on-screen window list front to back. Walk it until the chosen window; the first window before it with the same PID, layer 0 and a frame equal to a display frame is the show. If the chosen window is not on screen, the first such window anywhere is the show. While following: return when the show window no longer exists, or is off screen while the chosen window is on screen.

## Notched displays

macOS keeps most apps' full-screen windows below the camera housing, so a show window there is the display minus a top strip as tall as `NSScreen.safeAreaInsets.top` (about 32-38 pt). A window maximised with the Dock hidden has the same frame, so the gap alone must not count (`testMaximisedBelowTheMenuBarIsNotFullScreen` still holds).

Rule: an exact display-sized frame is accepted as before. A notch-gap frame (same x and width; y and height off by that display's own top inset, 2 pt tolerance; inset read per display from `NSScreen.safeAreaInsets.top`, matched by display ID, never a constant) is accepted only with a second signal:

1. New window: its id was not among the app's windows (`CGWindowListCopyWindowInfo` `.optionAll`, same PID) when following began or at the previous look. Keynote, PowerPoint and Google Slides create a new window for the show; a window the user merely maximises already existed. The caller (`followLook`) keeps the known set; it is refreshed each look except while a follow candidate is pending, so the candidate still counts as new on the confirming second look.
2. Space change: the chosen window is not on screen at all (the show took a new full-screen Space).

Both are in the pure `SlideShowFollow.slideShowWindow` / `decide` (`knownWindowIDs`, `notchInsets` parameters, defaults keep old behaviour). Why both: a show in the same Space leaves the editor on screen (signal 1 only); Safari-style shows take a Space (signal 2, and the window may also be new). Residual false positive: a user opens a brand-new window of the app and maximises it within one second of creating it with the notch gap; unavoidable without app-specific knowledge.

## Untested

- No real slide show was run (no Keynote, PowerPoint, Google Slides or PDF presentation, no Space switch). The rule is unit-tested; the ScreenCaptureKit retarget (`updateContentFilter` plus `updateConfiguration`) has never run against a real show.
- The Settings toggle was seen in the real app (background tour, `follow-window-Webcam.png`); the "Following ..." line was not, because it needs a show.
- Notched MacBooks: the rule below handles the notch gap, but it has never run on a notched display with a real show (see Notched displays).
- The picture of a full-screen show is fitted with the window margin box, not filled like a whole display. Not changed.
- Saved-target decoding for old settings is covered by code reading and the app launching with existing settings, not by a unit test (`ShareTarget.swift` pulls in too much for the test target).
- Frame-size change mid-recording: the encoder takes the Stage canvas, so it should be unaffected, but no recording was made across a switch.
