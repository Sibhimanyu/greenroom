# Dead ends while a meeting or recording is live

Rule: while a class is live, nothing may leave the teacher with a running session and no window to get back to it, and nothing may end it without a question. Zoom's own app is the model. Decisions live in `App/LiveExitRules.swift` (pure, unit-tested in `Tests/LiveExitRulesTests.swift`).

| Window | What closing does now | Path back | Fix |
|---|---|---|---|
| Meeting window (red button, Command-W) | Was: closed silently, class kept running. Now: a sheet on the window. Host: End Meeting for All / Shrink to Control Bar / Cancel. Participant: Leave Meeting / Shrink / Cancel. "Recording will stop and be saved." is added while recording. Cancel is the default and Escape. | Control bar; Dock click; Show Greenroom; menu bar live header | Sheet (`ParticipantGridWindowController.confirmClose`, `ControlPanel.performClose`). Nothing live: closes as before. |
| Meeting window (yellow, Command-M) | Shrinks to the Mini window, or straight to the control bar when the layout already shows the faces (a speaker view or a Meeting slot) or the bar was the last size chosen (2026-11-14; was: always the bar) | Control bar's expand button; Dock click | None needed. |
| Quit (Command-Q, app menu, menu bar, Dock) | Was: one "Quit Greenroom" alert. Now: End Meeting & Quit (host), Leave & Quit (participant), Stop Recording & Quit (a recording), each with Cancel as default. Logout, shutdown and restart skip the question and end cleanly, saving the recording. | n/a | `applicationShouldTerminate` reads the quit Apple event's reason. |
| Control bar | Borderless, no close button; cannot be closed | Shows only when neither the Meeting window nor the Mini is up, so exactly one control surface is on screen while live. Installed for every live meeting except layouts that use Zoom's own window. In a layout, a placed full-size Meeting collapses to the Mini and its neighbour takes the room; a Meeting slot goes straight to the bar. | None needed. |
| Mini window (320x180, floating) | Closes into nothing: the bar fills in. Closed automatically when the Meeting window opens. Excluded from Hide together. | Bar's Meeting button (Option-click opens the window), Dock click, Show Greenroom | `MeetingSurfaces` (pure, tested). |
| Chat window (arranged layouts) | Closes; the meeting goes on | Meeting window / bar Chat and Views entries | None needed; unverified in a real meeting. |
| Participants panel | A side panel inside the meeting window, so closing the window is covered by the sheet | Meeting window | Covered by the meeting-window fix. |
| Meeting view windows (Gallery, Active speaker, Hands up...) | Close or move; the meeting goes on | Views menu on the control bar and the meeting window | None needed. |
| Drawing toolbar and canvas | Borderless panels with Done; no close button | Menu bar "Draw on the Screen", Draw shortcut, control bar Draw | None needed. |
| Whiteboard window | Closes; drawing mode ends, the class goes on | Draw on the control bar, menu bar or shortcut | None needed. |
| Floating recording bar | Borderless, no close button. Carries timer, Pause, Draw, Notes and Stop | Menu bar Stop Recording and Show Notes, Dock click | None needed. |
| Main Greenroom window | Closes; the class goes on | Dock click, Show Greenroom, menu bar live header. It reopens on Home, which shows the live state (End Session and Record drawn only while live). | Dock click while live brings the meeting forward instead (`applicationShouldHandleReopen`). |
| Main Greenroom window | Hidden (ordered out, not closed) when a session goes live: a meeting joined with the readiness card done, or a Record take running. Never hidden while getting ready, so a failed start leaves it in place. Frame remembered. | Dock click, Show Greenroom and the menu bar live header bring back the meeting window, control bar or recording bar, not this window. On purpose: menu bar "Open Greenroom Window", Sessions..., Last: ..., Settings... (own window); it then stays until the next session. On End, Leave, Stop recording, host-ended or dropped meeting, or a failure: back at its frame on Home, ordered front without activating (a full-screen app keeps focus). A deliberate quit does not reshow it. | `App/MainWindowVisibility.swift` (pure, `Tests/MainWindowVisibilityTests.swift`); coordinator `reconcileMainWindow`. |
| Browser window (a shared page) | Closes or minimises; the class goes on | Same sharing controls as before | None needed. |
| Record start (no studio screen) | Home's Start Recording, the Start or stop recording shortcut (idle) and the menu bar run one flow: the picture, the island countdown (Off/3/5/10), the tape. The main window stays visible until the tape rolls, then steps aside. Esc or Cancel on the island, or Stop on Home while it starts, puts the picture away and Home is as it was. | Cancel: Home, unchanged. Failure: the island keeps the message with Try again and Close; the main window stays or comes back; nothing keeps running. | `CoordinatorController.startRecordingFlow`; pure order in `App/RecordStartFlow.swift` (`Tests/RecordStartFlowTests.swift`). |
| Recording stops (bar Stop, shortcut, menu) | The file is saved, the picture is torn down, Home returns (MainWindowVisibility), the upload prompt appears on the island. | Home's footer "Last session ... Open", Sessions. | The old Record screen had no post-take actions of its own; nothing was lost. Notes moved to the recording bar. |

## Getting back

`LiveExit.reopenTarget` decides. Dock click, Show Greenroom and the menu bar's "Live" header all use it:

- Live custom-UI meeting with the Mini up: the Mini comes forward.
- Live custom-UI meeting, window hidden, minimised or shrunk: the control bar comes forward, or whichever of window, Mini and bar exists if the bar was never installed (`MeetingSurfaces.wayBack`).
- Live custom-UI meeting otherwise: the meeting window comes forward (reopened if it was closed) and takes key.
- A recording, or nothing live: the main window, which shows the live state.

These are deliberate clicks, so the app activates. Nothing here runs on its own.

## Needs a real meeting to verify

The sheet on a non-activating panel, the Dock click while shrunk, and the logout path (the quit event's reason code) were not driven here.

The hidden main window, its ways back and the failure rule are in the Main Greenroom window rows above. Not driven here: the hide and restore in a real class and a real take, a full-screen app keeping focus on restore, and the host-ended path.
