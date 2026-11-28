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
  is not a surface change. A meeting starts on the Bar unless its layout places
  a Meeting window piece.
- **Surface**: one of those two. A live meeting always has exactly one that is
  the answer to "where are the controls" (`MeetingSurface.surface`), never none.
  Both are on screen only during a settle or a morph.
- **Settle**: the 0.5 s wait after a cover or desktop change before the surface
  switches. A new change while it waits starts the wait again.
- **Morph**: the shrink or expand animation between Meeting window and Bar.

## Personal room

The Zoom account's own fixed meeting room: its Personal Meeting ID (PMI) and
personal link, always the same. Say **personal room** in code and UI ("Your
personal room"), never "PMI" in UI text. Code: `App/Zoom/ZoomPersonalRoom.swift`.

- It is read from `GET /users/me` (`pmi`, `personal_meeting_url`), because Zoom's
  scheduled-meetings list never includes it. Own apps need `user:read:user:admin`;
  the sign-in's `user:read:user` already covers it.
- Home's My Meetings list pins it first (**Scheduled entry**: the personal room or
  one scheduled meeting, `ScheduledEntry`). It starts like any scheduled meeting:
  its number with a fresh host key. It is never edited or deleted from Greenroom.
- No scope or no PMI means no entry, never an error on Home.

## Zoom window

Greenroom's own window onto Zoom App Marketplace, opened large and centred on the
setup guide's screen by "Set up for me" or "Guide me instead" (`App/UI/ZoomMarketplaceWindow.swift`). It keeps
the Zoom sign-in in Greenroom, apart from Safari ("Sign out of Zoom" clears it).
A bar at its top (the **Greenroom bar**, `ZoomBarView`) says "Step n of 8 · title" and shows the step's one button, or the Set up for me line with Stop.
The **coach** draws a dim layer, a ringed spotlight and a one-line card on Zoom's page. It
only draws what the current step says. Greenroom clicks on Zoom's pages only through a plan
the person started (see **Plan**). Say **Zoom window**, not "browser".
Specs: `docs/specs/zoom-setup-flow.md` (current), `docs/specs/zoom-setup-assist.md` (what Zoom's pages taught us).

## Zoom setup

One flow sets up the two Zoom apps Greenroom needs. Code: `App/Zoom/ZoomSetupFlow.swift` and its
neighbours. Spec: `docs/specs/zoom-setup-flow.md`. Decision: `docs/adr/0003-one-setup-flow.md`.

- **Set up for me**: the main button of the Connect Zoom step. Greenroom does the steps itself,
  one after another (`SetupForMe.run()`), after one small form (name, email, company, and per app
  "Use my existing app" or "Build a new one"). The bar shows the step and a **Stop** button the whole time.
  "Guide me instead" is the fallback: the same steps, one press each. The guided "Do this step"
  is one turn (`advance()`) of the same loop, so both use the same steps, plans and safety.
- **Step** (`SetupStep`): everything a surface shows about where setup stands: number (of 8),
  title, why, where, a status line and exactly one call to action. The guide, the bar and the coach
  only render it. It is the first step of the fixed table whose evidence is missing
  (`ZoomSetupFlow.step(for:)`). Sign-in and the final check have no number.
- **Call to action** (`CallToAction`): the one thing a step asks for: take me there (`goTo`), do this
  step (`doThisStep`), the person presses a control (`press`), the person types (`fill`), wait,
  check again, back to Greenroom. There is no way to write a step with none.
- **Evidence** (`Evidence`): what Greenroom has seen proved about the person's apps (an app's ID, Meeting SDK on,
  Information filled, scopes present, activated, when keys were copied). It only grows, unless a page
  or the check shows it is no longer true. It has a logical clock (`lastChange`, `keysAt`): keys copied
  before the app's last change count as stale, and a check older than a change is ignored.
- **Plan** (`ActionPlan`): the list of presses, typings and verified waits for one step, naming
  controls by `ZoomControl` ID, never by label. `ZoomActor.run(plan)` is the only thing that acts on Zoom's pages.
  Its allow-list is the plan's own controls minus the person's (sign-in, passkey, closing someone else's
  window); the **deny-list** (regenerate, delete, remove, deactivate, disable, submit, publish, agree,
  accept, terms, sign out, log out, uninstall) is checked on the element's text at press time and always wins.
  A plan's `unless` condition skips a press when the page already shows the right state, so Greenroom never
  toggles what is already right.
- **ZoomPage seam**: what the flow needs from a Zoom page, as four verbs (`ZoomPage`: `read`,
  `perform`, `takeCopiedKey`, `draw`). Two adapters: `ZoomMarketplaceWindow` (the real WKWebView) and
  `FixturePage` (a scripted Zoom in tests).
- **FixturePage** (`Tests/FixturePage.swift`): a small hand-written model of Marketplace that behaves the way the
  live run showed Zoom behaving. It answers `ZoomPage` so Set up for me can be tested from a fresh account to done.
- **Hand over**: Greenroom stops doing steps and the guided step takes the person from there, saying where
  it stopped and why. It happens on sign-in, a control only the person can press, a plan that stops, a
  check Greenroom cannot run, or a step that still fails after 3 tries. Not the same as **Stop**
  (the person's button): Stop also hands over, after the current action.
- **Blocker**: a step with nothing Greenroom can do, because Zoom itself says no. The one today: the hosting
  app's Information fields are all disabled, so the Zoom account may not edit it. The step then says to ask the
  Zoom admin for "Server-to-Server OAuth app: Edit" and offers Check again.
- **Keys copied last**: each app's keys are copied only after the app's settings are done, because Zoom can change
  the keys when settings change. The secret arrives through the window's copy hook (in memory), never the clipboard.

## Layouts

**Layout**: a main-display arrangement, plus optionally a second-display arrangement used only when that display is connected: where each window goes and where the owner's camera sits. What the owner arranges is what everyone in the meeting sees, except windows hidden from everyone. The camera is the one piece that can be in everyone's picture without being on the owner's screen. Exactly one layout is active at a time.

**Piece**: one thing placed in a layout: an app, the Meeting window, Chat, a meeting view, the Room screen, or the camera.

**Camera piece**: the owner's camera as a piece. Its spot, size and shape belong to the layout it sits in.

**Camera state**: who sees the owner's camera, saved per layout, one of four: *Everyone & me*, *Only the meeting* (hidden on the owner's screen), *Only me* (a mirror; the meeting does not see the owner), *Off*. The same four everywhere in the app. *Off* takes only the camera out of the picture: everyone still gets the shared screen. Each state's one line (`CameraState.detail`, the camera menus and tooltips) says first what the meeting gets: "The meeting gets your screen and your camera" for the two "on" states, "The meeting gets your screen without your camera" for *Only me* (with the mirror) and *Off*. _Avoid_: calling Off "stop video".

**Stop video**: Zoom's own full video off for the owner, like Zoom's button: nothing is sent to the meeting, not even the screen, and everyone sees the owner's name or avatar. Not a camera state and not *Off*: the camera state stays as it was and comes back with *Start video*. The local stage, the recording and the Room screen keep going. Shown by Zoom's red, filled video.slash. Zoom's own state is the truth, so a stop by a co-host or by Zoom shows too.

**Camera look**: the owner's background (Normal, Blur or a picture), background removal for Cutout and Presenter, and Mirror my camera. One camera look for all layouts. Not the camera devices, and not the camera piece (spot, size, shape), which is per layout.

**Look**: the one value that holds the camera look (`CameraLook`). The coordinator keeps one; every screen reads it and every change goes through it (docs/specs/camera-look.md).

**Built-in layout**: a layout Greenroom ships with. Three, in this order: Leave my windows alone (the default active one), Raj San Mode and Room + laptop (owner decision, 2026-11-26). Teach from a browser, Talk to the meeting and Present are not built in any more; on an install that had them they are the owner's own layouts. Editable like any other; Reset brings the originals back.

**Leave my windows alone**: the built-in layout that does not move the owner's windows and only places the camera. Replaces "None".

**Everyone sees**: what the meeting gets: the shared display (or window, or whiteboard) with hidden windows left out. "Hidden" here means hidden from everyone, not from the owner. Shown everywhere in the app by the eye (open: everyone sees it; struck: only you); the eye means nothing else. Greenroom's own windows start hidden, except the Annotations whiteboard, which opens visible to everyone.

**Starts hidden**: a window placed by a layout that does not appear on the owner's screen at Start (an app opens minimised). Shown by a dashed outline, never by the eye.

**Shared display**: the display a layout gives to everyone (Main unless the layout says otherwise). Each layout has its own.

**Restore original**: puts one built-in layout back as Greenroom shipped it, leaving every other layout alone. _Avoid_: reset (that brings back every built-in at once).

**Room screen**: a piece for a second display that people in the room watch. It shows what everyone sees.

**Show my camera** (Room screen): whether the owner's own webcam is drawn on the Room screen. On by default. Off, the room sees what everyone sees without the owner's camera. Saved per layout.

**Layouts tab**: the one place to build layouts, camera included. Replaces the separate Webcam and Layout tabs.

**Camera device**: the physical camera (and second camera, auto-switching) the owner uses. Chosen on Home or in the Devices tab, never per layout.

**Devices tab**: the Settings tab for camera devices, the microphone and recording options. It holds nothing about where things go.

**What's shared**: what a layout gives everyone: the screen, an app, a window, the whiteboard, or nothing (just the camera). Saved per layout; a change on Home during a meeting is for this meeting.

**Meeting setup**: the active layout's camera state, camera piece and what's shared, each with its saved value and any for-this-meeting change. What every screen reads and every change goes through.

**Saved**: a setting's value as kept across launches: in the active layout (camera state, camera piece, what's shared) or for the whole app. Before a meeting, every place that changes it, Home included, changes the saved value, and Home names the layout it changes. _Avoid_: default, global (when it lives in a layout).

**For this meeting**: a change made while a meeting is live that sets a value for the rest of that meeting only and leaves the saved value alone. It ends when the meeting ends. Every place that shows the setting shows the value in use, and a place that edits the saved value says when a for-this-meeting change is in effect. _Avoid_: override, live value, temporary setting.

## YouTube

Code lives in `App/YouTube/`.

**Sign in with Google**: the one way to connect a YouTube channel from Greenroom. Any Google account, chosen in Google's account chooser in the browser. _Avoid_: Connect Google account, Disconnect (say **Sign out**).

**Greenroom's Google app**: the one shared Google OAuth client every copy of Greenroom signs in through (`YouTubeOAuth.sharedClient`). Unverified by Google on purpose, so Google warns "Google hasn't verified this app" and allows 100 people in total.

**Your own Google app**: a Google Cloud OAuth client (Desktop app) the person made and pasted into Settings -> YouTube, for when Greenroom's Google app is full. Which of the two signs in is `YouTubeRouteRules`.

**Upload sheet**: the sheet where a recording is sent to YouTube: title, description, visibility, **Made for kids**, YouTube's terms line, and the Upload button. Every upload from Greenroom starts here, except Upload automatically.

**Made for kids**: YouTube's audience question, Yes or No, asked before every upload from the sheet and needed for Upload automatically. Sent as `status.selfDeclaredMadeForKids`.

**Upload in YouTube Studio**: the way that needs no sign-in. Opens YouTube's upload page, shows the recording in Finder and copies the title and description. _Avoid_: manual upload, fallback (in UI text).
