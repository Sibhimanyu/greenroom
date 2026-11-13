# Phase 4: pause, countdown, controls, border, system audio (controls port log)

Built (Debug, zero errors; `GreenroomTests` 249 tests pass) 2026-11-13. Nothing run by hand: no recording, no meeting, no app launch.

Owner decisions applied: pausing affects only the recording file (the meeting keeps going and still sees and hears you); only shortcuts are logged by the events tracker (unchanged).

## What was copied, and every change vs upstream (@7210322)

| Greenroom file | Upstream | Change |
|---|---|---|
| `App/Recording/PauseClock.swift` | `Recording/ScreenRecorder.swift`: `timeOffset`, `pauseBegan`, `timingSnapshot`, `retimed(_:by:)` (`:140-153`, `:1740-1775`, `:2681`) | Reshaped, not verbatim. Upstream keeps one running offset and decides "paused? offset?" when a sample ARRIVES. This keeps the pauses as host-clock intervals and decides by the sample's own timestamp, so a late microphone buffer is judged by when it was heard. `retimed` is upstream's, with the offset in seconds. Old pauses are folded into one number after 30 s. Pure (no AppKit), so it is compiled into `GreenroomTests`. |
| `App/Recording/AudioMixer.swift` | none | New. Upstream writes two audio tracks (system, mic); Greenroom needs one. See "Audio mixing". |
| `App/UI/RecordingChrome.swift` `RecordingControlBarController/View` | `Recording/RecordingControlBar.swift` | Kept: non-activating panel, `.statusBar` level, all Spaces, `.fullScreenAuxiliary`, draggable by background. Changed: look follows DESIGN.md and the meeting pill (material capsule, red REC dot, grey when paused, system symbols) instead of Recorditor's black capsule and its image assets; only REC + timer, pause/resume, stop (no source pickers, comment or drawing buttons: the Record view has the pickers, drawing is phase 5); the frame is remembered and restored with `MeetingBarPlacement.restore` (default: bottom centre of the recorded display). `sharingType = .none` as an extra. |
| `App/UI/RecordingChrome.swift` `RecordingBorderController` | `Recording/RecordingBorderController.swift` | Kept: click-through `.statusBar` panel, rounded for windows and square for displays. Changed: `show(frame:)` / `showTracking(windowID:)` replaced by one `show(provider:)` that asks the live capture for its frame every 0.4 s (follows a moved window, a replaced capture, a changed display). Colour is `Brand.green` at 0.9 (not `Color.green`), 3 pt not 4. |
| `App/UI/RecordingChrome.swift` `CountdownOverlayController/View` | `RecorderView.swift` `CountdownOverlay` (`:1329`) | Upstream is a SwiftUI overlay over Recorditor's Home with a black card. Here it is a window of its own in the middle of the recorded display (material card, 14 pt radius, system rounded numerals), so it shows over whatever is about to be recorded. Never takes keyboard focus: Esc is heard by a local monitor (Greenroom in front) and, with Accessibility on, a global one; the Cancel button and pressing the Record shortcut again also cancel. |
| `App/Stage/StageScreenSource.swift` | `ScreenRecorder.swift:1506,1632-1633` | `capturesAudio`, `excludesCurrentProcessAudio = true`, plus 48 kHz stereo and an `.audio` stream output, only when `captureAudio` is set. Upstream also had a mic output on the stream; Greenroom keeps `MicrophoneTap`. |

Decisions where the owner left a choice:

- **Border while paused: hidden.** A border says "this is being recorded"; paused it is not. It returns on resume. (`RecordingChrome.update`.)
- **Clip buffer while paused: skips paused time too.** Pause means "do not keep this", and the buffer is what a clip shortcut would hand back. It has its own `PauseClock` (`bufferClock`) because the buffer outlives a recording; its timeline is continuous across pauses so segment lengths stay right. Clip shortcuts during a recording mark the recording, not the buffer, so this only matters to the buffer itself.
- **Pause default key: ⌥⇧P** (`ShortcutAction.togglePause`, group Class). No other default uses Shift. It is a global hotkey, so while bound it swallows ⌥⇧P (which types "∏") in other apps, like every other Greenroom shortcut; rebind in Settings → Shortcuts.
- **No setting for the border**, none was asked for. **Paused is shown by a grey dot** (not amber: DESIGN.md reserves amber for "leaves your Mac").

## The pause clock (one paragraph)

`SessionRecorder` never stops the writer. `pause()` opens an interval on `recordingClock` (and `bufferClock`) at host time; `resume()` closes it. Every video frame and audio buffer is looked up by its own host-clock timestamp: inside a pause it is dropped, otherwise it is moved back by the total length of the pauses before it (`PauseClock.offset(at:)`, then `shifted` for frames and `retimed` for audio). The encoder therefore sees one gapless timeline starting at the first frame it wrote; `firstFrameTime` is stored on that same adjusted clock, so the position in the file is `(now - paused(now)) - firstFrameTime`, frozen at the moment the pause began while paused. Pausing before the first frame is fine (the first written frame sets the start). A pause still open at stop or at an unexpected stop is closed so it cannot leak into the clip buffer.

Consumers of the paused-adjusted clock:

- `InputEventTracker` elapsed: `CoordinatorController.wireInputEvents` (`CoordinatorController.swift` ~4125) returns nil while `recorder.isPaused`, otherwise `elapsedMilliseconds` (adjusted). Clicks and shortcuts during a pause are not logged. The phase 2 TODO is resolved.
- Clip marks: `markClip` (`CoordinatorController.swift` ~1960) uses `recorder.elapsedMilliseconds`; marking while paused ends at the moment the pause began.
- Screenroom notes: `SessionNotesBar.swift:150` `position` now uses `coordinator.recordingElapsed(at:)`.
- Visible timers: meeting pill (`MeetingControls.swift:919`), window toolbar caption (`:424`), Record view chip and timer (`RecordStudioView.swift:261,307`), control bar (`RecordingChrome.swift:245`), all via `CoordinatorController.recordingElapsed(at:)` (`:1825`) = wall time since Record minus `recorder.pausedSeconds`.
- Not touched: `recordingStartedAt` itself (still the wall-clock Record press; used for analytics duration band and the session log).

## Audio mixing

One AAC track, as before (`StageEncoder`: 48 kHz stereo, 160 kbps). With "Record the Mac's sound" off, the microphone goes straight to the writers exactly as it did. With it on, `AudioMixer` sits in front: both sources are converted to interleaved stereo Float32 at 48 kHz (`AudioMixer.floats(from:)` handles the microphone's interleaved buffers and ScreenCaptureKit's planar ones), placed on a 48 kHz grid by their own host-clock timestamps (stamp jitter under 10 ms ignored, bigger gaps filled with silence, bigger overlaps trimmed), added at full level and clipped at full scale, and cut into 10 ms chunks held back 150 ms so the slower source can arrive. A source that goes quiet (muted mic, nothing playing) counts as silence and the other drives the clock. Chunks are stamped on the same host clock as the stage frames and then go through the same pause mapping as any audio. When the mic is off or denied, the Mac's sound alone goes through the mixer (`wantsAudio` in `SessionRecorder` is mic-authorised OR system-audio on, for the recording and the clip buffer). The mixer is flushed at stop so the last 150 ms reach the file. No automatic gain: loud system sound plus loud mic can clip.

Sound path: `StageScreenSource.onAudio` (`StageScreenSource.swift:40`, wired in `StageCompositor.swift:459`) → `StageCompositor.onSystemAudio` (only the capture that is on air, `board.activeScreenID`, forwards, so a replacement starting beside the old one is not doubled) → `SessionRecorder.appendSystemAudio`. `excludesCurrentProcessAudio = true` keeps Greenroom's and the meeting's own sound out (the meeting is heard through the microphone/mix side already, and not doubled).

Limits: the sound comes through the screen capture, so it needs something shared under Behind you (display: all the Mac's sound; app: that app's; window: that window's app). With Nothing shared there is no screen stream and no system sound. Toggling the setting mid-session rebuilds the screen capture (the share key includes it).

## Greenroom seams (file:line, after this change)

- `App/Recording/SessionRecorder.swift`: `recordsSystemAudio` property (top), `recordingClock` / `bufferClock` / `mixer`, `elapsed` / `elapsedMilliseconds` (`:140`) now adjusted, `pause()` / `resume()` (`:158,168`), `start` resets the clock, `handle(_:at:)` (`:441`) drops/moves video for the recording and the buffer separately, `appendSystemAudio` (`:499`), `handleMicrophone`, `handleMixed` (`:529`), `route(audio:)` (`:538`), mixer lifecycle in `syncPlumbing` (`:403`), `closePause()` in `stop` and `endUnexpectedly`.
- `App/Recording/InputEventTracker.swift`: doc comment only (TODO resolved).
- `App/Stage/StageScreenSource.swift`: `captureAudio`, `onAudio`, audio stream output and config (`:40-57,230-245`), log line when Greenroom is missing from ScreenCaptureKit's app list (display share).
- `App/Stage/StageCompositor.swift`: `onSystemAudio` + `LockedBox` (`:162`, end of file), `capturedScreenFrame()` (`:172`), `source.onAudio` wiring and `captureSystemAudio` in the share key in `apply` / `syncScreen` (`:459`).
- `App/Stage/StageLayout.swift`: `StageConfiguration.captureSystemAudio`.
- `App/CoordinatorController.swift`: settings `recordingCountdownSeconds` (`:1051`), `recordSystemAudio` (`:1057`); `isRecordingPaused`, `recordingCountdown`, `recordingChrome` next to `isRecording`; `recordingChrome.update` sink (`:1173`); `togglePauseRecording` (`:1809`), `recordingElapsed` (`:1825`), `runRecordingCountdown` (`:1833`), `cancelRecordingCountdown`, `capturedScreenFrame` (`:1858`), `recordedScreen` (`:1861`); `toggleRecording(withCountdown:)` (`:2016`; auto-record passes `false`, `:1495`); `startTake` runs the countdown then `startTakeNow` (`:2238`); `stop(failure:)` and `stopRecordingSession` cancel a countdown; `beginRecording` sets `recordsSystemAudio` (`:2108`); `buildScene` sets it and `stage.onSystemAudio` (`:4202`); `wireInputEvents` paused-aware elapsed; both settings in the transfer file.
- Shortcuts: `ShortcutModel.swift` (`togglePause`, `:233` and the switches), `ShortcutRuntime.swift:111` (also lets the Record shortcut cancel a countdown, `:109`), `Tests/ShortcutModelTests.swift` (Class group is now 7 rows).
- Menu bar: `MenuBarView.swift:56` Pause/Resume Recording with the shortcut hint.
- Meeting bar (pill): `MeetingControls.swift` `recordButton` (`:~855`): idle "Record"; recording shows REC dot + timer, pause/resume, stop in the same 136 pt cell; pill is 52 pt wider (`width` 496 → 548); puck dot goes grey when paused and its right-click menu has Pause/Resume. Meeting window toolbar: `MeetingToolbar.swift` `.record` case adds a Pause/Resume cell while recording; `MeetingToolbarLayout.specs(showsSecurity:recording:)` widens Record to two cells then.
- Record view: floating `RecordingControlBarController` (shown when `isRecording && recordOnlyActive`); the view's own bottom bar gets a pause button, a paused chip and "Cancel" while counting down (`RecordStudioView.swift`).
- Settings: Settings → Webcam → Recording (`WebcamPage.swift`): "Countdown before recording" (Off / 3 / 5 / 10 s, default 3) and "Record the Mac's sound" (default off). Neither has dependent controls, so there is nothing to fold away.
- `project.yml`: `PauseClock.swift` and `AudioMixer.swift` added to `GreenroomTests`; `Tests/PauseClockTests.swift` (pause arithmetic, retiming, mixer alignment/gap/clip/stall, buffer conversion round trip).

## Never in the recorded picture

Checked by reading `StageScreenSource.start`: display share excludes the whole Greenroom app (so the countdown, bar and border, all Greenroom windows, are out); app share includes only the shared app (`SCContentFilter(display:including:[app])`) or its chosen windows; window share is `desktopIndependentWindow`, one window; the "app on another desktop" fallback is also a single window. The border, countdown and bar also set `sharingType = .none` (bar, border), which newer macOS may ignore for ScreenCaptureKit; the filter is what is relied on. The countdown is gone before the file starts. Risk: if macOS does not list Greenroom in `content.applications` at capture start (no windows at that moment), a display share could not exclude it; this now logs a line saying so.

## Untested

- Everything. No real recording, pause, meeting, countdown, border or system-audio run. Verify by hand: record 30 s with a pause in the middle (file length = recorded time, no frozen stretch, A/V in sync after the pause, events sidecar times line up with the ripples after the pause), pause during a meeting (others still see and hear you), countdown 3/5/10 and cancel by Esc, Cancel and the shortcut, the border on display/app/window shares (and a moved window), the control bar never in the picture on each share kind, system audio alone (mic denied) and mixed with the mic, with and without something playing.
- Assumed ScreenCaptureKit audio sample buffers are stamped on the host clock (like its video) and delivered as 48 kHz Float32 planar when asked (`sampleRate` 48000, `channelCount` 2). Anything else is skipped with one log line, not mixed wrongly.
- The 150 ms mixer hold-back, 10 ms tolerance and unity gain are first guesses.
- Not done: the Participants rail's Record row has no pause row (the pill, the window toolbar, the menu bar, the shortcut and the puck menu all do); no audio-only stream for system sound when nothing is shared; no setting for the border; Esc during a countdown from another app needs Accessibility (the Cancel button and the Record shortcut work without).
