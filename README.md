# Greenroom

Screen capture + green-screen-keyed webcam, composited into one feed and
published system-wide as a virtual camera ("Greenroom Camera") — pick it in
Zoom, Meet, Teams, QuickTime, or any app with a camera picker, and whoever
you're talking to sees your whole screen with you keyed into a bubble in the
corner.

## Status

Everything below is written and **typechecks cleanly** against the macOS SDK
(verified with `swiftc -typecheck` in this environment), but **has not been
built or run** — this environment only has Xcode's Command Line Tools, not
full Xcode, and building an app + System Extension target needs the real
thing. Treat this as a strong first draft: open it in Xcode, fix whatever
Xcode's fuller diagnostics turn up (there will likely be a few small things -
see "What to expect on first build" below), and tell me what breaks.

What's implemented:
- Chroma-key webcam capture (`ChromaKeyFilter`, `WebcamCaptureManager`) with
  live key-color/threshold/smoothing controls
- Full-screen capture via ScreenCaptureKit (`ScreenCaptureManager`)
- Compositor: screen as background + keyed webcam in a fixed circular bubble
  (`Compositor`)
- A working camera extension (`CameraExtensionProvider.swift`) with both a
  **source** stream (what other apps read) and a **sink** stream (what this
  app writes into) — CoreMediaIO relays sink → source itself, so there's no
  custom XPC bridge to maintain
- The host-side low-level CoreMediaIO client code that actually writes into
  that sink (`CameraSinkWriter.swift`) — this is the single most
  under-documented part of the whole project; it's adapted from a verified
  working reference implementation, not written from guesswork
- System Extension activation (`SystemExtensionManager.swift`)
- A 3-pane debug UI (screen / keyed webcam / final composite) with the
  controls above

Not yet done (see "Next" at the bottom):
- Draggable/resizable bubble (position is fixed via `Compositor.BubbleLayout`)
- Audio (mic passthrough, system audio)
- Recording to disk / streaming
- App icon, proper packaging for distribution

## One-time setup

1. **Install full Xcode** (not just Command Line Tools) from the App Store,
   then point the command line at it:
   ```
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   ```
2. **Install xcodegen** (generates the `.xcodeproj` from `project.yml` — this
   repo doesn't check in the generated project file itself):
   ```
   brew install xcodegen
   ```
3. **Edit `project.yml`**: set `settings.base.DEVELOPMENT_TEAM` to your Apple
   Developer Team ID (developer.apple.com → Membership, or Xcode → Settings →
   Accounts). Do this in `project.yml`, not in Xcode's Signing & Capabilities
   UI — re-running `xcodegen generate` overwrites project settings from this
   file, so any change made only in Xcode's UI will get silently discarded.
   Also change `bundleIdPrefix` / the two `PRODUCT_BUNDLE_IDENTIFIER` values
   if you want your own reverse-DNS domain instead of `com.sibhimanyu.greenroom`.
4. **Generate and open the project:**
   ```
   xcodegen generate
   open Greenroom.xcodeproj
   ```
5. Select the **Greenroom** scheme and Run.

## First run

- macOS will prompt for **Camera** and **Screen Recording** permission the
  first time each is used — grant both.
- The app calls `systemExtension.activate()` on launch automatically, but
  macOS still requires one manual click: **System Settings → Privacy &
  Security → Allow** for the Greenroom extension. This is an OS-level gate
  with no programmatic bypass.
- Once approved, open **QuickTime Player → File → New Movie Recording**,
  click the camera dropdown next to the record button, and pick **Greenroom
  Camera**. You should see your composited feed.
- If the extension doesn't show up as a camera: quit and relaunch Greenroom
  (this retries the CoreMediaIO connection in `CameraSinkWriter.connect()`),
  and as a last resort, reboot — CMIOExtension registration has known cases
  where it only picks up cleanly after a reboot, which is a macOS quirk, not
  a sign anything here is wrong.

## What to expect on first build

I derived `CameraExtensionProvider.swift`, the entitlements, and the
`Info.plist` keys from a verified working open-source reference project
rather than from memory, specifically because this is the area most prone to
silent, undebuggable failures (wrong entitlement → extension just doesn't
load, no error). The typecheck pass confirms the Swift compiles; it can't
confirm runtime behavior like extension registration, code signing, or the
CMIODeviceStartStream handshake actually succeeding on your machine. If
something doesn't work, the most useful things to send back are:
- Console.app output filtered to "Greenroom" or "CameraExtension"
- Whether the extension shows up at all in `systemextensionsctl list`
- Any Xcode build errors verbatim

## Meeting SDK chat (separate window)

A standalone chat window (`App/UI/ChatWindow.swift`) that joins your Zoom
meeting as a **second, camera/mic-off participant** purely to get
programmatic chat access, via Zoom's native Meeting SDK
(`App/Zoom/ZoomMeetingSDKClient.swift`, `ZoomChatBridge.swift`,
`ZoomMeetingSDKJWT.swift`). This is deliberately not accessibility/UI
scripting on the native Zoom app - it's a real second SDK connection into
the meeting, so you'll show up twice in the participant list (once from the
native Zoom app, once as "Greenroom Chat" or whatever display name is set).

**Status: builds and launches clean.** `Vendor/ZoomSDK/` now holds the real
downloaded SDK (7.1.5.84750, ~80 frameworks/dylibs/bundles/helper apps),
copied in directly rather than via the Marketplace docs' incomplete
6-dylib list. `xcodebuild` succeeds, and the built app launches and quits
with no dyld errors in the unified log - meaning every one of those ~80
embedded binaries resolves and gets signed correctly under Hardened
Runtime. All the Swift code was rewritten at least once against the real
headers after the compiler caught several wrong guesses (the singleton is
`ZoomSDK.shared()` not `.sharedSDK()`, chat lives on
`ZoomSDKMeetingChatController` not `ZoomSDKMeetingActionController`, the
mute flags are `isNoVideo`/`isNoAudio` not `isVideoOff`/`isAudioOff`, etc.
- see git blame / the file headers for specifics if something still looks
off).

**Confirmed by an actual live test:** joining works, but only for meetings
hosted under the SAME Zoom account as this app's Marketplace credentials.
Joining a meeting hosted elsewhere fails with
`ZoomSDKMeetingError_UnableToJoinExternalMeeting` (63) - Zoom requires the
Marketplace app to be published to lift that, and per Zoom's own dev
forum, publishing doesn't even reliably fix it (one developer reported it
still failing post-publish). Decided not to chase that path - **this
feature is scoped to meetings you host yourself.** Sending/receiving chat
itself hasn't been exercised yet since every join attempt so far has hit
this account restriction first.

## Project layout

```
project.yml                      xcodegen spec - source of truth for the .xcodeproj
Shared/CameraConstants.swift      constants both targets need (compiled into both)
App/                              main app target
  GreenroomApp.swift               SwiftUI entry point
  PipelineController.swift         orchestrates capture -> composite -> camera sink
  Capture/WebcamCaptureManager.swift
  Capture/ScreenCaptureManager.swift
  Compositing/ChromaKeyFilter.swift
  Compositing/Compositor.swift
  Camera/SystemExtensionManager.swift
  Camera/CameraSinkWriter.swift    the low-level CoreMediaIO client code
  UI/ContentView.swift
  UI/CIImagePreview.swift
  Info.plist / App.entitlements
CameraExtension/                   system extension target
  main.swift
  CameraExtensionProvider.swift    device + source stream + sink stream
  Info.plist / CameraExtension.entitlements
```

## Giving this to one other person (no paid Developer Program)

(Rewritten after the OBS pivot - the old version of this section described
the retired System-Extension design, whose `systemextensionsctl developer on`
+ reboot steps no longer apply to anything. None of that is needed now.)

What to send: **`Greenroom.app`** plus **one settings file** you export from
Settings (⌘,) → Transfer → *Export Settings…*. That file carries the Zoom
app credentials and preferences - the recipient never touches the Zoom
Marketplace. (The credentials are app-level and shareable by design; the
export is plaintext, so hand it over directly and have them delete it after
importing.)

One caveat: "Start New Meeting" on their machine creates meetings hosted
under *your* Zoom account (the S2S credentials in the settings file are
account-level), and free accounts can only host one meeting at a time -
so you can't both start separate meetings simultaneously.

On the recipient's Mac: **copy `Greenroom.app` into `/Applications`,
right-click → Open → confirm once** (the app isn't notarized; this is the
standard Gatekeeper bypass - no Terminal needed). First launch opens a
built-in setup guide that walks through everything else - installing
OBS/Zoom (with live detection), importing the settings file, and every
permission prompt macOS will show. The guide is reopenable anytime from
the main window's **?** button.

Chat-window note: it works in meetings hosted under the credential-owning
Zoom account - which is exactly the meetings "Start New Meeting" creates,
so for shared morning meetings both machines' chat windows work. Meetings
hosted under other Zoom accounts are off-limits (confirmed error 63 - see
`Vendor/README.md`, including why the OAuth/OBF fix for this was
deliberately abandoned).

## Next

1. Get it building/running in real Xcode, fix whatever comes up
2. Draggable/resizable bubble position in the UI
3. Distribution: Developer ID signing + notarization (System Extensions
   can't ship via the Mac App Store)
4. Audio, recording, streaming - only if you want to take this past the MVP
