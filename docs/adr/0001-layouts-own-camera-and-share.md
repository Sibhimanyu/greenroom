# Layouts own the camera piece and what's shared

A layout now holds the camera piece (spot, size, shape), the shared display and what's shared, so picking a layout sets up everything the meeting sees; the Webcam and Layout tabs merge into one Layouts tab, and camera devices, mic and recording options move to a Devices tab. Camera look (background, effects, mirror) stays global.

We chose this over keeping the camera and share as global settings because the owner switches between teaching set-ups whose camera and share differ, and two tabs that edited one picture kept contradicting each other ("Camera off" meaning two things, the browser missing from the share). The cost is a migration: today's global camera settings and share choice are copied into every existing layout, and Home's live controls change only the running meeting, never the saved layout.

Who sees each piece (on my screen, everyone) comes from one rule shared by the builder's badges, its Everyone preview and the real capture filter, so the builder cannot show a state the meeting does not get.

_Partly superseded by [ADR 0004](0004-before-a-meeting-home-edits-the-layout.md): before a meeting, Home now edits the active layout._
