# Phase 5: drawing on the screen, the whiteboard, the Audio only card (drawing port log)

Built (Debug, zero errors; `GreenroomTests` 260 tests pass, 11 new) 2026-11-13. Nothing run by hand: no app launch, no meeting, no recording, no real drawing.

## The redesign, and why

Upstream (`ScreenRecorder`) records the screen with ScreenCaptureKit and **captures the drawing windows**: the capture filter excludes every Recorditor window except the canvas and whiteboard windows (`ScreenAnnotationController.windowNumbers`, `refreshCaptureFilter`), so the marks are in the file because they are on the screen. A window recording cannot take the canvas in, so upstream snapshots the canvas into each frame (`snapshot(of:scale:)`).

Greenroom cannot do that:

- Screen frames are composited by `StageCompositor`/`StageRenderer` into ONE Stage picture that feeds both the Zoom meeting and the recording. A mark that is only "on the real screen" would reach neither unless the filter lets our windows in, and the meeting must never see Greenroom's other windows.
- A display share excludes the whole Greenroom app (`StageScreenSource.start`), and an app or window share includes only the shared app's or window's own windows, so overlay windows are never captured.

So drawing is split in two:

1. **Over the real screen** (what the user sees and draws on): upstream's transparent canvas window, toolbar window and edit-handle window, all Greenroom windows, all out of capture, `sharingType = .none` as a belt.
2. **In the picture** (what the meeting and the file see): marks are kept in **global screen points** (CoreGraphics, top-left origin of the main display: the space of `SCDisplay.frame` and window bounds). When a mark changes, `AnnotationMarksRenderer.image(of:over:clip:)` draws them to a transparent image that covers the captured area (the display, or the followed window), at roughly Stage resolution. The image goes to `StageCompositor.setMarksOverlay`, and `StageRenderer.compose` fits it over the screen content with `stretch(marks, to: placed.rect)`, the very rect it just drew the screen into (and before the presenter panel mask, so a rounded panel cuts them too). Because the overlay has the screen's own shape, a mark lands where it was drawn for display, app and window shares, in every layout, with no geometry in the Stage. This is the same maths as `videoPosition(ofGlobalPoint:)` from phase 2 (written out, with tests, as `MarkProjection.canvasPoint`).

Cost per frame: one `CIImage` composite when marks exist, nothing when they do not. The overlay is re-rendered only when a mark changes, coalesced to 30 Hz, on the main thread (a 1920x1080 transparent bitmap, a few ms).

## Files and what changed vs upstream (@7210322)

| Greenroom file | Upstream | Change |
|---|---|---|
| `App/Recording/ScreenAnnotation.swift` | `ScreenAnnotation.swift`: `ScreenAnnotationModel`, `erasePolyline`, `Mark` geometry, the mark drawing in `AnnotationCanvasView.draw(_:)` | Model verbatim except: **marks are global points**, not canvas-view points; one surface only (no `.board`, no `whiteboard` flag: Greenroom's whiteboard is a share choice, see below); `drawableArea` is global; added `translateAll(by:)` (window follow), `inProgress` + `onMarksChanged` (the Stage's copy); `reset()` no longer touches a board. The drawing code is lifted into `AnnotationPainter.draw` so the canvas and the Stage's image draw identically. New: `StageMarksOverlay`, `AnnotationMarksRenderer`, `MarkProjection` (pure). In `GreenroomTests`. |
| `App/Recording/ScreenAnnotationController.swift` | `ScreenAnnotationController`, `AnnotationCanvasPanel`, `AnnotationCanvasView`, `AnnotationChromeView` | Removed: the board window and its fill/resize/header chrome, `windowNumbers`, `onWindowsChanged`, `snapshot(of:scale:)`, `snapshotting`, the capture-filter plumbing (all of it exists only to capture our windows). Added: `origin` on the canvas view (marks are global, the view converts); `begin(on:followsWindow:)`, `suspend()`, a 10 Hz poll of `capturedFrame()` that moves the canvas to a switched display, translates marks when a followed window moves, and keeps `drawableArea` equal to the window; `onOverlay`, `scheduleOverlay` (30 Hz coalesce); `onWhiteboard`. Dimming: upstream dimmed only outside a window share's window; here the whole screen dims lightly (10%) while a tool is picked, and a window share dims the rest 30% and leaves the window clear. Colours of the edit handles use `controlAccentColor`, not Recorditor's blue. Keys V/P/H/A/E, W, Cmd-Z, Esc are handled in the canvas view's `keyDown` only (it is the key window while a tool is picked); no global key monitor. The Pointer mode's mouse-moved monitors (to let a click through except over a mark) are upstream's and are global mouse, not key, monitors. |
| `App/UI/AnnotationToolbar.swift` | `AnnotationToolbarView`, `PressScaleStyle` (`RoomSessionView.swift:152`, verbatim) | Look: black capsule and `Theme` replaced by `.greenroomGlass(in: Capsule(), interactive: true)` (DESIGN.md, Glass) with semantic `.primary` symbols and `Brand.green` for the picked tool; the hint line is a glass capsule too. The Whiteboard button calls `onWhiteboard` (switches what is shared) instead of toggling a flag. "Done" is a system prominent button. |
| `App/Recording/CameraWhiteboard.swift` | `CameraWhiteboardModel` | Verbatim except: the camera inset constants removed (the Stage composites the camera over the page), `isOn` removed (sharing the whiteboard is `ShareTarget.Kind.whiteboard`). `renderPage(width:)` is what the Stage uses as the screen. In `GreenroomTests`. |
| `App/UI/WhiteboardViews.swift` | `CameraWhiteboardStage`, `CameraWhiteboardTools`, `CameraOrWhiteboard` | Stage view kept (draw, erase, hover chrome with delete, resize, move) without the camera preview and its inset. Tools on glass, floating at the foot of the page, with a "Back to screen" button. New `WhiteboardWindowView` and `WhiteboardWindowController` (a titled, resizable Greenroom window, 16:9 content ratio, `sharingType = .none`). `CameraOrWhiteboard` and `CameraWhiteboardToolsIfOn` dropped (no camera feed to swap). |
| `App/Stage/AudioOnlyCard.swift` | `appendStillFrame` "Audio only" card (`ScreenRecorder`) | New drawing code: `--ink` ground, mic glyph, "Audio only" in the system font, a `--faint` caption. Upstream's still-frame timer is not needed (see below). In `GreenroomTests`. |

## Greenroom seams (file:line)

- `App/Stage/ShareTarget.swift:27-52,89`: new `Kind.whiteboard` ("Whiteboard") and `Kind.capturesScreen` (display/app/window). `resolve` treats it like nothing captured.
- `App/Stage/StageCompositor.swift`:
  - `StageInputBoard.Screen` now holds a `CIImage` (made once when the frame arrives) so a captured frame and the whiteboard page are interchangeable (`:50-100`); `setWhiteboard(mode:)` / `setWhiteboardPage` (`:97-98`); the snapshot hands out the page as the screen while the share is the whiteboard (`:74`).
  - `setMarksOverlay`, `setWhiteboardPage` (`:182,189`), `followsWindow()` (`:204`).
  - `apply` sets whiteboard mode (`:332`); `syncScreen` and `displaysDidChange` use `capturesScreen` (`:378,458`): the whiteboard lets the capture go like Nothing does.
  - `tick` passes the overlay, except in whiteboard mode where marks are not drawn (`:611`).
  - Debug still takes `marks`.
- `App/Stage/StageRenderer.swift`: `compose(scene:screen:marks:cameras:)` (`:92`), overlay stretched to `placed.rect` (`:116`); the Audio only card when `!layout.showsContent` and no camera drew (`:128,153`, card cached in `audioOnlyCard`, `:45`).
- `App/Stage/StageScreenSource.swift:156`: `followsWindow` (a window share, or an app that is on another desktop).
- `App/CoordinatorController.swift`: `drawing`, `whiteboardModel`, `isDrawing`, `shareBeforeWhiteboard` next to `recordingChrome` (`:1766`); `wireDrawing()` called at the end of `init` (`:1180`); `pushWhiteboardPage(to:)` in `ensureStage` (`:1248`); `endDrawingTools()` first thing in `stopStage` (`:1271`); the Drawing section (`:1888-2030`): `canDraw`, `toggleDrawing`, `startDrawing`, `stopDrawing`, `toggleWhiteboard`, `shareKindChanged(to:)`, page push throttled to 30 Hz. `capturesScreen` replaces `!= .nothing` where the question is "is a screen captured" (`requestShapeApply`, `buildScene`'s `wantsScreen`, `wireInputEvents`); `showsContent` still means "something is behind the camera" so it is true for the whiteboard.
- Entry points: control bar Draw button (`App/UI/RecordingChrome.swift:252`, bar 232 -> 272 pt wide); meeting pill Draw button (`App/UI/MeetingControls.swift:759,856`, pill 548 -> 584 pt, `MeetingControlBarController.width`); shortcut `ShortcutAction.toggleDrawing` ("Draw on the screen", Class group, default **Option-Shift-D**, `App/ShortcutModel.swift:234,389`, handled at `App/ShortcutRuntime.swift:114`); `Tests/ShortcutModelTests.swift` Class group is now 8 rows.
- Whiteboard as a "Behind you" tile: `ShareKindPicker` (`App/UI/WebcamPage.swift:575-625`, tile built from `Kind.allCases`, so the Record view picks it up too), `ShareTargetSettings.swift:36`, `LookSummary.swift:58`.
- `project.yml`: `ScreenAnnotation.swift`, `CameraWhiteboard.swift`, `AudioOnlyCard.swift` in `GreenroomTests`; `Tests/ScreenAnnotationTests.swift`.

## How it behaves

- **Draw** (button, pill button, Option-Shift-D) is available whenever a screen (or the whiteboard) is the share and a session or the Record view is up (`canDraw`); it toggles. With a display or app share the canvas covers the recorded display (`recordedScreen`); with a window share drawing is confined to that window and the marks move with it (the 10 Hz poll translates them).
- Clicking the chosen tool again pauses drawing (clicks go through, marks stay, hover a mark to move, resize or delete it). Done or Esc clears the marks and takes the Stage overlay away.
- **W** (or the toolbar's whiteboard button) calls `toggleWhiteboard()`: the share becomes the whiteboard, the screen canvas steps aside keeping its marks, the whiteboard window opens. "Back to screen" restores what was shared before and the canvas comes back. The Webcam page / Record view tile does the same without the borrowed state. If the session ends while the whiteboard was borrowed with W, the previous share is restored.
- **Whiteboard**: the page is white 16:9; each stroke change renders `renderPage(width: 1920)` for the Stage (30 Hz at most). The Stage treats it as a whole-display screen, so the camera keeps the user's shape and position; Presenter and Cutout work too. No separate inset logic was needed. A window share's dims and screen marks are not drawn on the whiteboard.
- **Audio only**: the Stage already ticks on its own 30 fps timer and emits a backdrop-coloured frame even with no inputs (`StageCompositor.tick`), so nothing froze and no still-frame timer was needed; only the picture was missing. The card shows when content is off (Nothing shared) and no camera drew (none plugged in, or it has not delivered yet: the card shows until the first frame). With content on and the screen not yet delivered the backdrop stays, as before.

## Untested (nothing here was run on a real screen)

- No real drawing: the canvas, the toolbar glass, key handling (the canvas must really be the key window; panels are `.nonactivatingPanel` with `canBecomeKey` true, `makeKey` + `makeFirstResponder` are called on begin), the pointer pass-through, hover edit handles, eraser and the Pointer monitors.
- That marks really show up in a meeting and a recording, for display, app, window shares and the presenter layout (the renderer path is proven off screen: `stage-marks.png`, and the mapping by unit tests).
- Window follow: marks moving with the window and the clip while the window is resized; a window resized keeps marks in their old window-relative place (they are translated only, not scaled).
- Multi-display: canvas placement uses `recordedScreen` and `cgOrigin(of:)` (primary screen height); the "primary" is the screen at Cocoa origin zero.
- The toolbar and whiteboard tools as Liquid Glass: off-screen rendering shows no glass at all (no window server), so only layout and symbols were checked.
- The Webcam page and Record view with five tiles (Whiteboard added before Nothing) fit at their narrowest widths.
- Whiteboard window: reopening via Draw after closing it; closing the window with the share still on Whiteboard just hides it.
- Not done: a Draw button on the meeting-window toolbar or the Participants rail (only the pill, the control bar and the shortcut); no menu-bar item; the whiteboard window is not remembered across launches; marks are not saved to the `.events.json` sidecar or editable later (they are burned into the file as drawn).
- `MainActor.assumeIsolated` wrappers inside `AnnotationCanvasView` are belt-and-braces (NSView is main-actor in this SDK) and could go.
