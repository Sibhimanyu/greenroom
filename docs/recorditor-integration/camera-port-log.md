# Phase 3: camera backgrounds and camera recovery

Upstream: ZRecorditor @7210322, `native/MacRecorder/Recording/CameraCapture.swift`, `Backgrounds/*.jpg`.
Built (Debug, zero errors) 2026-11-13. **Not tried with a real camera.**

## What was copied

| Upstream | Greenroom | How |
|---|---|---|
| `CameraBackground`, `CameraEffects.apply` | `App/Stage/CameraEffects.swift` | copied, changed (below) |
| `keepDominantRegion`, `smoothedMask`, `ComponentScratch` | same file, class `MaskRefiner` | copied; moved out of the capture class so each camera owns one |
| `resolveDevice`, `applyPreferredDevice`, `replaceVideoInputs`, `recover`, the three notifications, the 5 s probe | `App/Stage/CutoutPublisher.swift` ("Camera recovery") | copied, adapted to one-device-per-publisher |
| `Backgrounds/bg-1-studio.jpg` ... `bg-5-slate.jpg` | `App/Stage/Backgrounds/` | byte copies; xcodegen puts them in `Resources/` |

Not taken: `CameraCapture` itself (its own session, preview model, audio output, `CameraStatus` "waiting" view, `ProcessedCameraPreview`), `.cutout` mode of `CameraBackground`. Greenroom already has a camera session (`CutoutPublisher`) and its own Cutout.

New (not upstream): `CameraBackgroundPreset`, `CameraBackgroundLibrary` (loading, caching, the user's own picture), `CameraBackgroundControl` UI.

## Changes against upstream

1. `CameraBackground` has Normal / Blur / Image only (no `.cutout`).
2. No mask (Vision failed on a frame) used to return the raw frame. Now the whole frame counts as background, so a blurred or imaged picture never leaks the room for a frame.
3. Image mode with no picture loaded falls back to blur instead of raw.
4. Blur is computed at a quarter size and scaled up (same sigma ratio): about 1/16 of the pixels of upstream's full-size sigma = width/50 blur.
5. Vision warm-up: upstream runs segmentation on the first camera frame even in Normal. Here segmentation never runs while the look is a plain bubble set to Normal; instead `CameraEffects.warmUp()` loads the model once on a utility queue the first time Blur/Image is applied, so the camera queue does not freeze.
6. The mask smoothing `CIContext` is one shared static, not one per camera.
7. Custom picture: copied to `~/Library/Application Support/Greenroom/CameraBackground/custom.<ext>` and downscaled to 1920 px wide on load. Key `custom-<unix time>` changes per choice so the compositor reloads.
8. Recovery: upstream has a "System default" choice and `preferredDeviceID`; here the chosen camera is the publisher's `uid`. Upstream's repeating 1 s watchdog is a single `asyncAfter(5 s)` per probe. The "waiting" spinner status is not ported; the existing `camerasLive` (no frame for 2 s) covers it.
9. Upstream's `preferredDeviceName`: replaced by `LocalDeviceResolver.cameraName(uid:)`.

## Greenroom seams (file:line at time of writing)

- `App/Stage/CutoutPublisher.swift`: `Frame.background`; `setBackground`, `onStandIn`, `setAllowsStandIn`; `init` (device attach moved into `applyPreferredDevice`); recovery block from "Camera recovery (controlQueue)"; `process` (one segmentation call serves cutout OR background); `autoreleasepool` in `captureOutput`.
- `App/Stage/StageRenderer.swift:27` `StageCameraInput.background`; `:153` `pixels(of:)` returns `background ?? raw` for non-chroma shapes. Cutout/Presenter path is untouched.
- `App/Stage/StageLayout.swift`: `StageConfiguration.cameraBackground`, `cameraBackgroundImage`.
- `App/Stage/StageCompositor.swift:278` (effective background is Normal for Cutout/Presenter), `:309` / `syncCameras` (loads picture, warms Vision, sets effect and `allowsStandIn = uids.count == 1`), `:394` wires `onStandIn` for slot 0 into `StageStatus.cameraStandIn` (`:45`).
- `App/CoordinatorController.swift:649-680` published `cameraBackground`, `cameraBackgroundImage`, `chooseCameraBackgroundImage()` (NSOpenPanel); `:1057` load; `:1203` into `makeStageConfiguration`; `:1222` logs stand-in / "back".
- `App/UI/WebcamPage.swift`: `WebcamSettingsTab` bindings (shape binding is now `animatedCollapse()`), `WebcamPageContent` new params, `CameraBackgroundControl` / `BackgroundImageRow` / `BackgroundThumb`.
- `App/Stage/CameraProbe.swift:60` `watchDevices()` (see below).
- UserDefaults keys: `cameraBackground`, `cameraBackgroundImage`.

## UI

Settings -> Webcam -> Picture, under the look tiles: a segmented "Background" (Normal / Blur / Image), same control as the neighbouring Cutout "Background" picker. Image reveals a row of the five presets plus "Choose..." (and the user's own, outlined, once chosen). Both the whole control (hidden for Cutout, Presenter, and No camera) and the picture row are `Collapsible`, animated per the app rule. Tiles use `ChoiceTile`'s outline (10 pt radius, `Brand.green` 2 pt when selected). Not changed: the Record view's own look picker has no background control yet.

## Camera unplug recovery and CameraDirector

- **One camera held** (the normal case; also the first seconds of any session): the publisher falls back to `AVCaptureDevice.systemPreferredCamera ?? default`, else any connected camera, when the camera disappears (wasDisconnected, or session runtime error). The slot keeps its uid, so the board, compositor and director see an uninterrupted slot 0. When the chosen camera returns it is attached at once and has 5 s to deliver a frame; if none, the stand-in returns and the camera is skipped until it reconnects. Each switch is logged ("Using X until Y is back.").
- **Two or more cameras held** (CameraDirector on): `syncCameras` sets `allowsStandIn = false`. A publisher then never substitutes another camera; the director's own rules (stale frame, `unplugged`, dwell) own which camera is live. A publisher still re-attaches its own camera when it comes back, which the director's log already promised but nothing did. If the director is switched on or off live, `syncCameras` flips the flag on existing publishers.
- **CameraProbe** (aiming, idle only) never stands in. It now reports "<camera> was unplugged." and re-opens when that camera returns, so the angle readout does not keep a dead answer.

## Performance

- Vision runs only when removal or Blur/Image needs it; Normal bubbles cost nothing extra. One request per frame, shared by both uses.
- Refiner works on the low-res mask (raw buffers, no per-pixel arrays); mask smoothing is one small GPU render into a pooled buffer.
- The composite itself is a lazy Core Image graph, rendered once by the renderer's existing context. No new CIContext per frame, no new queue except the publisher's small control queue.
- With several cameras open, every camera segments (the director needs all of them live and a cut must not flash an unblurred room). Costly only with Blur/Image and the director on.
- Debug builds run the component pass slowly; measure in Release.

## Checked

- Debug build, zero errors; the five JPEGs are in the built app's `Resources`.
- `.context/wr/go.sh` (rewritten for current paths) renders the real Webcam page off screen. With `live`, the picture is a synthetic frame (room, poster, person, a second smaller person) through the real `CameraEffects.apply` and `MaskRefiner`: Blur softens the poster and the second person is erased from the mask; Image shows the preset behind the main person. PNGs: `scratchpad/phase3/{normal,blur,image-studio,cutout-hidden}.png`. The `image-sunset-dark.png` render is washed out by an off-screen dark-mode artifact of the harness, not the page.

## Untested / open

- No real camera, no real Vision output, no real unplug/replug, no Continuity Camera. All of recovery is ported logic, compiled, never run.
- Blur/Image edge quality on real people (hair), and the 65/35 smoothing lag on fast movement.
- The Choose... panel and the copy into Application Support.
- If the chosen camera is missing at start with stand-in allowed, the first stand-in message is not logged (handler is attached after init).
- Cutout still does not use the largest-region step (upstream does); left alone to not change shipped behaviour.
- Record view has no background control.
