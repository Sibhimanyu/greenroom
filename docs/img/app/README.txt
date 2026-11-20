Real app screenshots of today's Greenroom: a Debug build of origin/main (83550f0) in a scratch worktree, light appearance, PNG, max 1600px wide.
Captured from inside the app (ScreenCaptureKit, per window), background launch, no clicks, no keystrokes, no focus taken.
The app was inactive, so the window buttons (top left) are grey.

How it was staged (scratch build only; none of this is in the repo):
- Isolated: separate preferences domain, separate Documents/Greenroom (a scratch home), separate keychain service. The owner's prefs, sessions, Zoom sign-in and camera were never read or used.
- Camera: a staged presenter (a generated stock-style person, not the owner) composited onto a drawn room. No real camera was opened.
- Screen: a made-up lesson slide ("How leaves make food"). The real screen was never captured.
- Zoom: a sample signed-in state ("Alex Rivera", alex.rivera@example.com). No token, no meeting was started.
- Sessions: five made-up lessons. Video = generated slide + the staged presenter bubble; voice = macOS `say`; transcript, word timings, facing-the-room samples and feedback written for the sample.
- Start sequence, control bar and End confirm: the real views with sample values (18 people, host). No meeting ran.

File                          What it shows
home.png                      Home, ready to start, Start Meeting, live preview of the sample slide with the presenter bubble
look-01..04.png               Home preview as the look changes: Circle, Rounded, Cutout, Presenter
home-panel-look.png           Home with the Look panel open (panel shown in a popover-shaped window: the content is the app's own view, the popover outline is drawn by the capture build)
home-panel-camera.png         Home with the Camera panel open (same note as above)
start-01..03-island.png       The island during start: steps 1/5, 3/5, 5/5
start-04-island-live.png      The island once live
start-05-control-bar.png      The live control bar (its Liquid Glass captures as flat grey, with no desktop behind it)
start-06-end-confirm.png      End pressed: "End the meeting for everyone?" with Keep going / End for everyone
sessions.png                  Sessions page with five sample cards
session-watch.png             A session's Watch page
editor.png                    The editor with the filmstrip
report-facing-pacing.png      Get feedback report: Facing the room and the Pacing gauge open
report-fillers.png            Get feedback report: Filler words open, rows for the other measures
settings-webcam/layout/shortcuts/cues/transfer.png   Settings tabs (Webcam preview shows the sample slide and presenter)

checked: every PNG was looked at. No owner camera, screen, name, email, Zoom IDs, YouTube client ID or Account tab.
