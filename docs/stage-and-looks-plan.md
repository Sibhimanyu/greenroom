# Stage and Looks: choose how you show up

Status: **proposed 2026-11-05, nothing built.** Branch `rethink-presence`.

## What it is

Greenroom today makes one picture: the whole display, with the teacher in a
corner bubble (or keyed in front of it). That picture suits one person's
morning class. Everyone else shares something different and wants to appear
differently.

The rethink: a **Stage** where you arrange what the meeting sees, and
**Looks**, which are saved arrangements you switch between mid-call.

- **What you share:** a whole display, one window, one app, several windows,
  a region of the screen, or nothing.
- **How you appear:** a bubble, a cutout in front of the content, behind the
  content, side by side with it, or full frame.
- **Switching:** one hotkey per Look, with a cut or a crossfade.

The five shapes that exist now (Square, Circle, Rounded, Cutout, Presenter)
become the first built-in Looks. Nobody who uses Greenroom today loses
anything.

## Who it is for

Anyone who presents on a call from a Mac, not only teachers:

- someone demoing one app, who does not want Slack and their mail on screen;
- someone walking through two windows at once (code and the running app, a
  doc and a spreadsheet);
- a 1:1 or standup where there is nothing to share and they just want to be
  framed well;
- someone who wants to look more like a presenter than a webcam tile.

The class setup stays a first-class Look and the default for existing users.

## What already exists to build on

| Piece | Where |
|---|---|
| Scene built idempotently over OBS WebSocket | `App/OBS/GreenroomScene.swift` (`ensureConfigured`) |
| Live re-layout without stopping the virtual camera | `applyLiveLayout` |
| Bubble, cutout and presenter arrangements | `layoutScene`, `layoutCutout`, `layoutPresenter` |
| Shape masks | `App/OBS/MaskImageGenerator.swift`, `ensureShapeMask` |
| Chroma key | `setChromaKey` |
| Several sources with cuts and crossfades between them | `App/OBS/CameraDirector.swift`, `ensureFade` |
| Display picker | `App/Layout/DisplayResolver.swift` |
| Settings for shape, size and position | `App/UI/SettingsView.swift` |

## The pieces

### 1. Sharing one window or one app (small)

**Built 2026-11-05** (`App/OBS/ShareTarget.swift`, Settings → Layout →
Shared screen). Checked against OBS 32.2.2 over the WebSocket: a window
source (`type: 1`, `window`) and an app source (`type: 2`, `application`
plus `display_uuid`) both come up with real frames, and the window sits
fitted on the `--ink` backdrop. Not yet run through a full Greenroom
session.

OBS's macOS capture source already takes `type: 1` (a window, by window ID)
or `type: 2` (an app, by bundle ID). Greenroom always passes `type: 0` (a
display) at `GreenroomScene.swift:301`.

Needed:

- A picker listing windows and apps (ScreenCaptureKit's
  `SCShareableContent` has both, with titles and app icons).
- **A fixed canvas.** `fitCanvasToScreenSource` sizes the OBS canvas to the
  screen source. With a window that would make the meeting's picture the
  window's odd shape, and it would change size when the window is resized.
  For anything but a full display, fix the canvas at 1920x1080 and fit the
  window inside it.
- Window IDs do not survive a relaunch of the app. Store the app's bundle ID
  and window title, and match them again at session start.
- The window closes mid-call: show the Look's background, not a black frame,
  and say so in the status log.

### 2. Sharing several windows (medium)

One capture source per window, named "Greenroom Window 1", "2" and so on,
following the camera-slot naming in `cameraSourceName(slot:)`.

Arrangements to start with:

- **Side by side** (two windows, equal width).
- **Main and corner** (one large, one small).
- **Free**: dragged into place on the Stage.

Each window sits on a background (a solid colour or a soft gradient from
DESIGN.md tokens) with rounded corners and a shadow, so a group of windows
looks arranged rather than pasted together.

### 3. Where you sit relative to the content (medium, depends on 5)

- **In front:** today's Cutout and Presenter.
- **Behind:** the person fills the frame and the shared windows float over
  them as panels at around 85% opacity. A lightboard or weather-map feel. This
  is the most distinctive Look and nobody does it well today.
- **Side by side:** a split of person and content, for when the person is the
  subject.
- **Bubble:** today's shapes, plus border, shadow and mirror.

Front and behind are only layer order and opacity in OBS, which
`enforceLayerOrder` and the fade filter already handle. What makes them look
good is a clean cut-out of the person, which is piece 5.

### 4. Stage and Looks (medium to large, mostly UI)

- **The Stage:** a live preview of the composite in a Greenroom window, where
  you drag and resize the windows and yourself. Moves are scene-item
  transforms, which OBS accepts while the virtual camera runs
  (`applyLiveLayout` already relies on this).
- **A Look** is a saved record: its sources, each one's transform, the person
  style, the background and the transition. Stored as JSON in Application
  Support.
- **Switching Looks live:** a menu-bar menu, plus ⌃⌥1 to ⌃⌥9. Either one OBS
  scene per Look (OBS's own scene transitions) or one scene re-laid out (what
  `applyLiveLayout` does now). One scene per Look switches faster and avoids
  a half-moved frame. To decide while building piece 2.

Follow DESIGN.md for the Stage UI. It is a new visual surface, so check its
"Open drift to fix" list first.

### 5. Background removal without a green screen (the risk)

**Built 2026-11-06** as option 2: `App/OBS/CutoutPublisher.swift` opens each
camera in Greenroom, removes the background with Vision (`.balanced`) for
Cutout and Presenter, passes frames through for the bubble shapes, and
publishes over Syphon; the scene's camera sources become `syphon-input`
sources found by app and server name. Settings → Webcam → "Remove your
background": Automatically (default) or With a green screen. Syphon is
OBS's own build, vendored by `scripts/vendor-syphon.sh` (building it needs
the Metal toolchain). Not yet run in a real session.

Cutout, Presenter and every front or behind Look need a real green screen
today (`usesChromaKey`). Most people do not own one. Until this is solved, the
wider audience gets bubbles only.

Options, cheapest first:

1. **macOS's own camera effects.** macOS 15 added background replacement in
   Control Center's video effects, applied per app, so OBS's camera would
   receive it. *To check:* whether a solid colour that chroma-keys cleanly is
   offered. If it is, this costs almost nothing. The person has to turn it on
   themselves, and it is Apple silicon only.
2. **Vision person segmentation inside Greenroom.** Greenroom opens the
   camera, runs `VNGeneratePersonSegmentationRequest` (macOS 12 and later, on
   device), and hands OBS a cut-out with transparency. The hard part is the
   hand-off: through Syphon (OBS has a Syphon source on macOS; it would add a
   dependency), or as an OBS source written by Greenroom. Greenroom then owns
   the camera, which affects `CameraDirector`'s face tracking.
3. **The obs-backgroundremoval plugin.** Works, but it means installing a
   third-party OBS plugin, which adds setup for every new user.

Recommendation: spend a day testing 1, then 2, before building pieces 3
and 4 on top of either.

#### Spike result, 2026-11-05: option 2 works end to end

Tested on an M5 Pro with staged footage (a generated presenter on green,
keyed over two busy macOS wallpapers, so the true outline is known exactly).
Spike code is in `.context/seg-spike/` (not committed).

Vision segmentation alone, 720p, 250 frames per run:

| Quality | Mask size | Mean | p95 | Match to true outline (IoU) |
|---|---|---|---|---|
| fast | 256x192 | 5-7 ms | 13-17 ms | 0.94, jagged pink-fringed edges |
| **balanced** | 512x384 | **12 ms** | **19-22 ms** | **0.945, clean edges and hair** |
| accurate | 2016x1512 | 33 ms | 44 ms | 0.945, no visible gain |

**Balanced is the setting.** Accurate costs three times as much for nothing
visible.

The hand-off to OBS also works, with no green screen and nothing installed:

- OBS 32 ships `Syphon.framework` and a `syphon-input` source with an
  `allow_transparency` setting.
- The spike published the cut-out from a `SyphonMetalServer`. OBS listed
  it, showed it, and a `GetSourceScreenshot` of the source came back 70%
  fully transparent, with the person upright and clean-edged.
- Two things had to be right: Syphon announces servers over distributed
  notifications, so the publisher needs a running main run loop; and the
  texture is published with `flipped: false`.

Still open:

- **Per-frame cost while OBS reads it:** 14 ms, 26 ms and 36 ms mean over
  three runs (p95 up to 90 ms). The spike waits for the GPU on every frame
  and the Mac was busy with other work, so this is an upper bound. The real
  version must not block per frame. Measure on an older Mac (M1 Air) before
  calling it done.
- **Real webcams:** dim rooms, a chair behind the person and a busy
  bookshelf are harder than studio-lit footage. Test with a staged person on
  a real webcam.
- **Who owns the camera:** Greenroom would open the camera itself and
  `CameraDirector`'s face tracking would read from the same frames, rather
  than OBS opening it.
- **Linking Syphon:** the spike borrowed OBS's copy at runtime. The app
  should bundle its own Syphon (BSD licence).
- Option 1 (macOS's own background replacement) was not tested; it needs
  clicking in Control Center, and option 2 makes it unnecessary.

## Order of work

1. ~~Test background removal (piece 5).~~ Done 2026-11-05: Vision plus
   Syphon works; see the spike result.
2. ~~One window or app (piece 1), with the fixed canvas.~~ Built
   2026-11-05; needs a run through a real session.
3. Several windows (piece 2).
4. The Stage and Looks (piece 4), with today's shapes as built-in Looks.
5. Behind and side-by-side styles (piece 3).

## Bigger questions, not blocking

- **OBS has to be installed.** Every new user is sent to install OBS first.
  Greenroom could eventually composite and publish its own virtual camera
  (a Camera Extension) and drop OBS. That is a large job; noted, not planned.
- **The meeting part is Zoom-specific.** The virtual camera already works in
  Google Meet and Microsoft Teams. For new users the meeting setup could
  become optional, with "Greenroom Camera" as the product.
- **The cost of ScreenCaptureKit per window.** Several window captures plus
  a camera on an older Intel Mac has not been measured.

## Definition of done (first release)

- A Look can share one window, one app, or two windows side by side, at a
  fixed 1920x1080 canvas, without a black frame when a window closes.
- At least four built-in Looks (today's shapes), plus user-saved ones.
- Switching Looks mid-call by hotkey, with no virtual-camera restart.
- Today's class setup works exactly as before for existing users.
- Background removal: decided and either shipped or explicitly left for a
  later release.
