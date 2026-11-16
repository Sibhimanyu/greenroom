# TODOS

Open items, newest first. Each one says what is wrong, what is known, and
where to start.

## Built 2026-11-16, not yet tried live

Tried in a solo meeting on 2026-11-16: the Mini window shows your picture
with no overlay; the People pop-out opens on this desktop, lists you, and
closes when the window comes back; the island opens to the whole message on
the notched screen; a window recording's outline sits just above the Finder
window it outlines. Still to try:

- [ ] **Mini window:** the "Video didn't start" overlay still appears when
  video really does not start.
- [ ] **People pop-out, with real people:** rows update as people join and
  leave; Admit and Mute all work from it; a row opens the meeting window on
  that person.
- [ ] **Island failure, opened:** on a plain screen (the rounded card); the
  taller island does not block clicks just below it while it shows.
- [ ] **Share outline stacking:** another window dragged over the shared one
  hides the outline too; a whole-display share keeps it over everything.
- [ ] **Black stage, with a real second person:** someone who joins with their
  camera off and turns it on later shows on the stage; the video log has
  "camera came on after the subscription; asking again".
- [ ] **Meeting window on another desktop:** Expand, Chat and People on the
  bar, and a click on the island's "waiting to join" notice, switch to the
  window's desktop (a full-screen browser too) and open the right panel;
  Greenroom's main window does not come up over the slides.
- [ ] **Meeting window polish (811606c):** at the smallest window size the
  toolbar shows Mute and End whole; End reads "End Meeting for All"; the
  close, caret, pager, Admit/Deny, Invite, Mute All and Copy buttons
  highlight under the pointer; the People panel has one waiting list; the
  line beside the side panel runs top to bottom. Look too at where that line
  meets the top bar and toolbar, and at a camera-off tile's name shown twice.

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
