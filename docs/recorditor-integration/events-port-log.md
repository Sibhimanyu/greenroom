# Phase 2: clicks and keystrokes (events port log)

Built (Debug, zero errors) 2026-11-13. Not tried by hand.

## What was copied

- `App/Recording/InputEventTracker.swift` from `native/MacRecorder/Recording/InputEventTracker.swift` @7210322 (the tracker class, lines 40-end). The `RecordingEvents` model (lines 1-38) was already ported in `App/Editor/RecordingEvents.swift` and is reused, not duplicated.

## Changes vs upstream (tracker)

- `start(screenFrame:elapsed:)` became `start(elapsed:locate:)`. Upstream normalised against one display frame in Cocoa coordinates and skipped clicks entirely for window captures; Greenroom hands in `locate`, a closure from global point to 0...1 video coordinates (mapping below).
- Click point comes from `CGEvent(source: nil)?.location` (CoreGraphics global, top-left origin, the same space as `SCDisplay.frame` / window bounds) instead of `NSEvent.mouseLocation` (Cocoa, bottom-left), so no flip.
- Accessibility gate now covers clicks too. Upstream: "Mouse clicks need no permission", only keys were gated. Now `AXIsProcessTrusted()` false means nothing is monitored and nothing is written, silently. `start` returns false in that case. No prompt from recording.
- Added `IsSecureEventInputEnabled()` guard in `recordKey` (secure input: never log).
- `import Carbon.HIToolbox` (for the secure-input call). Header comment and doc comments rewritten. `display(for:)` and the key table are verbatim.
- Kept as upstream, on purpose: plain typing IS logged, one `Key` per keypress (letters upper-cased, e.g. "H"), modifiers as symbols, specials as arrows/Space/Esc etc. Only control characters without a name are dropped. (The odd `parts.isEmpty ? nil : nil` is upstream.) Consequence: typed text, other than in secure-input fields, lands in the sidecar. The owner asked to keep this; revisit if that is not wanted (option: only log combos with ⌘/⌃/⌥ and specials).

## Coordinate mapping

Global click point `p` (CG points) to video fraction, in `StageCompositor.videoPosition(ofGlobalPoint:)` (`App/Stage/StageCompositor.swift:175`):

```
source = captured display frame            (display or app share: SCDisplay.frame)
       | followed window's CURRENT bounds  (window share, or an app followed as a window)
if !source.contains(p) or no screen drawn  -> click dropped
u = (p.x - source.minX) / source.width      v = (p.y - source.minY) / source.height
rect = where StageRenderer.compose last drew the screen (canvas px, top-left)
x = (rect.minX + u * rect.width)  / canvas.width     y = (rect.minY + v * rect.height) / canvas.height
```

- `rect` is `placed.rect` from `place(_:inside:)` (`App/Stage/StageRenderer.swift:107`, function at ~:240): the screen fitted by aspect into the box, which is the full frame (whole display), the frame minus a 4.5% margin (window/app), or the 78% presenter panel (`StageRenderer.swift:92-100`). Published by `StageRenderer.lastContentRect` (lock-protected, `:49`), cleared at the start of each `compose` (`:90`) so a layout with content off yields nil.
- Sampled at click time (both `rect` and the window bounds), so layout changes, a moved or resized window and the presenter panel are followed. The drawn rect is that of the last rendered frame, up to one frame (33 ms) old.
- The camera bubble is drawn over the screen but a click under it still maps to the screen point below. Not subtracted.
- Window bounds: `StageScreenSource.capturedFrame()` (`App/Stage/StageScreenSource.swift:146`) via `CGWindowListCopyWindowInfo(.optionIncludingWindow)`. Display frame and window ID are recorded in `start()` (`:172`, `:202`, `:292`).
- The active source is `StageInputBoard.activeScreenID` (`StageCompositor.swift:93`); a replacement capture only counts once it has delivered its first frame.

## Time mapping

`t = SessionRecorder.elapsedMilliseconds / 1000` (`App/Recording/SessionRecorder.swift:120`): host clock now minus `firstFrameTime`, which is the PTS of the first frame the encoder wrote (`:373`), the same instant `StageEncoder` passes to `writer.startSession(atSourceTime:)` (`StageEncoder.swift:146`). So `t` is seconds into the file, not since the button press. Before the first frame it is nil and the event is dropped.

TODO (phase 4, pause): when pause exists, `elapsed` must subtract paused time and return nil while paused. Marked in `InputEventTracker.start`.

## Greenroom seams touched

- `App/Recording/SessionRecorder.swift:49,52` two main-thread hooks `onRecordingStarted` / `onRecordingEnded(URL?)`; fired at `:183` (end of `start`) and via `announceEnd` at `:206, :214, :228, :246` (every `stop()` path) and `:425` (unexpected stop: disk full, writer failure). The file is closed before the end hook runs.
- `App/CoordinatorController.swift:1150` `private let inputEvents = InputEventTracker()`; `:4026` calls `wireInputEvents`; `:4061` `wireInputEvents` starts tracking only when `shareTarget.kind != .nothing`, and saves `<video>.events.json` on end. `buildScene` is shared by meeting and Record-mode recordings, so both are covered.
- `App/Stage/StageRenderer.swift:42-55,90,107`, `App/Stage/StageCompositor.swift:93,175`, `App/Stage/StageScreenSource.swift:136-155,172,202,292` as described above.
- `project.yml` unchanged.

## Untested

- Nothing run: no recording, no real click. Verify with a Debug run: record, click at a few known spots, check the `.events.json` and the editor's ripples land on the pictured cursor, for display, app and window shares and the presenter layout.
- Assumed `SCDisplay.frame` and `SCWindow` frames share CGEvent's top-left global space (matches how `ScreenAppMatch` already compares them).
- A window resized mid-recording: ScreenCaptureKit scales the content into the original picture size; the mapping then treats the picture as stretched over the current frame. Unverified.
- Accessibility revoked mid-recording is not noticed; events just stop arriving.
- Whether a global monitor sees keys while Greenroom itself is frontmost: it does not (AppKit only delivers other apps' events), so typing in Greenroom is never logged.

## Keystrokes: shortcuts only (owner's decision, 2026-11-13)

`InputEventTracker.display(for:)` no longer logs plain typing. Upstream logged
every key, so typed text ended up in `.events.json` in plain text.

- Character keys are logged only with ⌘ or ⌃ held. ⇧ and ⌥ alone still type characters, so they don't count.
- Special keys ↩ ⇥ Esc ←→↑↓ are always logged.
- Space and ⌫ are logged only with a modifier, because on their own they would show the length of each word.
- Secure input (password fields) is still skipped completely.

When syncing with upstream, keep this rule.
