# Bringing Recorditor features into Greenroom

Agent-ready notes for the work of porting features from **Recorditor** (a Zoho
macOS screen recorder with an editor) into Greenroom. Read this first, then the
log for the phase you are touching.

| File | What it holds |
|---|---|
| `README.md` (this) | Why, the method, decisions, phase plan and status |
| `events-port-log.md` | Phase 2: click/keystroke tracker, coordinate and time mapping, seams |
| `camera-port-log.md` | Phase 3: camera Blur/Image backgrounds, camera unplug recovery, how it coexists with CameraDirector |
| `controls-port-log.md` | Phase 4: pause without gaps, countdown, control bar, recording border, system audio mix |
| `drawing-port-log.md` | Phase 5: drawing on the screen (marks composited into the Stage picture), whiteboard as a share choice, Audio only card |
| `editor-port-log.md` | Phase 1: every file copied for the editor, every change vs upstream, every seam in Greenroom |

## Source of truth

- Reference copy on the owner's Mac: `~/Desktop/ZRecorditor Ref/`
  - `README.md`, `Editor-Integration.md`, `Recording-Customisation-Integration.md` — the Recorditor team's integration guides (the work plan).
  - `ZRecorditorSourceCode/docs/01-Recording.md`, `05-Editor.md` — what each feature does for users (the spec).
  - `ZRecorditorSourceCode/native/MacRecorder/` — the Swift sources (`Recording/`, `Editor/`, `Support/`).
- Upstream repo: `zohocorp/Jambav/iOS/iGarage/iProjects/ZRecorditor`, branch `Parch_Requirement`.
- **Pinned commit: `7210322c42633de1b5dafe40a6bb6177da971da9`.** Every "upstream" reference in these notes means this commit. To sync later, diff upstream from this commit and replay changes onto the ported files using the logs.
- The owner has approved copying code from Recorditor into Greenroom.

## How the two apps differ (why we port piece by piece)

Greenroom's recorder is not a plain screen recorder: ScreenCaptureKit frames
(`App/Stage/StageScreenSource.swift`) go through the Stage compositor
(`StageCompositor`/`StageRenderer`) that also feeds the Zoom meeting; the same
composite is recorded by `App/Recording/SessionRecorder.swift` →
`StageEncoder.swift` (fragmented H.264, keyframe ~2 s). The camera is already
composited into the picture (shapes, move/resize, Vision cutout).

So we take **path B** of Recorditor's guide: bring features in one by one and
wire them into Greenroom's pipeline. We do **not** adopt Recorditor's
`ScreenRecorder` (2,700 lines, tied to rooms/On Stage, duplicates the Stage).

Gap analysis at the start (2026-11-13):

| Recorditor feature | Greenroom before | Phase |
|---|---|---|
| Editor: trim, cut, crop, merge, speed, blur/text/arrow, music, fast export, ✦ Assistant | Missing (only clip export, notes burn-in, Analyse) | 1 |
| Clicks & keystrokes `.events.json` → ripples, key chips, auto-zoom | Missing | 2 |
| Camera background Blur / Image, camera unplug fallback | Cutout exists; blur/image missing; fallback partial | 3 |
| Pause without gaps, countdown, floating control bar, recording border, system audio | Missing (system audio off in code) | 4 |
| Drawing on the screen, whiteboard (also with screen off) | Missing | 5 |
| Presentation follow (window → its full-screen slideshow) | Window follow only | 6 |

## Decisions

- **Path B, not path A** (above).
- **Copy, then adapt; keep upstream names inside ported files** so future syncs diff cleanly. Exceptions: generic support types are prefixed (`Theme` → `EditorTheme`) so they don't become app-wide names that bypass `DESIGN.md`.
- **Every copied file carries a header** `Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/<path>).`
- **Look follows Greenroom's `DESIGN.md`**, not Recorditor's theme: `EditorTheme` maps onto Greenroom tokens.
- **Deployment target stays macOS 14.** Audit found no macOS 15 API in the editor; the only newer API is in `CaptionGenerator` (macOS 26 SpeechAnalyzer), which is not ported.
- **Captions not ported.** Greenroom already transcribes recordings (`App/Screenroom/ScreenroomTranscriber.swift`); a later step can feed that transcript into the editor instead of Recorditor's caption generator.
- **Room comments (Live Feedback) removed** — Greenroom has no rooms. Greenroom's own notes (`notes.jsonl`) are a candidate to reuse the `RoomCommentPopup` overlay later.
- **Edits never touch the original.** A saved edit becomes a new recording folder next to the original (`<name> – Edited`).
- **Pausing in a meeting**: pauses only the recording file; the meeting continues (owner confirmed, built in phase 4).

## Prep checks done (phase 0)

- Greenroom recordings (fragmented H.264 MP4, 1080p30) open in AVFoundation, are playable/exportable, seek in <140 ms, keyframes every 1.3–1.75 s, and an `AVMutableComposition` trim exports at the expected duration. Some recordings have no audio track — the editor must cope.
- Editor dependencies outside `Editor/`: `LibraryViewModel`, `PlaybackSheet` (Library), `RoomComments`, `RoomShareCopy`, `RoomCommentsEmbedder` (rooms), `AppPaths`, `AppSettings` (whose Settings UI pulls in `AccountManager`). All replaced or removed in phase 1.
- `EditAssistant` is a local rule parser (regex/keywords), no LLM.
- No third-party dependencies in the editor or recording files; Recorditor's WorkDrive/Zoho packages live only in `Support/WorkDrive*` / `AccountManager`, which we don't take.

## Status

| Phase | State |
|---|---|
| 0 Prep | Done |
| 1 Editor | Built (Debug, zero errors) 2026-11-13; not yet tried by hand. Entry: Recordings inspector → Edit tile → `Window("Editor", id: "editor")` |
| 2 Clicks & keystrokes | Built (Debug, zero errors) 2026-11-13; untested by hand. See `events-port-log.md` |
| 3 Camera backgrounds + recovery | Built (Debug, zero errors) 2026-11-13; untested with a real camera. See `camera-port-log.md` |
| 4 Pause, countdown, controls, border, system audio | Built (Debug, zero errors, 249 unit tests pass) 2026-11-13; untested by hand. See `controls-port-log.md` |
| 5 Drawing, whiteboard, Audio only card | Built (Debug, zero errors, 260 unit tests pass) 2026-11-13; untested by hand. See `drawing-port-log.md` |
| 6 Presentation follow | Planned |

## How to continue a phase (for agents)

1. Read the phase's rows in Recorditor's `Recording-Customisation-Integration.md` and the matching section of `01-Recording.md`.
2. Find the Greenroom side first (Stage, SessionRecorder, StageEncoder, RecordStudioView, RecordingsView) — wire into it, don't add a parallel pipeline.
3. Copy upstream files with the header; record every change in a `<phase>-port-log.md` here, plus each seam (Greenroom file:line touched).
4. `xcodegen generate`, Debug build, no installs (run from DerivedData). UI checks go through the Accessibility tree; screencapture is blocked from the shell.
5. Update the Status table above.
