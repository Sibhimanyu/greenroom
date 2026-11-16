# TODOS

Open items, newest first. Each one says what is wrong, what is known, and
where to start.

## Built 2026-11-16, not yet tried live

- [ ] **Mini window, camera already on:** opens with your picture and no
  "Video didn't start in this window" overlay (fc5a3bf, `viewVideoWaiting`
  now asks `getDataType()`). Also check the overlay still appears when video
  really does not start.
- [ ] **People pop-out** (af2fa0d): the bar's People count opens the small
  Participants window beside the bar; its rows update while the meeting
  window is folded; Admit and Mute all work from it; a row opens the meeting
  window on that person; it folds into the window's People panel when the
  window comes back.
- [ ] **Island failure, opened** (b9d0f53): the chevron opens the full
  message, on a notched Mac and on a plain screen (the rounded card); check
  the taller island does not block clicks just below it while it shows.
- [ ] **Share outline stacking** (d3e9c45): the preview and recording
  outlines sit just above the shared window, so another window on top of it
  hides the outline too; a whole-display share keeps it over everything.

## Participant panel and live speaker

- [ ] **Verify in a real class:** the speaker window's name bar shows the
  student who is talking, never "(you) · host" (`ActiveVideoUserSignal.set`).
- [ ] **Verify in a real class:** the chat moves under the speaker window the
  moment it first appears (`showActiveSpeakerInColumn`), Snap Back with the
  speaker window open, and ⌥⌘Z hide/show.
- [ ] **Verify in a real class:** clicking outside the student drawer, or the
  same student again, closes it; clicking another student switches.

## Ending a class

- [ ] **Confirm End ends the meeting for everyone.** The SDK's end-for-all is
  sent, but `leaveMeeting` reports nothing back. Watch a student device after
  End. The scope for the web backstop (`meeting:update:status:admin`) was
  added on 2026-09-28, so the session log's `End: REST end meeting` line
  should now read `HTTP 204 ended` (or `code=3001`, already over), not 4711.

## Cameras

- [ ] **Verify the dead-camera fallback live:** unplug the secondary camera
  while it is live; the main camera should take over within a second and the
  status log should say so.

## Video, in case it comes back

- [ ] The blank-tile fix (re-subscribe once a tile is on screen) is confirmed
  in one class. If a tile goes blank again, check the video log for a tile
  line with no "re-subscribed now that its tile is on screen" after it.
- [ ] Code-7 "requests came too quickly" still fires on the first request of
  most tiles at class start. Harmless now, but the start-up burst could be
  spread out (and the speaker window started a second after the grid).
