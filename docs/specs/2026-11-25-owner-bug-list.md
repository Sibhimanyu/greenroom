# Owner's bug list, 2026-11-25

The owner sent a list of eight problems on 2026-11-25 (R1 to R8). The same
session then fixed five more things (R9 to R13). Each item below has the
decision the owner made, the acceptance criteria, the commit, and its status.
Statuses follow [the spec rules](README.md#status).

Some of these were later reshaped by the Layouts builder
([layouts-builder.md](layouts-builder.md)). Where that happened, the item
says so; the later spec wins.

**Summary:** 13 requirements. All 13 are built. None is verified live: no
commit on this branch records a check in a real meeting.

| R | Item | Commit | Status |
| --- | --- | --- | --- |
| R1 | Raj San Mode is editable | 02169d9 | built |
| R2 | Built-in layouts use the Active speaker view | 02169d9, a7e3082 | built |
| R3 | The camera can start hidden on my screen | 02169d9, then f9fe057 | built |
| R4 | Room screen piece | 02169d9, a7e3082 | built |
| R5 | "Show my camera" is about my screen only | 02169d9, then f9fe057 | built |
| R6 | Layout pieces default to Everyone sees this | 02169d9 | built |
| R7 | Home can turn the camera on | 02169d9, then f5d4b97, f9fe057 | built |
| R8 | Annotations whiteboard stays local | 02169d9, a7e3082 | built |
| R9 | One home for "What everyone sees" in the menus | 7c3359b | built |
| R10 | Greenroom Browser is always in the share | a7e3082 | built |
| R11 | Zoom Marketplace guides in Settings | a7e3082 | built |
| R12 | Smaller recordings, same crash safety | 494a79b | built |
| R13 | Screenroom's WAV stays WAV | 494a79b | built |

## R1. Raj San Mode is editable

The default Raj San Mode layout was locked. It does not need to be.

- R1.1 Raj San Mode can be moved, resized and changed in Settings like any layout.
- R1.2 No lock banner or lock guard remains for Raj San Mode.
- R1.3 Reset to defaults still brings back the shipped Raj San Mode.

Commit 02169d9. Status: built.

## R2. Built-in layouts use the Active speaker view

In the built-in layouts, the meeting was the Meeting window tile. It should be
the Active speaker view.

Decision: Raj San Mode's two-display version keeps the full-display Meeting
window on its second display. When views can't open, the Meeting window falls
back into the Active speaker's spot.

- R2.1 On one display, each built-in layout places the Active speaker view, not
  the Meeting window.
- R2.2 Raj San Mode's second display still holds the Meeting window filling that
  display.
- R2.3 Given views can't open (including custom UI falling back while the
  meeting runs), the Meeting window takes the Active speaker's spot.
- R2.4 The fallback checks the whole layout version, not one piece.

Commits 02169d9, a7e3082 (fallback checks the whole version, re-resolves at
runtime). Status: built.

## R3. The camera can start hidden on my screen

The owner wants to hide the camera window (the camera bubble) by default when
setting up a layout, and show it later from the control bar.

Decision: this was first misread as the Self view, and a Self view bar button
was removed. The fix that stays: Self view "Starts hidden" hides only the Self
view, not the whole meeting.

- R3.1 A layout can say the camera starts hidden on the owner's screen.
- R3.2 During the meeting, the bar's camera button shows or hides it.
- R3.3 Self view "Starts hidden" hides only the Self view.

Later: the Layouts builder replaced the switch with the four-way camera state
(layouts-builder R6, f9fe057). "Only everyone" is this case.

Commits 02169d9, f9fe057. Status: built.

## R4. Room screen piece

People in the room watch a big screen behind the owner. They need a piece for
the second (extended) display that shows what everyone sees, with private
Greenroom windows left out. It must be quick, not laggy.

- R4.1 Room screen is a layout piece that can be placed on the second display.
- R4.2 It shows what everyone sees, live.
- R4.3 Private Greenroom windows are left out of it.
- R4.4 It ignores the layout's hide for itself (it is never hidden from its own
  display).
- R4.5 It is low latency. (No number was set; this needs a live check.)

Commits 02169d9 (`RoomScreenWindow`, `RoomScreenRules`), a7e3082 (ignores the
layout hide). Tests: `RoomScreenTests`. Status: built. Not checked on a real
extended display.

## R5. "Show my camera" is about my screen only

The layout said "Camera off", which read as "the meeting can't see me".

Decision: the layout's camera switch is local only. The layout builder
arranges the owner's own screen. The meeting still sees the owner.

- R5.1 The switch reads "Show my camera on my screen".
- R5.2 Turning it off hides the camera window on the owner's screen only. The
  meeting's picture still has the camera.

Later: replaced by the four-way camera state (layouts-builder R6, f9fe057),
which states both halves.

Commits 02169d9, f9fe057. Status: built.

## R6. Layout pieces default to Everyone sees this

Anything in a layout should be visible to everyone by default, not hidden.
The amber "Everyone sees this" edge and label are removed everywhere.

Decision: the owner approved a one-time flip of existing saved layouts to
visible. Windows are shown to everyone by default only when a layout is in
use. With no layout, they default to hidden.

- R6.1 A piece added to a layout is shown to everyone.
- R6.2 On first launch after the update, saved layouts are flipped to visible
  once. A second launch changes nothing.
- R6.3 With no layout in use, Greenroom windows are hidden from everyone.
- R6.4 No window shows the amber share edge, label or its one-time explainer.

Note: the Layouts builder's 📡 badge stays amber when on (layouts-builder Q11).
That is a badge in the editor, not the edge on real windows.

Commit 02169d9. Tests: `LayoutMigrationTests`, `ShareVisibilityRulesTests`.
Status: built.

## R7. Home can turn the camera on

When the camera was off in Settings, Home's camera tile was disabled. Home is
a control surface, so it must be able to turn the camera on. The same goes for
"Just me" (approved).

- R7.1 Given the camera is off in Settings, the Home camera tile is enabled.
- R7.2 Choosing a camera there turns the camera on.
- R7.3 Choosing "Just me" turns the camera on.
- R7.4 Later (f9fe057): the Home camera tile is a choice row with the four
  camera states, and a change there applies to the running meeting only.

Commits 02169d9, then f5d4b97 (Home deep links follow the Devices tab) and
f9fe057 (four-way choice row). Tests: `HomeTilePanelRulesTests`. Status: built.

## R8. Annotations whiteboard stays local

During a meeting, opening a whiteboard from Annotations presented it to
everyone. It should be a plain white window the owner can drag around, and
nothing the meeting sees changes. Share > Whiteboard is how to present it.

- R8.1 Annotations > Whiteboard opens a white window on the owner's screen and
  leaves what's shared unchanged.
- R8.2 Share > Whiteboard still presents the whiteboard to everyone.
- R8.3 Whiteboard "Back to screen" returns to the share that was there before.
- R8.4 Closing the local whiteboard always turns drawing back on.
- R8.5 The local whiteboard follows its 👁.
- R8.6 Decision changed 2026-11-25: the Annotations whiteboard opens visible to
  everyone. Its eye starts on (amber, "Everyone sees this"), so a Whole screen
  share shows it at once. This is the one exception to "Greenroom's own windows
  start hidden". The owner can turn the eye off and that holds while the window
  is open; each new opening starts visible again. Opening it still never changes
  what is shared. The rule lives in `ShareableWindow.startsShown`.

Commits 02169d9, a7e3082 (R8.3 to R8.5). Tests: `WhiteboardOpenRulesTests` (R8.6 included).
Status: built (R8.6 added 2026-11-25).

## R9. One home for "What everyone sees" in the menus

The Meeting menu's "Share a display" submenu repeated the Share button's What
everyone sees, Look and Layout items.

Decision: "What everyone sees" lives on the bar's Share button only. The
Meeting menu keeps the Zoom-only items.

- R9.1 The Meeting menu's submenu is called "Sharing".
- R9.2 It holds only: share a display on its own, who can share, and when
  someone is sharing.
- R9.3 It has no What everyone sees, Look or Layout items.
- R9.4 When the "When someone is sharing" rows are grey, a note says why: "Only
  while "All participants" can share".

Commit 7c3359b. Tests: `MeetingToolbarTests`. Status: built.

## R10. Greenroom Browser is always in the share

The Greenroom Browser had no 👁 switch and was left out of a whole-display share
since "Show on my share" landed.

Decision: the browser is always in everyone's picture. Its 📡 is fixed on.

- R10.1 In a whole-display share, the Greenroom Browser is in the stream.
- R10.2 It is in the Room screen and in recordings.
- R10.3 The builder shows its 📡 as fixed on, never as a switch.

Commit a7e3082 (`ShareVisibilityRules.alwaysShared`). Later, f5d4b97 made it
the browser's fixed-on answer in the one rule (layouts-builder R1). Tests:
`ShareVisibilityRulesTests`, `ShareVisibilityTruthTests`. Status: built.

## R11. Zoom Marketplace guides in Settings

People setting up their own Zoom apps didn't know where to get the keys.

- R11.1 Settings > Zoom shows a link, "Open Zoom App Marketplace", under each
  own-app block.
- R11.2 Each block has a "Show the step-by-step guide" with the steps for that
  app: Meeting SDK (General App) and Server-to-Server OAuth.
- R11.3 The menu names in the steps match the setup guide's Zoom step.

Commit a7e3082 (`ZoomMarketplaceGuide`). Tests: `ZoomMarketplaceGuideTests`.
Status: built.

## R12. Smaller recordings, same crash safety

A busy 1080p recording was about 45 MB a minute at 6 Mbps.

Decision: lower the average, cap the peak, and keep the 2 s fragments that make
a recording survive a crash.

- R12.1 At 1080p, the H.264 average bitrate is 3.5 Mbps.
- R12.2 The peak is 1.7 times the average (DataRateLimits): 6 Mbps at 1080p, never more than about 20.6 Mbps. The average stops at 12 Mbps (4K).
- R12.3 Other sizes scale by pixel count, with a 1 Mbps floor and at most 4x
  the 1080p rate.
- R12.4 Audio is AAC at 128 kbps.
- R12.5 Keyframes and fragments both stay at 2 s.
- R12.6 Given the app is killed with `kill -9` during a recording, the file
  plays back up to the last fragment.

Result: a `kill -9` harness on synthetic frames recovered 18.05 s of a 20 s
recording, video and audio. This was not a real meeting recording.

Commit 494a79b (`StageEncoderRules`). Tests: `StageEncoderRulesTests`.
Status: built.

## R13. Screenroom's WAV stays WAV

The recording size work asked whether Screenroom's WAV should also shrink.

Decision: no. Screenroom's WAV is a temporary input for whisper, rebuilt from
the recording when analysis runs. It is not kept, so its size doesn't matter,
and the whisper tool reads plain 16-bit WAV, so a compressed file would only
need converting back.

- R13.1 Screenroom still writes WAV for whisper.
- R13.2 The kept recording is the only file whose size changed.

Commit 494a79b (decision recorded in its message). Status: built (no change
needed).

## R14. Only Only-me's camera bubble is hidden from other apps' captures

Decision 2026-11-25. Screenshots, QuickTime, Loom, Zoom's own share and OBS may see every
Greenroom window except the camera bubble while the camera state is Only me.

- R14.1 The Room screen is visible to other apps' captures (default sharingType).
- R14.2 The Room screen stays out of Greenroom's own capture, so it never films itself.
- R14.3 The setup guide is visible to other apps' captures; it is not a `WindowKind`.
- R14.4 Every secret (Zoom SDK and Server-to-Server Client Secret, YouTube Client Secret) is a
  `SecureField`, dotted while typed and displayed; pasting works. Client IDs and Account IDs stay readable.
- R14.6 The "Show Greenroom on screen in other apps' recordings" switch is removed (decided 2026-11-25).
  Every Greenroom window is always `.readOnly`; only the camera bubble in Only me is `.none`. The bubble
  feeds at its real pixel size (max 1920, no cheap cap) and keeps the 0.5 s chrome fade.
  The old recordings-switch key is ignored. Mirror is kept (owner, 2026-11-25): "Mirror my camera" is back in
  the Camera look and Home, flips only the bubble on the owner's screen, never the Stage, recordings or Room
  screen (layouts-builder R11.4).
- R14.5 No secret is logged. If a reveal control is ever added: a text "Show" / "Hide" button (never
  the eye), re-masking after about 10 s and when the window loses focus.

Tests: PresenceRecorderRulesTests, RoomScreenTests, ShareVisibilityRulesTests.

## Verified live

Nothing yet. To move an item on, check it in a real Zoom meeting and record the
date here. The ones that most need it: R4 (Room screen speed on a real
extended display), R10 (browser in the stream), R12 (a real recording killed
mid-meeting).
