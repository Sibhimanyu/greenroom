# Remove Zoom's own window mode

Branch: sibhimanyu/hi. Restore point: git tag `zoom-own-window-mode-last` (the last commit that still has the mode). Code: `App/CoordinatorController.swift`, `App/Zoom/ZoomMeetingSDKClient.swift`, `App/UI/ZoomSettingsTab.swift`, `App/Settings/*`. Terms: `GLOSSARY.md` (Meeting window).

## Problem

Settings > Zoom had "Use Zoom's own meeting window" (the `customUIMode` setting, inverted). Off, Greenroom initialised the Zoom SDK with its default UI, then found Zoom's own meeting windows and parked, pinned and defended them (about 740 lines in the coordinator, 21 `didUseCustomUI` branches). That path was experimental, off by default since 2026-11-11, and the source of the tug-of-war between Greenroom and the SDK over window positions. `migrateCustomUIDefault()` already flipped every Mac to custom UI once.

## Decision

Owner, 2026-11-25: delete the mode. Greenroom's own meeting window is the only way a meeting is shown. To restore the old mode, check out tag `zoom-own-window-mode-last`.

## Non-goals

- No change to how the SDK is configured for custom UI.
- No deletion of stored values: an old `customUIMode` default stays on disk, unread.

## Requirements

### R1. The SDK always starts in custom UI

`initSDK` always sets `needCustomizedUI = true`. Nothing reads the `customUIMode` default; `didUseCustomUI` and `customUIModeEnabled` no longer exist.

Acceptance: `grep -rn "didUseCustomUI\|customUIModeEnabled" App` finds nothing.
Status: pending.

### R2. No Settings toggle

Settings > Zoom has no "Use Zoom's own meeting window" row, no relaunch note. The Layout pages no longer say "Zoom window" or "Needs Greenroom's meeting UI".

Acceptance: the Zoom page shows sign-in, credentials and display name only; `ZoomPageContent` takes no `customUI` binding.
Status: pending.

### R3. Old files still import

A settings export that has `customUIMode` (true or false) decodes and imports without error and changes nothing. The field is retired: decoded, ignored, never written.

Acceptance: test `testRetiredCustomUIModeImportsAsNothing` imports a file with `customUIMode: false`; the catalog guard test stays green with a written reason.
Status: pending.

### R4. Zoom-window code is gone

The coordinator no longer finds, parks, pins or demotes SDK windows (`parkBuiltInMeetingWindow`, the people-view placer, stray-window demotion, tile candidates, drift logging) and the layout engine has no path for "Zoom's own window".

Acceptance: build and full test suite pass; nothing remains that is reachable only when custom UI is off.
Status: pending.

### R5. Layout pieces and the analytics key

A Meeting piece is always "Meeting window"; the view pieces (Active speaker and so on) never show "Needs Greenroom's window". The `custom_ui` analytics dimension stops being sent.

Status: pending.

## What users with the mode off will see

They get Greenroom's meeting window, with the same layout and settings as everyone else (all Macs were flipped to it once already). The toggle is gone. Their old export files still import.

## Manual check (owner)

- Start a meeting: the Greenroom meeting window (or the control bar while alone) appears; no Zoom window opens.
- Settings > Zoom has no custom-UI toggle.
- Import an old settings export with `customUIMode` false: it imports without an error and nothing changes.
- Layout page: the Meeting piece reads "Meeting window"; view pieces have no "Needs Greenroom's window" badge.
- Start with a layout that has a Meeting piece: the window lands in its slot; Hide/Show meeting still works.
