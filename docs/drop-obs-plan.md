# Dropping OBS

Written 2026-11-10. Status: plan only, nothing built. Step 0 decides whether
the rest happens.

## What it is

Greenroom builds the class picture (your screen with your webcam in it)
itself, hands the frames straight to the Zoom SDK it already runs, and
records them itself. OBS stops being needed: there is nothing to install,
no WebSocket, and no hidden second app.

## Why

The virtual camera is a detour. Zoom runs inside Greenroom, so today the
picture leaves Greenroom (as Syphon cutouts), is put together in OBS,
published as a system camera, and read back into Greenroom by the SDK.
What that costs:

- **Install and onboarding.** Someone has to get OBS, and Onboarding has to
  explain the "OBS Virtual Camera" pick (`OnboardingView.swift:393`).
- **Fragility.** One property-list call crashes OBS 32.2.2. The clip buffer
  needs an OBS restart if OBS was already running (`CoordinatorController.swift:1792`).
  Source and filter names differ between OBS versions, so `GreenroomScene`
  has to ask OBS which kinds exist.
- **Start time.** OBS has to launch, connect and build the scene before the
  meeting can show a picture.
- **Two apps to support,** and OBS's own updates can break Greenroom.

## What OBS does today

| Job | Where in Greenroom |
|---|---|
| Screen capture: a whole display, one app, one window, or nothing | `GreenroomScene`, `ShareTarget`, `LocalDeviceResolver` |
| One camera source per camera, all open at once | `GreenroomScene.ensureCameraInputs` |
| Webcam shapes (square, circle, rounded) as alpha masks | `WebcamShape`, `MaskImageGenerator`, OBS `mask_filter_v2` |
| Cutout and Presenter looks (camera with the background removed, arriving over Syphon) | `CutoutPublisher` → OBS `syphon-input` |
| Positioning, layering and crossfading between cameras | `GreenroomScene` transforms, `Greenroom Fade` filter |
| The virtual camera the SDK reads | `StartVirtualCam` |
| Recording, written as fragmented MP4 into the session folder, with the mic | `StartRecord`, `pointRecordingAt`, the mic input |
| The 5-minute replay buffer behind the clip shortcuts (⌥⌘1/2/5) | `configureReplayBuffer`, `StartReplayBuffer` |
| Camera frames for camera switching | `CameraDirector` → `GetSourceScreenshot` |
| Record mode (recording with no meeting) | `recordOnlyActive` path |
| A standby scene, and process supervision | `OBSProcessManager`, "Greenroom Standby" |

About 3,500 lines are OBS glue: `GreenroomScene` (1.8k), `OBSProcessManager`,
`OBSWebSocketClient`, and the OBS parts of `CoordinatorController` and
`CameraDirector`.

## What already exists to build on

- **Screen capture:** `ScreenroomScreenEngine` already uses ScreenCaptureKit.
  `SCContentFilter` takes a display, an app or a window, which is exactly
  what `ShareTarget` describes.
- **Camera capture without OBS:** `CameraProbe` (Settings, when idle) and
  `ScreenroomCameraEngine`.
- **Background removal:** `CutoutPublisher` already makes the cutout frames.
  Only the Syphon hand-off to OBS goes away.
- **Mask shapes:** `MaskImageGenerator` already draws them.
- **Recording:** `ScreenroomRecorder` / `ScreenroomVideoExport` already use
  AVFoundation.
- **Sending video into Zoom:** the bundled SDK has
  `ZoomSDKRawDataVideoSourceController.setExternalVideoSource(_:videoDataFormat:)`,
  which takes a `ZoomSDKVirtualVideoSourceDelegate` that pushes frames.
  `ZoomSDKRawDataController.hasRawDataLicense` says whether we may use it.

## The pieces

### 0. The gate: may we send raw video, and how good is it? (small, decides everything)

1. After the SDK authenticates, log the result of `hasRawDataLicense`.
2. Spike: send a moving test pattern through `setExternalVideoSource` into
   a test meeting, and look at it from a second device.
3. Measure the resolution and frame rate the SDK offers in `onInitialize`
   (its `supportCapabilityArray` and `suggestCapability`), and what the
   other side actually sees, compared with today's virtual-camera path.

**Go** if the licence is there and the quality matches today's path.
**No go** if there's no licence: ask Zoom to enable raw data for the SDK
app. Until they do, stop here. Pieces 3, 5 and 6 (compositor, recording,
camera switching) would still remove OBS from Record mode, and could ship
on their own if that's wanted.

### 1. The compositor (large, the core)

This is one object that owns the picture: `StageCompositor`, in a new
`App/Stage/` folder.

- Inputs: one ScreenCaptureKit stream (built from `ShareTarget`), N
  `AVCaptureSession` cameras, and the cutout frames from `CutoutPublisher`
  (called directly, not over Syphon).
- It draws with Core Image on a Metal context, once per output frame at a
  fixed 30 fps clock: background, then the live camera masked to its shape
  at its position, then any crossfade between two cameras.
- Output: an NV12 or I420 `CVPixelBuffer`, in whichever format the SDK asks
  for in piece 0. It gets handed to anyone who subscribes (Zoom, the
  recorder, the Settings preview).
- Layout is read from the same settings `GreenroomScene` reads today, so
  the Layout and Webcam pages don't change.
- "Nothing" as the share target and "No camera" (just added on this branch)
  have to work from day one.

### 2. Into the meeting (small once 0 and 1 exist)

`ZoomVideoSender` implements `ZoomSDKVirtualVideoSourceDelegate` and pushes
compositor frames while the SDK says it is sending. The meeting then no
longer picks a camera device at all. Remove the "OBS Virtual Camera" pick
and its onboarding copy.

### 3. Recording and clips (medium)

- `SessionRecorder`: AVAssetWriter with hardware H.264/HEVC, taking
  compositor frames plus the chosen microphone. It writes into the same
  session folder with the same file name pattern, so `RecordingsView`,
  `SessionThumbnails` and YouTube upload don't change.
- Crash safety: OBS writes fragmented MP4 so a crash still leaves a usable
  file. Use `movieFragmentInterval`, or segmented output, to get the same.
- Clip buffer: keep the last 5 minutes as rolling segments
  (`preferredOutputSegmentInterval`) while not recording. `SessionClips`
  keeps its "bookmark, cut later" model. Only where the bytes come from
  changes.
- The OBS restart workaround for the replay buffer goes away.

### 4. Record mode (small)

The same compositor and recorder, with no meeting attached.

### 5. Camera switching (small to medium)

`CameraDirector` reads frames from the compositor's own camera sessions
instead of `GetSourceScreenshot`. That's the same thing `CameraProbe`
already does when idle. The setup path and the class path stop being
different, and the comment in `CameraProbe.swift` needs rewriting.

### 6. Preview (small)

`WebcamShapePreview` and the Layout page can show the real compositor
output instead of an approximation.

### 7. Remove OBS (medium, mostly deleting things and rewriting copy)

- Delete `OBSProcessManager`, `OBSWebSocketClient`, `GreenroomScene`,
  `LocalDeviceResolver` (if ScreenCaptureKit makes it redundant), the Syphon
  loader in `CutoutPublisher`, and the OBS settings (including the switch
  that quits OBS at End Session).
- Rename `App/OBS/` to `App/Stage/`.
- Onboarding: drop the OBS install and connection steps.
- `docs/how-it-works.html`: the system map, the Start sequence diagram, the
  Screen Recording permission row ("OBS does the class capture"), the
  `ws:4455` paragraph and the "does not capture your screen" chip. All of
  these become false. Update them in the same commit as the code, as
  `ScreenroomScreenEngine.swift` says.
- README, site copy, and the guide.

## Order of work

1. Piece 0, the gate. Opus reads the result and decides go or no go.
2. Piece 1, the compositor, with a hidden debug-only engine switch
   (`#if DEBUG`, see the debug-UI rule) so the OBS and native paths can be
   compared on the same Mac.
3. Pieces 2 and 3 in parallel (separate worktrees).
4. Pieces 4, 5 and 6 in parallel.
5. A class-length soak test: 60 minutes, two cameras, cutout on. Compare
   CPU, temperature, dropped frames and file size against OBS.
6. Piece 7, then a release.

Who does what: Opus writes each piece's brief and reviews its diff. Sonnet
5.5 agents write the code.

## Risks

- **The licence (piece 0).** If Zoom won't enable raw data, the meeting
  half of this can't happen.
- **SDK resolution cap.** If the external source tops out lower than the
  virtual camera, the class picture gets worse. Piece 0 measures this.
- **Load.** Compositing at 1080p30, background removal and encoding all
  move into Greenroom's process. OBS was doing the same work, so the total
  should be similar, but a crash now takes the meeting down with it.
  Piece 1 must stay off the main thread.
- **Permission prompt.** Greenroom now asks for Screen Recording for the
  class itself, not only for Screenroom. Onboarding has to ask for it, and
  the privacy page has to say so plainly.
- **Other apps lose the virtual camera.** Anyone using the "OBS Virtual
  Camera" in Meet or Teams would lose it. A CoreMediaIO camera extension
  could bring it back later, but it needs a system extension and Developer
  ID signing, the same signing gap that broke the install on a new Mac.
  Not part of this plan.
- **Power users lose OBS's knobs.** Accepted. Greenroom's settings are the
  product.

## Questions to answer, not blocking piece 0

- Keep OBS as a hidden fallback for a release or two, or cut it cleanly?
  Recommendation: cut cleanly once the soak test passes. Two engines double
  the bug surface.
- HEVC or H.264 for recordings? H.264 is the safer choice for YouTube upload
  and passthrough clip cuts.

## Definition of done (first release)

- A fresh Mac with no OBS installed can run a class, Record mode and clips
  end to end.
- The meeting picture is at least as sharp and smooth as today's.
- Camera switching cuts at least as fast as today.
- No OBS strings are left in the release binary (check with `strings`),
  and how-it-works describes what the app really does.
