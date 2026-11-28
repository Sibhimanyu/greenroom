# App/Recording

Everything that turns the Stage's composited picture into files on disk, plus the on-disk shape of a "session folder". The recorder (`SessionRecorder`) is a `StageFrameSink`: the Stage (`App/Stage/StageCompositor`) pushes BGRA frames into it, it encodes them with one `AVAssetWriter` (`StageEncoder`) into a fragmented H.264/AAC `.mp4`, mixes microphone + Mac sound into one AAC track (`AudioMixer`), and handles pause without gaps (`PauseClock`). A second writer feeds an in-memory ring of HLS-style segments (`ClipRing`) for "clip the last N minutes" when nothing is recording. The folder also holds the small pure types for clips, metadata, folder naming/space, thumbnails, summaries, the on-screen drawing tool and the whiteboard page. No outside program (no OBS) is involved since 1.3.0.

## Files

| Path | Owns | Key types / functions |
|---|---|---|
| `App/Recording/SessionRecorder.swift` | The recorder: start/stop/pause, clip-buffer arm/save, audio routing, frame hand-off, disk watchdog | `SessionRecorder` (`start(in:)`, `stop()`, `pause()`/`resume()`, `armClipBuffer`, `disarmClipBuffer`, `saveClipBuffer`, `stageDidRender`, `appendSystemAudio`, `elapsedMilliseconds`, `onRecordingStarted/Ended`, `onUnexpectedStop`, `clipBufferFolder`) |
| `App/Recording/StageEncoderRules.swift` | Pure encoder numbers: 3.5 Mbps average at 1080p (scaled by pixels, 1 Mbps floor, 4x cap), 6 Mbps peak cap (`DataRateLimits`, bytes per 1 s), AAC 128 kbps, 2 s keyframes and 2 s fragments | `StageEncoderRules` (`averageBitrate`, `peakBitrate`, `dataRateLimit`), `StageEncoderRulesTests` |
| `App/Recording/StageEncoder.swift` | One `AVAssetWriter`, two shapes (`.file` fragmented MP4; `.segments` in-memory HLS) | `StageEncoder` (`appendVideo`, `appendAudio`, `finish`, `cancel`), `StageEncoder.videoBitrate(for:)`, `RecorderError` |
| `App/Recording/PauseClock.swift` | Pause arithmetic: drop samples while paused, shift later ones back by total paused time | `PauseClock` (`pause/resume(at:)`, `offset(at:)`, `pausedSeconds`, `fileTime(of:firstFrame:)`), `PauseClock.retimed(_:by:)`, `.shifted(_:by:)` |
| `App/Recording/AudioMixer.swift` | Mixes mic + system sound onto a 48 kHz grid by host-clock timestamp; emits 10 ms chunks | `AudioMixer` (`add(_:at:from:)`, `flush()`, `onChunk`), `AudioMixer.floats(from:)`, `.sampleBuffer(samples:at:)` |
| `App/Recording/OwnAudioProbe.swift`, `AudioLevelMath.swift` | DEBUG-only probes B and C: audio-only SCStream of Greenroom's own process, plus a list of WebKit/Zoom helper processes; logs "Audio probe:" lines only. `AudioLevelMath` (pure, tested) holds `AudioLevelMeter` (peak/RMS dBFS) and `AudioProbeSwitch` | `OwnAudioProbe`, `AudioLevelMeter` |
| `App/Recording/MicrophoneTap.swift` | `AVCaptureSession` reader of the chosen mic (CoreAudio uid), 48 kHz stereo float out | `MicrophoneTap` (`start(uid:completion:)`, `stop()`, `isAuthorized`, `onSamples`, `StartResult`) |
| `App/Recording/ClipRing.swift` | In-memory ring of encoded segments (default 300 s); writes the newest N seconds to an .mp4 | `ClipRing` (`AVAssetWriterDelegate`; `write(lastSeconds:to:)`, `bufferedSeconds`, `reset()`) |
| `App/Recording/SessionClips.swift` | Clip marks as bookmarks + JSON sidecars | `SessionClip`, `SessionClipStore` (`appendPending`, `loadPending`, `adoptPending(in:as:)`, `load/save(for:)`, `sidecarURL`) |
| `App/Recording/SessionClipExporter.swift` | Passthrough cut of a marked range from a finished recording | `SessionClipExporter` (`export`, `exportTail`, `exportAll`, `isClip`, `clipPrefix` = `"Clip "`, `exportURL(for:from:)`, `isExported`) |
| `App/Recording/InputEventTracker.swift` | Global click/keystroke monitors during a screen-share recording; writes `<video>.events.json` | `InputEventTracker` (`start(elapsed:locate:)`, `stopAndSave(nextTo:)`) |
| `App/Recording/SessionFolders.swift` | Where recordings live, folder naming, free/used space, space levels | `SessionFolders` (`recordingsDirectory`, `sessionFolderName`, `uniqueSessionFolder`, `sanitizedClassName`, `recordingsFreeBytes`, `recordingsUsedBytes`, `spaceLevel`, `clipBufferSeconds`) |
| `App/Recording/SessionFolderRules.swift` | Pure "did this session leave anything?" rule (Foundation only) | `SessionFolderRules.isEffectivelyEmpty`, `.isNonEmptyFile` |
| `App/Recording/SessionMetadata.swift` | `session.json` per folder: title, kind, YouTube uploads, Cues links | `SessionMetadata` (`load(in:)`, `save(in:)`, `recordUpload`, `updateUploadTitle`, `forgetUpload`, `recordLink`, `rename(folder:to:)`, `Kind` = screen/green/recording) |
| `App/Recording/SessionSummary.swift` | Transcript reader + on-device (FoundationModels) meeting summary cached as `summary.md` | `SessionSummary` (`lines(in:)`, `hasTranscript`, `cached(in:)`, `generate(for:progress:)`, `chunk`, `tidy`) |
| `App/Recording/SessionThumbnails.swift` | Poster frame (10% in) + duration per recording; memory + JPEG cache in `~/Library/Caches` | `SessionThumbnails.shared` (`image(for:)`, `duration(for:)`) |
| `App/Recording/ScreenAnnotation.swift` | Drawing model, hit-testing/erasing, painter, marks-to-image renderer, global-to-canvas projection | `ScreenAnnotationModel` (Tool: pointer/pen/highlighter/arrow/eraser; `Mark`), `erasePolyline`, `AnnotationPainter`, `AnnotationMarksRenderer.image`, `StageMarksOverlay`, `MarkProjection.canvasPoint` |
| `App/Recording/ScreenAnnotationController.swift` | The AppKit windows for drawing over the real screen: canvas panel, toolbar panel, hover chrome | `ScreenAnnotationController` (`begin(on:followsWindow:)`, `suspend()`, `end()`, `onOverlay`, `onClose`, `onWhiteboard`, `capturedFrame`), `AnnotationCanvasPanel`, `AnnotationCanvasView`, `AnnotationChromeView` |
| `App/Recording/CameraWhiteboard.swift` | Stroke model + page renderer for the "whiteboard" share target | `CameraWhiteboardModel` (`begin/extend/finish`, `erase`, `undo`, `renderPage(width:)`, `aspect`, `colors`), `WhiteboardOpenRules` (pure: what the tools' Whiteboard button does, and that only a presented whiteboard feeds the Stage; `Tests/WhiteboardOpenRulesTests.swift`) |

Neighbours that belong with this area: `App/UI/RecordingsView.swift` (Sessions window; lists folders), `App/UI/AnnotationToolbar.swift` + `App/UI/WhiteboardViews.swift` (drawing UI), `App/UI/RecordingChrome.swift` (REC bar), `App/RecordStartFlow.swift`.

## How it fits

Entry points (all in `App/CoordinatorController.swift`, the single owner):
- `buildScene()` creates `SessionRecorder(source: stage, microphoneUID: micDeviceUID, log:)`, sets `onUnexpectedStop`, `recordsSystemAudio`, `stage.onSystemAudio` -> `recorder.appendSystemAudio`, then `wireInputEvents(recorder, stage:)` (only when `shareTarget.kind.capturesScreen`).
- `beginRecording()` checks `SessionFolders.recordingsFreeBytes`/`spaceLevel` (warns, never refuses), then `recorder.start(in: sessionFolder)`. `stopRecordingSession()` / `finishTake()` call `recorder.stop()`, then `adoptPendingClips(recordedAt:)` and `recordingFinished(path:)`.
- Session folder is named at session start: `SessionFolders.uniqueSessionFolder(named: sessionFolderName(className:started:), in: recordingsDirectory)` (~line 1570 for meetings, `beginTakeOrThrow` ~2706 for Record mode, fallback "Recording"; meeting fallback "Green"). `pointOutputsAtSessionFolder()` creates it and sets `recorder.clipBufferFolder`. `discardEmptySessionFolder()` removes it when `SessionFolderRules.isEffectivelyEmpty`.
- Clip shortcuts: `markClip(minutes:)`. While recording it appends a `SessionClip` to `pending-clips.json` (bookmark only, no video work). When not recording, `clipFromBuffer` -> `recorder.saveClipBuffer` (writes `Replay <stamp>.mp4`) -> `SessionClipExporter.exportTail` (writes `Clip ...mp4`). The buffer is armed with `recorder.armClipBuffer(seconds: SessionFolders.clipBufferSeconds)` (~line 2040).
- Drawing: `coordinator.drawing` (`ScreenAnnotationController`) and `coordinator.whiteboardModel`. `drawing.onOverlay` -> `stage.setMarksOverlay`; whiteboard page -> `stage.setWhiteboardPage(whiteboardModel.renderPage(...))` (lines ~2144-2276).
- Readers of the files: `App/UI/RecordingsView.swift` (`SessionClipStore.load`, `SessionClipExporter.*`, `SessionFolders.*`, `SessionThumbnails.shared`), `App/UI/SessionsIndex.swift`, `App/Screenroom/ScreenroomLibrary.swift` (scan + `clipPrefix`), `App/Editor/EditorConfig.swift` and `App/Editor/RecordingEvents.swift` (events sidecar), `App/UI/SessionTranscriptView.swift` (`SessionSummary.generate`), `App/YouTube/CoordinatorController+YouTube.swift` and `App/Cues/CoordinatorController+Cues.swift` (`SessionMetadata.recordUpload/recordLink`).

Capture pipeline:
`StageCompositor` (render queue) -> `SessionRecorder.stageDidRender` (lock, `pendingFrames` counter, max 2 queued else drop) -> private serial queue `greenroom.recorder.writer` -> `handle(_:at:)` -> `PauseClock.offset` shifts the timestamp -> `StageEncoder.appendVideo`.
Audio: `MicrophoneTap` buffers (+ `stage.onSystemAudio` buffers) -> `AudioMixer` (only when `recordsSystemAudio`; otherwise mic goes straight to `route(audio:)`) -> `route(audio:)` retimes per writer clock -> `appendAudio` on recording and buffer encoders.

On disk (root is `~/Documents/Greenroom`, `SessionFolders.recordingsDirectory`):
```
<Name> - yyyy-MM-dd HH-mm/          one folder per session (hyphens, no colons)
  yyyy-MM-dd HH-mm-ss.mp4           the recording (SessionRecorder.fileName); "(2)" on clash
  <recording>.clips.json            marks (SessionClipStore.sidecarURL)
  pending-clips.json                marks written live, adopted at stop
  <recording>.events.json           clicks/keys (RecordingEvents.sidecarURL)
  Clip <stamp>.mp4                  exported clips, beside the recording (no clips/ subfolder)
  Replay <stamp>.mp4                raw buffer dump, trimmed into a Clip
  session.json                      SessionMetadata
  transcript.txt cues.txt           written by Cues ("stamp<TAB>text")
  analysis-transcript.txt           written by Analyse ("[m:ss] text"); see screenroom.md
  summary.md ...                    other Cues/Screenroom files
```
Edited exports go to a NEW sibling folder `<name> – Edited` (see `editor.md`). Thumbnail JPEG cache: `~/Library/Caches` keyed by path+size+mtime.

Threading: `SessionRecorder` flags read by the render queue sit behind `lock` (`NSLock`); everything else lives on `queue`. `InputEventTracker`, `ScreenAnnotationController`, `ScreenAnnotationModel`, `SessionThumbnails` are `@MainActor`. `onRecordingStarted/Ended` are delivered on main.

## To change X, go to Y

- Bitrate, peak cap, keyframe/fragment seconds, AAC rate: `StageEncoderRules` (tested); profile and the rest: `StageEncoder.init`. Keyframe and fragment intervals must stay equal (crash safety). Crash check: a swiftc harness over `SessionRecorder` + synthetic frames, `kill -9` at 20 s, recovered 18 s (2 s fragment lost).
- Recording file name or collision suffix: `SessionRecorder.fileName(for:prefix:)` and `start(in:)`.
- Folder naming, stamp format, name sanitising (60 chars, `/ : \`): `SessionFolders.sessionFolderName`, `sanitizedClassName`, `sessionStampFormatter`; uniqueness `uniqueSessionFolder`.
- Disk-space thresholds (4 GB critical / 12 GB low) and the mid-record 200 MB auto-stop: `SessionFolders.SpaceLevel`, `SessionRecorder.minimumFreeBytes`.
- Which leftovers keep/delete an empty session folder: `SessionFolderRules.isDisposable` (and `SessionFolderRulesTests`).
- Pause/resume behaviour or timeline maths: `PauseClock`, `SessionRecorder.pause/resume`, `fileSeconds(first:)`.
- Mic device handling or permission messages: `MicrophoneTap.start`, `SessionRecorder.syncPlumbing`.
- System-sound mixing (jitter threshold, 150 ms hold-back, chunk size): `AudioMixer.add/flush`.
- Clip-buffer length or segment interval: `SessionFolders.clipBufferSeconds`, `SessionRecorder.segmentInterval`, `ClipRing.init`.
- Clip mark format, sidecar names: `SessionClip`, `SessionClipStore`; the hotkey logic is `CoordinatorController.markClip(minutes:)`.
- Clip cut behaviour (passthrough, keyframe lead-in, naming): `SessionClipExporter.export/exportTail`, `clipFileName`.
- Click/key capture for the editor (what is recorded, Accessibility gating): `InputEventTracker.recordClick/recordKey`; wiring in `CoordinatorController.wireInputEvents`.
- Session title, YouTube upload records, Cues links, `kind` marker: `SessionMetadata`.
- Meeting summary prompt, chunking, minimum words, cache file: `SessionSummary` (`generate`, `chunk`, `minimumWords`, `summaryURL`).
- Sessions grid poster frame and duration cache: `SessionThumbnails.make`.
- Drawing tools, colours, hit-testing, erase: `ScreenAnnotationModel`, `Mark.hits`, `erasePolyline`; how marks are drawn: `AnnotationPainter.draw`; how they reach the shared picture: `AnnotationMarksRenderer.image`, `MarkProjection.canvasPoint`.
- Drawing windows, toolbar placement, window-follow polling, Esc/shortcut keys: `ScreenAnnotationController`, `AnnotationCanvasView`.
- Whiteboard strokes/page: `CameraWhiteboardModel` (UI in `App/UI/WhiteboardViews.swift`).

## Gotchas

- Never block the render queue. `stageDidRender` only locks, counts and dispatches; do not add encoder or disk work there. Dropped frames are counted (`droppedBusy`) and logged in plain words at stop.
- Pause never stops the writer. Samples are dropped while paused and later ones shifted by total paused time, so the file has no gap. The recording and the clip buffer each have their own `PauseClock` (`recordingClock`, `bufferClock`); the buffer outlives recordings.
- `elapsedMilliseconds` is the position clip marks and input events are taken against: host clock minus pauses minus the first frame's time. It is nil before the first frame is written and while recording is off. `InputEventTracker` also gets nil while paused and drops the event.
- Fragmented MP4 (`movieFragmentInterval` 2 s) is what makes a crash lose only the last fragment. No B-frames and a keyframe every 2 s are deliberate: passthrough clip cuts then never need a later frame and land at most one keyframe early.
- The clip buffer lives in memory on purpose (a teacher who chose not to record ends with nothing on disk); about 230 MB for 5 min. `disarmClipBuffer` cancels the segmented writer off the queue because cancelling can block a MediaToolbox thread for a minute.
- Frame size must equal `source.outputSize`; mismatched frames are skipped (`sizeMismatches`).
- `stop()` returns nil and deletes the file when no frame was written. `onRecordingEnded` always fires (with nil if nothing kept); the events sidecar is only saved next to a non-empty video (`SessionFolderRules.isNonEmptyFile`).
- Marks are first appended to `pending-clips.json` (atomic write, read-modify-write) because the recording filename is unknown until stop; `adoptPending` merges by id and deletes the pending file only after a successful save.
- Clips sit beside the recording and are told apart by the `Clip ` filename prefix. `ScreenroomLibrary.recording(in:)` and `RecordingsView` rely on `SessionClipExporter.isClip` / `clipPrefix`; changing the prefix breaks both.
- `SessionMetadata.kind` is written only by Record mode (`.recording`) and Screenroom; class folders are told by absence. A kind-only `session.json` still counts as empty. Folder is never renamed on disk; the title is display only.
- `SessionRecorder` ("compiles with StageFrames.swift alone") must not take app-only dependencies.
- Test target compiles files directly (see `project.yml`, GreenroomTests sources): `PauseClock.swift`, `AudioMixer.swift`, `ScreenAnnotation.swift`, `CameraWhiteboard.swift`, `SessionFolderRules.swift`. They must stay free of app types. Pinned by `Tests/PauseClockTests.swift`, `Tests/ScreenAnnotationTests.swift` (mark projection, edit rules), `Tests/SessionFolderRulesTests.swift`. Adding a new pure file that a test needs means adding its path to `project.yml`.
- Mac sound must arrive as 48 kHz float; otherwise it is logged once and left out (`mixerLogged`).
- Two whiteboards, kept apart: PRESENTING (share target, Home Screen panel; `whiteboardWindow`, pushes the page to the Stage) and OPENING from the drawing tools / W (`whiteboardFromTools`, `localWhiteboardWindow`, `WhiteboardWindowController(mode: .local)`): an ordinary white window with the Show-on-my-share eye (ON at every opening: `ShareableWindow.localWhiteboard.startsShown`, the one Greenroom window that starts visible to everyone; the owner can turn it off while open; `RecorderVisibility` never tracks it), share target and Stage untouched, screen canvas suspended while it is open and restored on close.
- Annotation and whiteboard windows are Greenroom windows, so display share excludes them; what reaches the picture is the second copy drawn by `AnnotationMarksRenderer` into the Stage. Do not draw into the capture by other means.
- Summaries need macOS 26 (`@available(macOS 26.0, *)`, `FoundationModels`); on-device only by design (never send a class's transcript off-device).
- Screen Recording and Microphone permission failures degrade to logged messages (no sound / blank picture), not thrown errors.
