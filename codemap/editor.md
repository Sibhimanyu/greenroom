# App/Editor

The video editor, ported from Recorditor (`ZRecorditor @7210322`) and reshaped so it is not a window of its own: it is the Edit mode of a session's page. One `EditorViewModel` (a single app-wide `@StateObject` created in `App/GreenroomApp.swift` and injected as an environment object) holds all edit state for the loaded video: trim, cuts, speed segments, crop, merged extra clips, background audio, annotations (blur/text/arrow) and recorded-input effects (click ripples, keystroke chips, auto-zoom). `EditorView.swift` holds the UI PARTS (stage, tool row, timeline block, side panel, sheets); `App/UI/SessionDetailContent.swift` lays them out around the picture and timeline shared with Watch mode. Export builds an `ExportRecipe` and renders with `VideoExporter` -> `FastExportEngine` (AVAssetReader -> AVAssetWriter, hardware encoders), optionally followed by an `EffectsRenderer` pass. An edit is always saved as a NEW session folder `<original> – Edited` next to the original; the original is never touched.

## Files

| Path | Owns | Key types / functions |
|---|---|---|
| `App/Editor/EditorViewModel.swift` | All editing state, undo/redo, playback, export orchestration, mapping of times between source / edited / final timelines | `EditorViewModel` (`load(url:)`, `togglePlay`, `seek(to:)`, `undo/redo`, `addCut`, `setCrop`, `applySpeed`, `addMergeClips`, `keptRanges()`, `builtEffects()`, `editedSpeedRanges()`, `currentRecipe()`, `exportPanelAndRun()`, `cancelExport()`, `closeVideo()`, `hasUnsavedEdits`), `CutRegion`, `MergeClip`, `EditorAnnotation`, `SpeedSegment` |
| `App/Editor/EditorView.swift` | The editor's UI parts and page-level chrome | `EditorChrome`, `EditorSupport` (+ `.editorSupport(chrome:onBack:)`), `EditorSavedPopup`, `EditStage`, `EditToolRow`, `EditTimelineBlock`, `EditSidePanel`, `EditsPanel`, `BackgroundAudioOptions`, `SpeedPopover`, `SpeedDial`, `ExportOptionsSheet`, `EditorKeyMonitor` |
| `App/Editor/TimelineView.swift` | The timeline: ruler, thumbnail track, trim handles, selection, lanes for cuts/speed/annotations/audio, zoom | `EditorTimelineView`, `TimelineThumbnails` (in-process cache of tile images) |
| `App/Editor/VideoExporter.swift` | Recipe -> AVMutableComposition -> file; speed ranges, overlay audio, crop/merge composition, size estimate; hardware reader/writer engine; quality/format enums | `ExportRecipe`, `VideoExporter.export/estimatedSize/buildComposition`, `ExportQuality`, `ExportFormat`, `FastExportEngine.render` |
| `App/Editor/EffectsRenderer.swift` | CoreImage per-frame effects: ripples, key chips, captions, blur/text/arrow annotations, zoom camera, room-comment popups | `EditedEffects` (`Ripple`, `KeyChip`, `Caption`, `Annotation`, `ZoomKeyframe`, `RoomCommentPopup`), `AnnotationColor`, `EffectsRenderer.handlerComposition`, `.render` |
| `App/Editor/RecordingEvents.swift` | The `<video>.events.json` model and load/save | `RecordingEvents` (`Click`, `Key`, `load(for:)`, `save(for:)`, `sidecarURL`) |
| `App/Editor/EditorConfig.swift` | Greenroom-specific constants and where an edit is saved | `EditorConfig` (`frameRate` 30, `bitsPerPixel` 0.8, `editedSuffix` "– Edited", `makeEditedSessionFolder(for:)`, `writeMetadata(forEditIn:source:)`) |
| `App/Editor/EditorRecordingLibrary.swift` | Picker of existing recordings inside the editor (Load/Add clip), thumbs, playback sheet | `EditorRecordingLibrary` (uses `ScreenroomLibrary.presentations()`), `EditorRecordingThumb`, `EditorRecordingDuration`, `EditorPlaybackSheet` |
| `App/Editor/PlayerContainerView.swift` | `AVPlayerLayer` wrapper to overlay own controls | `PlayerContainerView`, `PlayerNSView` |
| `App/Editor/CropOverlayView.swift` | Drag-to-crop overlay (normalized 0...1 rect, top-left origin) | `CropOverlayView` |
| `App/Editor/AnnotationOverlayView.swift` | Place a pending blur/text/arrow by dragging a box; live preview of annotations | `AnnotationPlacementOverlay`, `AnnotationPreviewOverlay`, `ArrowShape` |
| `App/Editor/ArrowDragLayer.swift` | Raw AppKit mouse handling for arrow endpoints (SwiftUI gestures were unreliable) | `ArrowDragNSView`, `ArrowDragLayer` |
| `App/Editor/EditorTheme.swift` | Recorditor Theme re-pointed at Greenroom tokens (DESIGN.md) and button styles | `EditorTheme`, `EditorButtonStyle`, `EditorPanelHeader` |
| `App/Editor/TimeFormatting.swift` | `mm:ss` / `h:mm:ss` / playhead readout strings | `TimeFormatting` |

## How it fits

Host and routing:
- `App/GreenroomApp.swift` (~line 98): `@StateObject private var editor = EditorViewModel()`, put in the environment.
- `App/CoordinatorController.swift` `enum MainPage { ... .detail(id), .report(id), .editor(id) }` and `goBack()`; `.editor` pops to `.detail`.
- `App/UI/RecordingsView.swift`: `inspectorActions(session).edit` sets `coordinator.mainPage = .editor(session.id)` then `await editor.load(url: take.url)` and seeks to the Watch playhead. Leaving the editor page closes the video (`editor.closeVideo()`, clears `savedExportURL`); `onChange(of: editor.savedExportURL)` reloads the session list so the new edited folder appears.
- `App/UI/SessionDetailContent.swift`: Watch/Edit switch (`isEditing`); in Edit it shows `EditStage()`, `EditTimelineBlock()`, `EditSidePanel(...)` and applies `.modifier(EditingSupport ...)` which wraps `.editorSupport(chrome:onBack:)`; the toolbar Save button sets `editor.showExportOptions = true`. `App/UI/ContentView.swift` routes Back through `editor.backRequests += 1` while on the editor page. `App/UI/SessionTranscriptView.swift` also reads `EditorViewModel` (as `vm`) for the edit-mode transcript.

Inputs and outputs:
- Source video: any URL given to `load(url:)` (session recordings, usually `~/Documents/Greenroom/<session>/<stamp>.mp4`). Sidecar `<video>.events.json` is loaded as `recordingEvents` (written by `App/Recording/InputEventTracker`).
- Export (`exportPanelAndRun`): `EditorConfig.makeEditedSessionFolder(for: source)` creates `~/Documents/Greenroom/<original folder> – Edited[ 2...]/`; the file is `<name>.<mp4|mov>`; on success `EditorConfig.writeMetadata` writes `session.json` with the title `<original title> – Edited`, `closeVideo()`, `savedExportURL` set (shows `EditorSavedPopup`). On cancel or failure the new folder is removed. Loose files or files picked from elsewhere get a folder named from the file name in the recordings root.
- Time domains: source time (trim/cuts/selection live here) -> edited time (after cuts; `editedTime(forTimeline:)`) -> final time (after speed segments; `finalTime(fromEdited:ranges:)`). All effect times sent to `EffectsRenderer` are on the FINAL timeline (`builtEffects()`).

Export pipeline (`VideoExporter.export`): `buildComposition(recipe)` (kept ranges + merge segments + crop transform) -> `applySpeedRanges` -> `overlayAudioMix` -> then
- no crop/merge, or no effects: ONE `FastExportEngine.render` pass (with `EffectsRenderer.handlerComposition` when there are effects);
- crop/merge AND effects: two passes via a temp `recorditor-edit-<uuid>.mp4` (transform first, progress 0-60%), then `EffectsRenderer.render` (60-100%).
Spectral audio pitch correction is used only when speed ranges exist.

## To change X, go to Y

- Add a new edit operation (state + undo): a `@Published` on `EditorViewModel`, include it in `Snapshot`/`pushUndo`, in `hasUnsavedEdits`, `clearAllEdits`, `closeVideo`, `load(url:)` resets, then in `currentRecipe()`/`ExportRecipe` and `VideoExporter`.
- Cut / trim / kept-range logic: `EditorViewModel.keptRanges()`, `addCut`, `setCutRange`, `setTrimStartToPlayhead`, `removeSelection`.
- Speed changes: `applySpeed(factor:from:to:)`, `applySpeedToSelection`, `editedSpeedRanges()`; export side `VideoExporter.applySpeedRanges`; UI `SpeedPopover`, `SpeedDial`.
- Crop: `EditorViewModel.setCrop`, `cropPreviewActive`, `displayVideoSize`; overlay `CropOverlayView`; export crop in `buildComposition`.
- Merge extra clips: `addMergeClips`, `moveMergeClip`, `setMergeTrimStart/End`; `ExportRecipe.mergeSegments`; picker UI in `EditToolRow`/`EditsPanel` using `EditorRecordingLibrary`.
- Annotations (blur/text/arrow): `beginAnnotationPlacement`, `placeAnnotation(rect:)`, `setAnnotationRange`; placement UI `AnnotationPlacementOverlay`; arrow dragging `ArrowDragNSView`; rendering `EffectsRenderer.Compositor.compose` and `makeArrow`; colours `AnnotationColor`.
- Click ripples / keystroke chips / auto-zoom: toggles `showClickRipples`, `showKeystrokes`, `autoZoom`; mapping in `builtEffects()`; clustering `zoomKeyframes(fromFinalClicks:)` (1.8x, 3 s cluster gap); drawing in `EffectsRenderer`; data capture in `App/Recording/InputEventTracker.swift`.
- Background audio (volume, loop, fade, placement): `setOverlayAudio`, `overlayAudio*` properties, `BackgroundAudioOptions`, `VideoExporter.overlayAudioMix`.
- Export formats and quality presets: `ExportFormat`, `ExportQuality.preset(hevc:)`; options sheet `ExportOptionsSheet`; size estimate `updateExportEstimate` / `VideoExporter.estimatedSize`.
- Export bitrate / GOP / hardware writer settings: `FastExportEngine.render`, `EditorConfig.bitsPerPixel`, `EditorConfig.frameRate`.
- Where an edit is saved / its title / suffix: `EditorConfig.makeEditedSessionFolder`, `writeMetadata`, `editedSuffix`; default Save-as name `defaultExportName()`.
- Timeline interactions (drag kinds, lanes, zoom, handles): `EditorTimelineView` (`DragKind`, layout constants at top); thumbnails `TimelineThumbnails`.
- Keyboard shortcuts in editing: `EditorKeyMonitor.handle` (installed by `EditorSupport.onAppear`).
- Back / discard-edits / saved-popup flow: `EditorSupport.handleBack`, `EditorChrome`, `EditorSavedPopup`.
- Colours, buttons, panel headers: `EditorTheme.swift` (use DESIGN.md tokens: `Brand.green` fills, `Brand.text` for green text).
- Playback and preview-with-edits (skipping cuts, rate on speed segments): `EditorViewModel.togglePlay`, `previewEdits`, `activePreviewRate`, `playingMergeIndex`.
- Edit-mode page layout (what sits where): `App/UI/SessionDetailContent.swift`, not this folder.

## Gotchas

- One shared `EditorViewModel` for the whole app. Always call `closeVideo()` when leaving the editor page (RecordingsView does) or state leaks into the next session; `load(url:)` resets edits but callers should confirm first when `hasUnsavedEdits`.
- The edited export is a NEW folder, never an in-place overwrite. If you add export paths, remove the new folder on cancel/failure as `exportPanelAndRun` does, and keep `EditorConfig.writeMetadata` so Recordings shows the right title.
- Timeline vocabulary matters: effects are mapped to the FINAL timeline; annotations and cuts are stored in source/timeline time. Mixing these is the most common bug. Speed ranges are on the EDITED timeline and are dropped entirely when `mergeClips` is non-empty (`editedSpeedRanges()`).
- Crop plus effects needs two passes because the effects handler draws in final-frame space; do not collapse them. Crop rect is normalized, top-left origin; annotation rects likewise.
- `AVAssetExportSession` is no longer used for rendering (software, slow, huge); `estimatedSize` still creates one only to predict size. Keep renders on `FastExportEngine`.
- `ExportQuality.hd` has no HEVC 720p preset; it falls back to 1080p HEVC.
- Arrow editing uses raw AppKit mouse events on purpose (SwiftUI drag values arrived in the wrong space / flipped axis). Keep `ArrowDragNSView` flipped (top-left origin).
- `EditorKeyMonitor` is a local key monitor that only handles keys when: a video is loaded, no saved popup, not exporting, the event's window is the titled window named "Greenroom", no sheet attached, and the first responder is not a text view. Renaming the main window title breaks editor shortcuts.
- `EffectsRenderer.EditedEffects.roomComments` exists in the renderer (pop-ups for room comments) but `EditorViewModel.builtEffects()` currently never fills it.
- `RecordingEvents.save(for:)` writes nothing when empty; `RecordingEvents` is the model only. The tracker class lives in `App/Recording/InputEventTracker.swift`. The sidecar sits beside the recording and is treated as disposable by `SessionFolderRules`.
- The Editor files are not in the `GreenroomTests` source list (`project.yml`) and no test in `Tests/` pins them; changes are verified by building and exercising the editor.
- Files marked "Ported from Recorditor (ZRecorditor @7210322)" keep the upstream structure; `docs/recorditor-integration/` tracks the port. Written-for-Greenroom files: `EditorConfig.swift`, `EditorRecordingLibrary.swift`.
- `EditorRecordingLibrary` lists via `ScreenroomLibrary.presentations()` (any session with a recording), so it follows whatever `ScreenroomLibrary.recording(in:)` picks (largest non-clip file), not necessarily the take being edited.
