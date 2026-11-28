# Shelved features

Features the owner has parked. The code stays, the way to use it does not ship. Each entry says what exists and how to test it so it can come back. Switches live in `App/Shelved.swift` (Foundation-only, tested by `Tests/ShelvedTests.swift`).

## Record the Mac's own sound

Shelved 2026-11-27 by the owner: "Let's not record system audio for now. Let's have that as a shelved feature which needs testing." Needs testing before it returns.

- S1. Release builds: no control anywhere, and recordings never include the Mac's sound, whatever an old stored value or an imported settings file says. Status: built.
- S2. Debug builds: the controls stay, captioned "(shelved, needs testing)". Status: built.
- S3. When shelved, the screen capture does not ask for audio (`captureSystemAudio` is false). Status: built.
- S4. The Settings file keeps carrying `recordSystemAudio` as before; a Release import never turns it on. Status: built.

What exists:

- `Shelved.macSound` (true in Debug, false in Release) and `Shelved.effectiveMacSound(stored:macSoundAvailable:)`.
- `CoordinatorController.recordSystemAudio` (the stored switch) and `recordsMacSound` (the effective value that the recorder and the capture read).
- The path itself: `StageScreenSource` (`captureAudio`), `SessionRecorder.appendSystemAudio`, `AudioMixer`.
- Controls (Debug only): Home, Mic tile popover, "Record the Mac's sound"; Settings, Devices, Recording.

How to test: build Debug, share a screen or app that plays sound (Home, Behind you), turn the switch on under Home, Mic (or Settings, Devices), record, and check the file has the shared app's sound mixed with the microphone and not Greenroom's own sound. To bring it back: make `Shelved.macSound` true in Release, drop the `#if DEBUG` around the controls, remove the caption, and update this file.
