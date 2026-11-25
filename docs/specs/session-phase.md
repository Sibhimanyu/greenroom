# Session phase: one owner for what Greenroom is doing

Branch: sibhimanyu/hi. Commits 91bbb33 to 00d72e2. Plan: `.context/session-phase-plan.md` (decisions Q1 to Q11). Terms: `GLOSSARY.md` (Session, Take). Code: `App/SessionPhase.swift`. Tests: `Tests/SessionPhaseTests.swift`.

## Problem

`CoordinatorController` set eight `Bool` flags by hand (`isRunning`, `stageLive`, `isStopping`, `recordOnlyActive`, `startingRecordOnly`, `isRecording`, `isRecordingPaused`, `isSavingRecording`) from many places. Callers then combined them in about 80 ad hoc expressions ("in a meeting", "can start", "anything live", and so on), each spelled a little differently. Nothing stated which combinations were possible. Two bugs came out of it: the automatic update check ignored a Record session between takes, and a cancelled meeting start could clear the `isRunning` of a newer start.

## Goal

- One value, `SessionPhase`, owns the session (idle, starting, live, stopping; meeting or Record) and the take (none, rolling, paused, saving).
- The coordinator reports events. Nothing writes a flag directly.
- The eight flags are derived from the phase and still publish as before.
- Repeated flag combinations become named questions on the phase.

## Non-goals

- `takeBusy` and `recordingCountdown` stay outside the phase.
- `StartChoreography.Phase` stays separate.
- No visible behaviour change, except the two fixes (R4, R5).

## Decisions

- Pure restructure first; bugs found become separate, labelled commits (Q1). Keeps the refactor reviewable and the fixes revertable.
- The phase owns the transitions; the coordinator only reports events (Q2). One place to read to know what is legal.
- Step 1 keeps the old flags as `@Published private(set)`, assigned only from the phase (Q3). `$isRunning` sinks, `.onChange(of:)` and view refresh keep working with no call-site edits.
- Step 2 replaces flag combinations with named questions, one group per commit (Q3). Each group can be reviewed and reverted alone.
- Session and Take are two parts in one module (Q6). Saving can outlive the session, so they cannot be one enum.
- Derived flags reproduce the old values exactly, quirks included (Q7). A refactor must not change behaviour; quirks are listed in the `SessionPhase` doc comment.
- Tests talk only to the module: event sequences in, answers out (Q4). Named questions are checked against the old expressions over every reachable state.
- Each start has a number (`startID`); a finish event carries it and a stale one is ignored. This is the fix for R5.
- Checks are unit tests, full suite and build; the owner then tries the Debug build by hand (Q11).

## Requirements

### R1. One owner of the eight flags

Only `SessionPhase.apply(_:)` changes session and take state. The coordinator calls `phase.apply(event)` and then `syncFlags`. No other code assigns the eight flags.

Acceptance:
- Searching `CoordinatorController.swift` finds assignments to the eight flags only inside `syncFlags`.
- Tests drive state with events only, never by setting a flag.

Tests: all event-driven tests, for example `testMeetingStartLiveStop`, `testRecordStartCountdownTakeStopWithSavingAfterStop`, `testStopWhileRecordStartIsPending`, `testFailedMeetingStart`, `testFailedRecordStart`.
Commit: 91bbb33.
Status: built.

### R2. Derived flags match the old values, quirks included

At every step of every flow, `isRunning`, `stageLive`, `isStopping`, `recordOnlyActive`, `startingRecordOnly`, `isRecording`, `isRecordingPaused`, `isSavingRecording` equal what the hand-set flags were. Quirks kept:
- `isRunning` stays true through a Record countdown and take start, until the start task ends.
- `isStopping && isRunning` while Stop waits for a pending start.
- `isSavingRecording` can outlive `isStopping`; `isRecording` can be true while `isStopping`.
- `isRecordingPaused` stays true after a paused take ends, until the next take begins.

Acceptance: each flow below gives the flag values listed in the test, and the old REC-after-start bug case is covered.

Tests: `testStartsIdle`, `testMeetingStartLiveStop`, `testRecordStartCountdownTakeStopWithSavingAfterStop`, `testStopWhileRecordStartIsPending`, `testFailedMeetingStart`, `testFailedRecordStart`, `testCancelledMeetingStartEitherOrderEndsIdle`, `testNormalFinishStillClears`, `testTakeDuringAMeeting`, `testLiveMeetingWithRollingTakeAfterStartTaskFinished`, `testRecordingCanContinueWhileStopping`, `testPauseAndResume`, `testRecorderStoppedItself`.
Commit: 91bbb33.
Status: built.

### R3. Flags stay `@Published` and change only on a real change

The eight flags remain `@Published private(set)` on the coordinator. `syncFlags` writes a flag only when its value differs from the phase, so Combine sinks, `.onChange(of:)` and view refresh see no spurious publishes.

Acceptance:
- Each flag is assigned inside an `if flag != phase.flag` guard.
- Existing sinks and `.onChange` handlers still fire on real changes (owner check below).

Tests: none in `SessionPhaseTests.swift` (the coordinator is not test-compiled). Covered by the full suite and Debug build, and the manual check.
Commit: 91bbb33.
Status: built.

### R4. Update gate counts a Record session between takes

The automatic update check does not run while a meeting is starting or live, a Record session is starting or up (including between takes), or a take is rolling or paused. Manual "Check for Updates" still works.

Acceptance: with a Record session up, its start task finished and no take rolling, `hasSessionOrTakeOnScreen` is true; with nothing running it is false.

Tests: `testSessionOrTakeOnScreenCountsRecordSessionBetweenTakes`.
Commit: cd13eb6.
Status: built.

### R5. A stale start finish no longer clears a newer start

Stop cancels the start task without waiting. The old task can end after Stop's teardown and after a new start began. Each start request increments `startID`; the finish event carries the id and a finish for an older id is ignored.

Acceptance:
- Meeting finish for an old start, after a new Record start, leaves `isRunning` true.
- Record finish for an old start, after a new Record start, leaves `isRunning` true.
- A finish with the current id still clears.

Tests: `testStaleMeetingFinishAfterNewRecordStartIsIgnored`, `testStaleRecordFinishAfterNewRecordStartIsIgnored`, `testNormalFinishStillClears`, `testCancelledMeetingStartEitherOrderEndsIdle`.
Commit: d3a1da1.
Status: built.

### R6. "In a meeting" is one named question

`isInMeeting` equals `isRunning || stageLive` in every reachable state. See open question 1.

Tests: `testInMeetingMatchesOldExpression`.
Commit: bc4bf9d.
Status: built.

### R7. "Camera / stage busy" is one named question

`sceneInUse` equals `stageLive || recordOnlyActive`. `isCameraBusy` equals `sceneInUse || isRunning` and equals the spelled-out `stageLive || recordOnlyActive || isRunning`.

Tests: `testCameraBusyMatchesBothOldSpellings`.
Commit: 5920aa9.
Status: built.

### R8. "Can start" is one named question

`canStart` equals `!isRunning && !sceneInUse && !isStopping`. The Start button's disabled state is its exact negation. The toggle-record variant (`!hasSessionOrTakeOnScreen`) equals `!isRunning && !sceneInUse && !isRecording`.

Tests: `testCanStartMatchesOldExpressions`.
Commit: dfe1bc2.
Status: built.

### R9. "Record mode" is one named question

`isRecordMode` equals `recordOnlyActive || startingRecordOnly`, and equals the older `recordOnlyActive || (isRunning && startingRecordOnly)`. It decides which Stop runs and which exit prompt shows.

Tests: `testRecordModeMatchesBothOldSpellings`.
Commit: bc85b77.
Status: built.

### R10. "Fully live" and "starting" are named questions

- `isMeetingFullyLive` equals `stageLive && !isRunning`.
- `isSceneFullyLive` equals `sceneInUse && !isRunning`.
- `isStarting` equals `isRunning && !stageLive` (true during a Record start too; see open question 1).

Tests: `testFullyLiveAndStartingMatchOldExpressions`.
Commit: f9a3967.
Status: built.

### R11. "Anything live" has three named questions

- `hasSessionOrTakeOnScreen` equals `isRunning || stageLive || isRecording || recordOnlyActive` (notes bar and update gate).
- `isSessionUp` equals `isRunning || stageLive || recordOnlyActive` (YouTube hand-off).
- `isLiveAndNotStopping` equals `!isStopping && (isRunning || sceneInUse || isRecording)` (End and Quit confirmations).
- `isSessionUp` and `hasSessionOrTakeOnScreen` differ in at least one reachable state (a take with no session), so they stay two names.

Tests: `testAnythingLiveVariantsMatchOldExpressions`, `testSessionOrTakeOnScreenCountsRecordSessionBetweenTakes`.
Commit: a59a100.
Status: built.

### R12. The last flag pairs are named questions

- `isRecordSessionSettled` equals `recordOnlyActive && !isRunning`.
- `isStartOrStopInFlight` equals `isRunning || isStopping`.
- `hasNoLiveMeetingOrTake` equals `!stageLive && !isRecording`.

Tests: `testRemainingQuestionsMatchOldExpressions`.
Commit: 00d72e2.
Status: built.

### R13. Questions are checked over every reachable state

The named-question tests run over all states found by breadth-first search over every event (finish events with the current and a stale `startID`), not over a few hand-picked flows.

Acceptance: the search finds more than 30 states and every question test passes on all of them.

Tests: `testReachableStatesAreEnumerated`, plus the question tests R6 to R12.
Commit: 00d72e2 (helper added with bc4bf9d).
Status: built.

### Verification state

Unit tests pass (912 tests) and the Debug build passes. Nothing is verified live: the owner has not yet tried it in the app. Moving any requirement to "verified live" waits on the manual check below.

## Open questions

1. The menu bar shows "Starting" for Record starts too. `isInMeeting` and `isStarting` count a Record start, because `isRunning` is true then. Kept to match old behaviour; decide whether it should say something else for Record.
2. `isSessionUp` (YouTube hand-off) and `hasSessionOrTakeOnScreen` differ when a take exists with no session. Decide whether the hand-off should also count a take.
3. The Combine sinks in `MenuBarStatusItem` and `SessionNotesBar`, and the `ShortcutRuntime` record guard, still read the raw flags rather than named questions.

## Manual check (owner)

Run the Debug build from DerivedData and try:

- [ ] Start a meeting; press REC, stop REC, then End Session. Home returns and nothing is left recording.
- [ ] Record mode: make a take and save it. The file appears and the session returns to idle.
- [ ] Cancel during a start, then start again. The second start goes live and stays live.
- [ ] Record during a meeting, then End Session immediately. Saving clears and Home returns.
- [ ] Pause and resume a take. The pause state shows and clears correctly, and the take saves.
