# TODOS

Open items, newest first. Each one says what is wrong, what is known, and
where to start.

## Participant panel and live speaker

- [x] **Speaker window names the wrong person.** Fixed: Zoom's events name
  the teacher whenever they talk, but its active-speaker view never draws
  them, so an event naming yourself is now ignored and the last student named
  keeps the caption (`ActiveVideoUserSignal.set`). **Verify in a real class.**
- [ ] **Verify in a real class:** the chat moves under the speaker window the
  moment it first appears (`showActiveSpeakerInColumn`), Snap Back with the
  speaker window open, and ⌥⌘Z hide/show.
- [ ] **Verify in a real class:** clicking outside the student drawer, or the
  same student again, closes it; clicking another student switches.
- [x] When the class drops below three and the speaker window closes, the
  quick-hide flag now goes back to hidden, so the rail offers Show Speaker
  instead of Hide Speaker for a window that no longer exists.

## Ending a class

- [ ] **Add the `meeting:update:status` scope** to the Zoom Server-to-Server
  app (Zoom Marketplace → the app → Scopes). Without it the REST backstop in
  `endMeetingForEveryone` and the pre-flight's stale-meeting cleanup both get
  Zoom error 4711 and do nothing. Account setting, not code.
- [ ] **Confirm End ends the meeting for everyone.** The SDK's end-for-all is
  sent, but `leaveMeeting` reports nothing back. Watch a student device after
  End; if they stay in, the backstop above is the only fix.

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
