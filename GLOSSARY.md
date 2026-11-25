# Glossary

Words this codebase uses on purpose. Code lives in `App/SessionPhase.swift`.

## Session

The time Greenroom has its picture up: the cameras, the screen capture and the
composited picture. A session is either a **meeting** (the picture goes to a
Zoom meeting) or a **record** session (no meeting, only a take being made).
It is in one of four states:

- **Idle**: nothing is up.
- **Starting**: the start task is running (building the picture, joining the
  meeting, or counting down in Record). The picture may already be up.
- **Live**: the start task has finished and the picture is up.
- **Stopping**: Stop was asked for and the teardown has not finished. What was
  underneath (a start still in flight, the picture) stays until it does.

## Take

One recording file, made while a session is up. It is **none**, **rolling**,
**paused** (the file is not growing; resuming carries on in the same file) or
**saving** (stopped, the file is still being closed). A take is not part of
the session's state: a meeting can run with no take, and **saving can outlive
the session** (End Session stops the tape and closes the file in the background).

## Settings file

The one JSON file Settings -> Transfer exports and imports (`App/Settings/`).
Each persisted setting either **travels** in it (export writes it, import
applies it), is **import-only** (an old file may carry it, nothing writes it),
or is **excluded** with a written reason (consent, tokens, window positions,
tips seen). `SettingsCatalog` lists them all; a test fails when a persisted key
is in none of the three. Import **sanitizes** first: anything invalid or not
available on this Mac (a microphone not plugged in, a custom background picture
that is a file on the other Mac) is dropped, and the person is told when it
matters.

## Questions about the phase

Callers ask `coordinator.phase.<question>` (a read-only value on `SessionPhase`)
instead of combining the eight flags by hand. The flags stay `@Published` for
`$` sinks and `.onChange(of:)`; a view that reads a question re-renders because
every change to a question is a change to a flag, and the coordinator is its
`@EnvironmentObject`. One line per question, in `SessionPhase.swift`:

- `isInMeeting`: `isRunning || stageLive`. True while a Record session is
  starting too (`isRunning`), false for a Record session between takes.
- `sceneInUse`: `stageLive || recordOnlyActive`, the picture is built (either kind).
- `isCameraBusy`: `sceneInUse || isRunning`, also written `stageLive ||
  recordOnlyActive || isRunning`. Nothing may take the camera or stage while true.
- `canStart`: `!isRunning && !sceneInUse && !isStopping`; Start (meeting or
  Record), the Record shortcut and `startActionDisabled` ask it. The
  toggle-recording check "nothing live, nothing starting" is the other variant:
  it ignores `isStopping` and counts a take, so it reads `!hasSessionOrTakeOnScreen`.
- `isRecordMode`: `recordOnlyActive || startingRecordOnly` (the old
  `recordOnlyActive || (isRunning && startingRecordOnly)` is the same value).
  Picks the Record stop over the meeting stop, and the Record exit prompt.
- `isMeetingFullyLive`: `stageLive && !isRunning`, a meeting's picture is up and
  its start task is done. `isSceneFullyLive` is the same for either kind
  (`sceneInUse && !isRunning`).
- `isStarting`: `isRunning && !stageLive`. True during a Record session's start
  too; the menu bar shows "Starting" for both.
- Anything live, in three honest forms (they differ):
  `hasSessionOrTakeOnScreen` (`isRunning || stageLive || recordOnlyActive ||
  isRecording`: Notes bar, automatic update gate), `isSessionUp` (the same
  without the take: the YouTube "session ended?" check, equal to `isCameraBusy`
  today), and `isLiveAndNotStopping` (the first, unless stopping: `hasLiveSession`,
  the End / Quit confirmations).
- `isRecordSessionSettled`: `recordOnlyActive && !isRunning`.
  `isStartOrStopInFlight`: `isRunning || isStopping` (Try again waits on it; Start
  warm-up skips while it is true). `hasNoLiveMeetingOrTake`: `!stageLive &&
  !isRecording` (Home's Record button is disabled with it, or while saving).

## Meeting surfaces

While a meeting is live, the controls are in exactly one place. Code:
`App/Meeting/MeetingSurface.swift` (the pure model), `MeetingSurfaceOwner.swift`
(the one value, the settle, the safety hooks). Spec: `docs/specs/meeting-surface.md`.

- **Meeting window**: the one titled Greenroom window that shows the meeting and
  carries its own controls (`ParticipantGridWindowController`).
- **Bar**: the floating control bar (`MeetingControlBarController`) that holds
  all the controls when the Meeting window is not up. It can fold to a puck; that
  is not a surface change.
- **Surface**: one of those two. A live meeting always has exactly one that is
  the answer to "where are the controls" (`MeetingSurface.surface`), never none.
  Both are on screen only during a settle or a morph.
- **Settle**: the 0.5 s wait after a cover or desktop change before the surface
  switches. A new change while it waits starts the wait again.
- **Morph**: the shrink or expand animation between Meeting window and Bar.
