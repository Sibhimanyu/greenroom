# App/Screenroom

Recording analysis and the report, folded into the Sessions/Record flow. Despite the name it is no longer a separate window or recorder: the old Screenroom (a presentation recorder that wrote `presentation.mov`) was merged into Greenroom's Sessions window. What remains is the "Get feedback / Analyse" pipeline that runs over ANY session folder under `~/Documents/Greenroom` that holds a recording or notes: transcribe (whisper.cpp or Apple Speech) -> stills -> Vision "presence" pass -> cohort consistency -> written analysis (user's own agent CLI, else Apple's on-device model, else counted from notes) -> `analysis.json` + report view + exports (Markdown, PDF, annotated video, SRT). Design rule: the session folder IS the API. There is no index or database; every artefact is a plain file next to the recording, so a folder copied elsewhere still opens. The same area also owns whisper setup (shared with Cues) and the evaluator's timestamped notes and rubric.

## Files

| Path | Owns | Key types / functions |
|---|---|---|
| `ScreenroomReviewController.swift` | The one `@MainActor ObservableObject` driving selection, notes, scoring, the analysis run, exports, progress/ETA | `ScreenroomReviewController.shared` (`select(folder:)`, `requestAnalyse()`, `analyse()`, `run(_:)`, `cancel()`, `addNote`, `deleteNote`, `setScore`, `setComment`, `recomputeCohort`, `seek`, `playWithoutFillers`, `exportAnnotatedVideo`, `exportSubtitles`, `reportMarkdown(for:)`, `selectionMismatch`, `eta`) |
| `ScreenroomLibrary.swift` | Finds sessions on disk (no index) | `ScreenroomPresentation`, `ScreenroomLibrary.presentations()`, `.recording(in:)`, `.presentationFileName`, `.cohortEntries()`, `.date(of:)` |
| `ScreenroomNote.swift` | Evaluator note + `notes.jsonl` (versioned per line, schema v2) | `ScreenroomNote`, `ScreenroomNotesFile` (`append`, `load`, `replace`, `add`, `remove`) |
| `ScreenroomRubric.swift` | Rubric (per-teacher default in UserDefaults, per-session snapshot in `rubric.json`) and scores | `ScreenroomCriterion`, `ScreenroomRubric.starter`, `ScreenroomScore`, `ScreenroomScoring` (`load/save(in:)`, `apply(_:by:)`), `ScreenroomRubricStore` |
| `ScreenroomTranscriber.swift` | Engine switch + settings; Apple Speech path; writes `analysis-transcript.txt` and `words.json` | `ScreenroomTranscriberSettings` (`load`, `resolved`, `resolvedModel`, `whisperIsReady`, key `screenroomTranscriberSettings`), `ScreenroomTranscriber.transcribe`, `loadWords`, `alignToSpeech` |
| `ScreenroomWhisper.swift` | whisper.cpp binary + model discovery and invocation, JSON parse | `ScreenroomWhisper` (`transcribe(wav:model:language:)`, `binaryPath()`, `availableModels()`, `findModel()`, `offeredModels`, `suggestedModel`, `parse`) |
| `WhisperInstaller.swift` | One-button install (Homebrew formula + model download) | `WhisperInstaller.shared` (`Phase`, `recommendedModel`) |
| `WhisperModelPicker.swift` / `WhisperSetupRows.swift` | Shared SwiftUI rows used by Screenroom setup, Settings -> Cues, and the setup guide | `WhisperModelPicker`, `WhisperSetupRows` |
| `ScreenroomAudio.swift` | Recording -> 16 kHz mono WAV via AVFoundation (no ffmpeg) | `ScreenroomAudio.extractWAV` |
| `ScreenroomSpeechMetrics.swift` | Fillers, pace windows, pauses, runs, from word timings; `speech.json` | `ScreenroomSpokenWord`, `ScreenroomSpeechMetrics` (`load(in:)`, `fileName`); voice-activity alignment helper is `SpeechActivity` in `App/Audio/SpeechActivity.swift` |
| `ScreenroomFrames.swift` | A still every 20 s (960 px long edge) into `frames/` for agents and the report | `ScreenroomFrames.extract`, `.existing(in:)`, `.folder(in:)` |
| `ScreenroomPresence.swift` | Vision pass over the camera: facing the room (head yaw, not gaze), movement, away spans; `presence.json` | `ScreenroomPresence` (`Sample`), `ScreenroomPresence.measure(recording:onProgress:)` |
| `ScreenroomCohort.swift` | Marker-consistency findings across sessions (arithmetic only) | `ScreenroomCohort` (`Entry`, `Finding`, `findings(for:among:)`, `minimumForSpread`) |
| `ScreenroomInsights.swift` | Readings sorted into worked/change rows for the report | `ScreenroomInsights` (`verdicts(metrics:presence:)`, `Repeat`, `Question`, `PacePoint`) |
| `ScreenroomAnalyst.swift` | Written analysis: Apple on-device model pass, else counted-from-notes pass | `ScreenroomAnalyst.analyse(...)`, `writtenEngine`, `countedEngine`, `countedPass`, `GeneratedFeedback`, `GeneratedMark` |
| `ScreenroomAgent.swift` | Hands a brief to the user's CLI agent (Claude Code, Codex, custom command) in their shell; parses JSON reply | `ScreenroomAgentSettings` (key `screenroomAgentSettings`; `Kind`), `ScreenroomAgent` (`brief(...)`, `writeBrief`, `stageWorkspace`, `run`, `writeReport`, `existingReport`, `analysis(from:engine:consistency:)`, files `BRIEF.md`, `agent-report.md`) |
| `AnalysisUsage.swift` | Pure (in `GreenroomTests`): token usage of the agent step and the reader that folds Claude Code / Codex JSON lines into it; compact k/M, cost, popover and report wording. Tests in `Tests/AnalysisUsageTests.swift` | `AnalysisUsage` (`liveLine`, `reportLine`, `compact`, `money`, `onDeviceLine`), `AnalysisUsageReader` (`consume`, `usage`) |
| `ScreenroomAnalysis.swift` | The analysis result and `analysis.json`; records which engine wrote it | `ScreenroomAnalysis` (`Point`, `Mark`, `save(in:)`, `load(in:)`, `agreeing(with:presence:strict:)`) |
| `ScreenroomRunRules.swift` | Pure (in `GreenroomTests`): the step list, overall fraction, "Step x of n", Stop's cleanup list and protected names, agent/whisper time limits. Tests in `Tests/ScreenroomRunRulesTests.swift` | `ScreenroomRunRules` (`steps`, `overall`, `stepLine`, `rowState`, `cleanup(inFlight:existedBefore:)`, `isProtected`, `agentTimeout`, `whisperTimeout`) |
| `ScreenroomProcessReaper.swift` | Ends whisper / agent child trees: SIGTERM, then SIGKILL after 2 s; `Watchdog` kills past a time limit | `ScreenroomProcessReaper` (`stop`, `descendants`, `Watchdog`) |
| `ScreenroomETA.swift` | "Roughly how much is left": per-step timing history in UserDefaults | `ScreenroomStage`, `ScreenroomTimings` (key `screenroomStageTimings`), `ScreenroomETA.estimate` |
| `ScreenroomReport.swift` | Markdown report (`report.md`), two audiences | `ScreenroomReport.markdown(...)`, `Audience`, `write(_:in:)` |
| `ScreenroomReportView.swift` | The report window/page (charts, transcript with fillers marked, `paged:` mode for PDF) | `ScreenroomReportView(onBack:)`, `ScreenroomReportView(paged: true)` |
| `ScreenroomExport.swift` / `ScreenroomExportMenu.swift` | PDF pagination, save panels, base file names; toolbar export menu | `ScreenroomExport.pdf(of:width:)`, `.save`, `.copy`, `.baseName`; `ScreenroomExportMenu` |
| `ScreenroomVideoExport.swift` | Notes burned into the video (`presentation-with-notes.mp4`) or `notes.srt` | `ScreenroomVideoExport` (`exportAnnotated`, `subRip`, `writeSubtitles`, `windows(for:duration:)`, `annotatedFileName`, `subtitleFileName`) |
| `ScreenroomAnalysisPane.swift` | Just the shared time formatters `clock(_:)` and `stamp(_:)` (used by `RecordingsView`, `SessionNotesBar`); the old side-pane view was removed | `ScreenroomAnalysisPane` |
| `ScreenroomSettingsTab.swift` | One-time "How to analyse" setup form (transcriber, agent); no longer a Settings tab | `ScreenroomSettingsTab`, `ScreenroomPageContent`, `ScreenroomModelTile`, `ScreenroomFlowPicture` |
| `ScreenroomDefaults.swift` | One-off UserDefaults migration from the Marks name | `ScreenroomDefaults` |

## How it fits

UI entry points (all in `App/UI/`):
- `RecordingsView.swift` holds `@ObservedObject review = ScreenroomReviewController.shared`. The session inspector's "Get feedback" button calls `review.requestAnalyse()` (via `inspectorActions(session).analyse`, ~line 714); `analyseState(session)` decides ready / analysed / unavailable. When `coordinator.mainPage == .report(id)` it renders `ScreenroomReportView(onBack:)`. `.sheet(isPresented: $review.showingSetup)` shows `AnalysisSetupPanel` (`App/UI/AnalysisSetupPanel.swift`), which embeds `ScreenroomSettingsTab`. Selecting a take sets `review.selectedRecording`.
- `SessionNotesBar.swift` / `RecordingsView` pass `onAddNote` -> `review.addNote(text, at:)`.
- `MenuBarView.swift` uses `ScreenroomLibrary.presentations().first`.
- `CoordinatorController.swift` (~5532-5640) reads/writes `ScreenroomAgentSettings` and `ScreenroomTranscriberSettings` for the synced settings payload.
- `App/Cues/CuesWhisperTranscriber.swift` reuses `ScreenroomTranscriberSettings.resolvedModel()` (whisper is a property of the Mac, shared with Cues). `App/UI/CuesSettingsTab.swift` shows `WhisperInstaller` / `WhisperModelPicker`.
- `App/Recording/SessionFolders.recordingsDirectory` is the library root; `SessionMetadata.title` becomes `ScreenroomPresentation.presenter`.

The analysis run (`ScreenroomReviewController.run`), in order, each reporting step/progress/ETA:
1. `transcribe` -> `ScreenroomTranscriber.transcribe` -> whisper path (`ScreenroomAudio.extractWAV` to `audio-for-transcription.wav`, `ScreenroomWhisper.transcribe`, `alignToSpeech`) or Apple `SFSpeechRecognizer` path -> writes `analysis-transcript.txt` (never Cues' `transcript.txt`), `words.json`, then `ScreenroomSpeechMetrics` -> `speech.json`.
2. `takeStills` -> `frames/*.jpg`.
3. `watch` -> `ScreenroomPresence.measure` -> `presence.json` (removed when nobody is in shot).
4. `recomputeCohort` -> `ScreenroomCohort.findings` over `ScreenroomLibrary.cohortEntries()`.
5. `write(consistency:for:)`: agent (`ScreenroomAgent.run`, writes `BRIEF.md`, `agent-report.md`, falls through on error) else `ScreenroomAnalyst.analyse`. Result goes through `.agreeing(with:presence:strict:)` so prose never contradicts the counted numbers.
6. `scoring.apply(marks)` -> `rubric.json`; `analysis.save` -> `analysis.json`; `analysisRuns += 1` (the window opens the report on a NEW run only).
Steps 1-3 only run when a recording exists; a notes-only folder skips to step 4.

Files in a session folder owned by this area: `notes.jsonl`, `rubric.json`, `analysis.json`, `report.md`, `analysis-transcript.txt`, `words.json`, `speech.json`, `presence.json`, `frames/`, `BRIEF.md`, `agent-report.md`, `presentation-with-notes.mp4`, `notes.srt`, plus legacy `presentation.mov`. `transcript.txt` and `cues.txt` belong to Cues; Analyse never writes or deletes them (`isProtected`). Old folders analysed before the split hold Analyse's transcript as `transcript.txt` in "[m:ss]" format; `ScreenroomTranscriptFile.url(in:)` (in `ScreenroomRunRules.swift`) falls back to it only when `analysis-transcript.txt` is missing and the old file is in that format. The watch page's Transcript tab (`SessionSummary.transcriptURL`, `ScreenroomTranscriptFile.displayURL`) shows Cues' `transcript.txt` when it has one, else Analyse's. Whisper loop collapsing (`App/Audio/WhisperLoops.swift`, pure) runs in `ScreenroomWhisper.parse`. Per-Mac state: UserDefaults keys `screenroomAgentSettings`, `screenroomTranscriberSettings`, `screenroomDefaultRubric`, `screenroomStageTimings`; whisper models under `~/Library/Application Support/Greenroom/whisper` (also `~/.cache/whisper`, Homebrew).

Progress and Stop: the controller publishes `plannedSteps`, `stepIndex`/`stepCount`, `progress` + `isDeterminate` (nil fraction for Apple speech and the agent), `elapsed`, `isStopping`, and the `runProgress` snapshot. `App/UI/AnalysisProgressViews.swift` draws the pill's ring and the popover (step list, bar, elapsed, Stop) from them; the pill is `SessionAnalyseButton` in `SessionDetailContent.swift`. Token usage: `ScreenroomAgent.StreamReader` feeds every stdout line to `AnalysisUsageReader`; `ScreenroomAgent.run(onUsage:)` reports each change, the controller publishes `runUsage` and `usageLine` (popover shows it under the step list; "On this Mac, no tokens" once the notes pass is the writer; nothing for custom commands that stream no JSON). The final value is saved as the optional `usage` field of `analysis.json` (old files decode with nil) and drawn as one caption line under the report's provenance paragraph. Claude: `assistant` `message.usage` per message id, then `result` totals + `total_cost_usd` win. Codex: `turn.completed` `usage` summed (cached taken out of input), or a `token_count` running total (bare or in `event_msg.payload`) that replaces. Stop (`cancel()`): cancel the Task, `ScreenroomProcessReaper.stop` on the registered child, then `finishStopped` removes only what the running step had begun writing and this run created (`ScreenroomRunRules.cleanup`). Steps that finished keep their files. Stills are cut into `frames.partial` and swapped in at the end, so a stop leaves old stills alone. Each step and stop is logged to `~/Library/Logs/Greenroom-session.log` as `Analyse: ...`.

## To change X, go to Y

- Which folders count as sessions / which file is "the recording": `ScreenroomLibrary.presentations()`, `.recording(in:)` (largest playable non-clip, non-annotated file; prefers `presentation.mov`).
- Add or reorder analysis steps, status text, cancellation: `ScreenroomReviewController.run`, `plan(for:)`, `begin(_:_:determinate:)`, and add a case to `ScreenroomStage` + `ScreenroomTimings` for the ETA.
- Transcription engine choice, language (default `en_IN`), "never send audio to Apple" rule: `ScreenroomTranscriberSettings`, `ScreenroomTranscriber.transcribe`/`isAvailable`.
- whisper binary lookup, model search paths, parsing: `ScreenroomWhisper.binaryPath`, `findModel`, `parse`; install flow `WhisperInstaller`.
- Filler list, pace windows, pause thresholds: `ScreenroomSpeechMetrics`.
- "Facing the room" threshold (20 degrees), sample interval (2 s), away span (8 s): constants in `ScreenroomPresence` (`facingDegrees`, `everyMs`, `awayWorthNamingMs`).
- Still interval/size: `ScreenroomFrames.everySeconds`, `.longEdge`.
- Consistency findings (drift, per-criterion spread): `ScreenroomCohort.overallHarshness`, `perCriterion`, `minimumForSpread`.
- Agent behaviours (default commands, brief text, workspace staging, reply parsing): `ScreenroomAgentSettings.Kind.defaultCommand`, `ScreenroomAgent.brief`, `stageWorkspace`, `run`, `analysis(from:...)`.
- On-device written pass prompt / output shape: `ScreenroomAnalyst.instructions`, `writtenPass`, `prompt`; counted fallback `countedPass`.
- Rubric defaults or schema: `ScreenroomRubric.starter`, `ScreenroomScoring`, `ScreenroomRubricStore`.
- Note file format or version: `ScreenroomNote` (`schemaVersion`), `ScreenroomNotesFile`.
- Report layout and charts: `ScreenroomReportView` (`Insight`, `NumberedPoint`); readings and wording: `ScreenroomInsights`.
- Markdown report text and audiences: `ScreenroomReport.markdown`.
- Export menu items, PDF page size (612x792), file names: `ScreenroomExportMenu`, `ScreenroomExport`.
- Annotated video look/timing (6 s per note, 2 s lead): `ScreenroomVideoExport` constants and `overlayLayer`/`noteCard`.
- First-press setup sheet content: `ScreenroomSettingsTab` / `ScreenroomPageContent`, hosted by `App/UI/AnalysisSetupPanel.swift`.
- ETA wording and maths: `ScreenroomETA`, `ScreenroomTimings.expected`.

## Gotchas

- Everything reads from and writes straight to disk: scores, notes and analysis are persisted the moment they change; there is no Save button and no unsaved state. Do not add an in-memory-only cache that can drift.
- Never add a database or index. `ScreenroomLibrary` scans one directory level deep on purpose (clip folders and dragged-in junk would otherwise appear).
- `selectionMismatch` / `analysisTarget` / `selectedRecording`: when the window is playing a different take than the one the artefacts describe, derived data (words, metrics, skip spans) must be withheld (`guard !selectionMismatch`). Keep that guard when adding new per-take outputs.
- Analysis steps are not fatal individually: a failed transcribe/stills/watch sets `status` and the run continues; an agent failure falls back to the on-device/counted pass. Preserve that.
- Cancelling a Swift `Task` does not kill a child CLI. The controller keeps `childProcess` (whisper AND agent, both registered via `onStart`) and `cancel()` hands it to `ScreenroomProcessReaper`, which also kills grandchildren. whisper has a time limit (`whisperTimeout`) and the agent 15 min (`agentTimeout`); a timeout is a step failure, not a hang. After a stop, `write` returns nil rather than falling through to the notes pass.
- A new step must be added to `ScreenroomRunRules.steps` and given a `cleanup` case, or Stop cannot say what to remove.
- Counted numbers must win over prose: `ScreenroomAnalysis.agreeing(with:...)` (strict only for the small on-device model). Fillers/pace/cohort stay arithmetic by design (`ScreenroomSpeechMetrics`, `ScreenroomCohort`), never the model's job.
- "Facing the room" is head yaw, not eye contact; the report text says so. Do not rename it to eye contact.
- Whisper is the default transcriber because Apple's recogniser strips fillers; Apple's path requires an on-device model (otherwise it refuses rather than send audio off the Mac).
- `ScreenroomAgent.run` runs a user-provided shell command: the brief and workspace are staged in a temp dir (`greenroom-agent-<uuid>`); only whitelisted files (`agentReadable`) are copied. Stored commands are upgraded only if they match `supersededCommands`. Report text in briefs is data, not instructions.
- `analysisRuns` is bumped once per finished run so the window opens the report only for runs started from it; do not replace it with a boolean that re-fires on selection.
- `SessionMetadata.kind == "screen"` marks old Screenroom folders; the Sessions sidebar category is `SessionKind.review` ("Presentation") in `App/UI/SessionsQuery.swift`. New analysis never depends on `kind`.
- Settings are stored as encoded JSON strings in UserDefaults and synced through `CoordinatorController` (~5546); renaming a key or struct field needs a migration (see `ScreenroomDefaults` for the pattern).
- `ScreenroomReportView(paged: true)` is used off-screen for PDF export; avoid state that needs a live window. A separate off-screen render of the real report to PNG is in the user's memory notes (`.context/rr/go.sh`), not in the repo.
- Colours/type come from `DESIGN.md` tokens; one-series charts only (a categorical palette would colour by position). Only `ScreenroomRunRules.swift` and `AnalysisUsage.swift` from this folder are compiled into `GreenroomTests` (`project.yml`); nothing else here is pinned by a test.
