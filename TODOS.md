# TODOS

Open items, newest first. Each one says what is wrong, what is known, and
where to start.

## Participant panel and live speaker

- [ ] **Speaker window names the wrong person.** The name bar and title read
  "Sibhimanyu V (you) · host" while the window shows a student's camera. The
  name comes from `onActiveVideoUserChanged` / `onActiveSpeakerVideoUserChanged`
  (`App/Zoom/ActiveVideoUserSignal.swift`), which disagree with the picture
  `ZoomSDKActiveVideoElement` actually draws. Start by logging both events
  next to `dataTypeChanged user=1` in `~/Library/Logs/Greenroom-video.log`,
  and consider hiding the host from the caption (the teacher is never who
  this window is for).
- [ ] **Verify in a real class:** the chat moves under the speaker window the
  moment it first appears (`showActiveSpeakerInColumn`), Snap Back with the
  speaker window open, and ⌥⌘Z hide/show.
- [ ] **Verify in a real class:** clicking outside the student drawer, or the
  same student again, closes it; clicking another student switches.
- [ ] When the class drops below three and the speaker window closes, the
  quick-hide flag stays false, so the rail can offer "Hide Speaker" with no
  window behind it.

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
