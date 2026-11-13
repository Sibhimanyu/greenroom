# Editor port log

Recorditor's video editor, ported into Greenroom. Upstream: ZRecorditor @7210322,
`native/MacRecorder/`. Every ported file starts with a one-line
"Ported from Recorditor ..." header. Build: `xcodegen generate`, then
`xcodebuild -project Greenroom.xcodeproj -scheme Greenroom -configuration Debug build` (succeeds).

## App/Editor/ files

### EditorViewModel.swift  (Editor/EditorViewModel.swift)
- Removed captions: `captions`, `isGeneratingCaptions`, `captionStatus`, `burnCaptions`, `saveSRT`, `CaptionEngine`, `generateCaptions`, `finalCaptionLines`, the `effects.captions` block in `builtEffects`, caption resets in `load`, the `.srt` write on export, and `burnCaptions` in `hasAnyEnhancement`. (`ENABLE_CAPTIONS`/`ENABLE_WHISPER` blocks gone; CaptionGenerator/WhisperEngine not copied.)
- Removed room comments: `roomComments`, `burnRoomComments`, `canBurnRoomComments`, `exportRoomComments(to:)`, the `effects.roomComments = RoomShareCopy.popups` block, `RoomComments.loadIncludingEmbedded`, `RoomCommentsEmbedder`. `load(url:)` uses `url` directly (`let mediaURL = url`) instead of `RoomShareCopy.cleanSource`.
- Saving (`exportPanelAndRun`): `AppPaths.libraryDir` replaced. Each save creates a new session folder via `EditorConfig.makeEditedSessionFolder(for:)` and writes `<exportName>.<ext>` inside it; on success `EditorConfig.writeMetadata` writes `session.json`; on cancel or failure the new folder is removed. Numbered-file-suffix loop removed (the folder is unique instead).
- `finalTimeIfKept` kept (still used by ripples/keys/zoom).

### EditorView.swift  (Editor/EditorView.swift)
- Removed: caption preview (`captionPreview`), the `#if ENABLE_CAPTIONS` CAPTIONS section, the ROOM COMMENTS section of the Effects popover.
- `LibraryViewModel` -> `EditorRecordingLibrary` (`@StateObject library`); `await library.refresh()` -> `library.refresh()` (sync). Thumbnail/duration views replaced by `EditorRecordingThumb` / `EditorRecordingDuration` (both in the empty-state picker and the merge picker).
- `PlaybackSheet` -> `EditorPlaybackSheet`.
- `TimelineView()` -> `EditorTimelineView()`.
- Theme renames (below). Copy: "Library"/"~/Movies/Recorditor" strings now say Recordings / "saved as its own recording ... in a new Edited folder".

### TimelineView.swift  (Editor/TimelineView.swift)
- Type renamed `TimelineView` -> `EditorTimelineView`: it shadowed SwiftUI's `TimelineView` and broke `TimelineView(.periodic ...)` in RecordStudioView and ScreenroomReportView. File name unchanged.
- `Theme.` -> `EditorTheme.`.

### AnnotationOverlayView.swift, EditAssistant.swift, EffectsRenderer.swift
- Only `Theme.` -> `EditorTheme.`. EffectsRenderer keeps `RoomCommentPopup` / `roomComments` (always empty). `EffectsRenderer`'s `Caption` struct and `captions` list are also kept (empty, harmless).
- EditAssistant text still says captions are on the roadmap (unchanged upstream string).

### VideoExporter.swift
- `AppSettings.bitsPerPixel` -> `EditorConfig.bitsPerPixel`. Nothing else.

### CropOverlayView.swift, ArrowDragLayer.swift, PlayerContainerView.swift
- Header comment only. (Annotation rects keep signed width/height; untouched.)

### TimeFormatting.swift  (Support/TimeFormatting.swift)
- Header comment only.

### RecordingEvents.swift  (Recording/InputEventTracker.swift, lines 1-38)
- Only the `RecordingEvents` model; `InputEventTracker` not copied.

### EditorTheme.swift  (Support/Theme.swift)
- `Theme` -> `EditorTheme`; `CardStyle` -> `EditorCardStyle`, `.card()` -> `.editorCard()`; `RoundControlButtonStyle` -> `EditorRoundControlButtonStyle`; `PanelHeader` -> `EditorPanelHeader`; `ThemeButtonStyle` -> `EditorButtonStyle` (`.themePrimary` etc. -> `.editorPrimary` ...); `ThemeSegmented` -> `EditorSegmented`.
- Colours re-pointed: accent and accentDeep = `Brand.green`; `accentText` (new, used by panel headers) = `Brand.text`; danger = `.systemRed`; surface/card = `controlBackgroundColor`; border/cardStroke = `separatorColor`; text colours = `.primary`/`.secondary`; white-alpha fills -> `.primary` alpha so it tracks light and dark.
- Dropped the navy backdrop (`bgTop`, `bgBottom`, `background`), `titleGradient`, `recordGradient`. `accentGradient` kept but flat (DESIGN.md: no gradients).
- Known drift: some editor views use `EditorTheme.accent` (the lime-ish fill) as a foreground icon colour without a label; DESIGN.md allows that for icons only. Check against "Open drift to fix" if anything is labelled.

### EditorConfig.swift  (new, replaces AppPaths and three AppSettings statics)
- `frameRate = 30`, `bitsPerPixel = 0.8` (Greenroom has no equivalent setting). `frameRate` is currently unused by any ported file.
- `makeEditedSessionFolder(for:)`: `~/Documents/Greenroom/<original folder name> – Edited` (en dash), ` 2`, ` 3` if taken. A source not inside a session folder (loose legacy file, or Load Video from elsewhere) uses its file name as the base, in the recordings root.
- `writeMetadata(forEditIn:source:)`: `session.json` with `title` = original's custom title (else folder name) + " – Edited". No `kind` (a plain Green-style session). The original is never written.

### EditorRecordingLibrary.swift  (new, replaces LibraryViewModel and PlaybackSheet)
- `EditorRecordingLibrary` lists `ScreenroomLibrary.presentations()` that have a recording; `EditorRecordingThumb` / `EditorRecordingDuration` read `SessionThumbnails.shared`; `EditorPlaybackSheet` is a plain `AVPlayerView` sheet (Recorditor's PlaybackSheet is not self-contained: it is built around room comments, so it was not copied).

## Seams (Greenroom touch-points outside App/Editor/)

- `App/GreenroomApp.swift:90` `@StateObject private var editor = EditorViewModel()` (app-lifetime).
- `App/GreenroomApp.swift:123` `.environmentObject(editor)` on the main window's `ContentView` (RecordingsView reads it).
- `App/GreenroomApp.swift:145` `Window("Editor", id: "editor") { EditorView().environmentObject(editor).tint(Brand.green) }`, default size 1180x760.
- `App/UI/SessionsContent.swift:576` `SessionInspectorModel.canEdit`; `:604` `SessionInspectorActions.edit`; `:728` `editTile` added to the tile row; `:807` `editTile` definition (a `StatusTile`, "Edit", scissors).
- `App/UI/RecordingsView.swift:187` `@EnvironmentObject editor` and `@Environment(\.openWindow)`; `:274` `.onChange(of: editor.savedExportURL)` calls `reload()`; `:557` `model.canEdit = take != nil`; `:639` `actions.edit` opens the `editor` window and runs `await editor.load(url: take.url)`.
- `project.yml` is unchanged (`sources: App/` picks up App/Editor/); `Greenroom.xcodeproj` is regenerated by xcodegen.
- Anything else that renders `RecordingsView` off-screen (e.g. `.context` render scripts) now needs an `EditorViewModel` environment object.

## Behaviour differences from Recorditor
- Edits are saved in a new Greenroom session folder, not a flat library file; no numbered-file suffix.
- No captions, no room comments, no `.srt`.
- Look follows Greenroom (system chrome, Brand.green), not the Recorditor navy/blue theme.
- Frame rate / quality are fixed at 30 fps / 0.8 bpp.
- Entry is from the Recordings inspector (Edit tile) or the Editor window's own Load Video / picker.
