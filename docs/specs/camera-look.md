# Camera look: one owner for background, removal and mirror

Branch: sibhimanyu/camera-look-module. Next piece named by [meeting-setup.md](meeting-setup.md) D7 ("The Look as one value is the next piece of work"). Style model: `App/Layout/MeetingSetup.swift`, `App/SessionPhase.swift`. This is a refactor: no behaviour changes.

## Terms (in GLOSSARY.md)

**Camera look** (reworded here), **Look** (the value that holds it).

## Problem

The camera look is one setting for every layout, but it has no owner. Survey of 831a4d9, 2026-11-28:

- Three values (`backgroundRemoval`, `cameraBackground`, `cameraBackgroundImage`) are three separate `@Published` properties on `CoordinatorController`. Each repeats the same `didSet` (write the key, skip if unchanged, `requestShapeApply()`), and `init` reads each key by hand.
- The fourth, Mirror my camera, is not on the coordinator at all. Two views each hold their own `@AppStorage` on the same key and the presence bubble reads the key on every frame.
- The settings file export and import each list the three by hand (`CoordinatorController+SettingsTransfer.swift`), with the "picture before mode" order and the "ignore a value we do not know" checks written inline.
- "Which look changes need the Stage" is a rule hidden in three `didSet`s. Mirror is the one that does not.

## What the Look is

The Look is four settings, the same in every layout and every meeting:

| Setting | Values | UserDefaults key | Needs the Stage |
| --- | --- | --- | --- |
| Background removal (for Cutout and Presenter) | Automatic, Green screen | `backgroundRemoval` | yes |
| Background (for the bubble shapes) | Normal, Blur, Image | `cameraBackground` | yes |
| Background picture (for Image) | a preset name or `custom-<stamp>` | `cameraBackgroundImage` | yes |
| Mirror my camera | on, off | `camera.mirrorSelfView` | no (the bubble reads it per frame) |

Not part of the Look (they stay where they are):

- **Camera devices** (`cameraDirectorSettings`: which cameras, switching, the cut style, `noCamera`). Devices, not looks.
- **Camera state, camera piece (spot, size, shape) and what's shared.** These are per layout and belong to the [Meeting setup](meeting-setup.md).
- **The webcam shape.** It is part of the camera piece, so per layout.
- **Framing.** There is no framing setting in the app today (survey: no key, no field). The camera director's cuts are device switching, not a look. If framing is added, it joins the Look.

## Decisions

- D1. One value type, `CameraLook`, owns the four settings. It is Foundation only and compiled by the test target.
- D2. The coordinator holds exactly one stored `CameraLook` (`@Published private(set) var look`). `backgroundRemoval`, `cameraBackground`, `cameraBackgroundImage` and `cameraMirror` become computed reads whose setters go through `setLook`, so views and `$coordinator.x` bindings keep working.
- D3. Persistence does not change. The same four keys, the same raw values, no migration. A key that is missing or holds a value we do not know reads as the default.
- D4. The Stage hears about a Look change from one place. The pure module says whether a change reaches the Stage; the coordinator calls `requestShapeApply()` only then.
- D5. The settings file keeps its field names. The module reads and writes them, so the coordinator extension has no look rules of its own.

## Requirements

**R1. One value owns the four settings.** (D1) built
- R1.1 `CameraLook` holds removal, background, background picture and mirror. A new `CameraLook()` is Automatic, Normal, `studio` (`CameraBackgroundPreset.defaultChoice`) and mirror on.
- R1.2 It is Equatable, so "did anything change" is one comparison.

**R2. It persists under the old keys.** (D3) built
- R2.1 `CameraLook.load(from:)` reads `backgroundRemoval`, `cameraBackground`, `cameraBackgroundImage` and `camera.mirrorSelfView`. Given a store with the keys of an old install, the look is what the old code read.
- R2.2 Given a missing key, or a value that is not one of the cases, that field is its default and the others still load.
- R2.3 `save(to:)` writes the same four keys with the same raw values (`automatic` / `greenScreen`, `Normal` / `Blur` / `Image`, the picture string, a Bool). A saved look loads back equal.
- R2.4 Mirror is stored as a Bool, so the presence bubble's per-frame read of the key and the settings file's bridge keep working untouched.

**R3. The Stage hears about the right changes.** (D4) built
- R3.1 `reachesStage(from:to:)` is true when removal, background or the background picture differ, and false when only mirror differs or nothing differs.
- R3.2 Given the coordinator sets a look equal to the one it holds, then nothing is written and the Stage is not told.
- R3.3 Given a look that reaches the Stage, when it is set, then `requestShapeApply()` runs once.
- R3.4 `makeStageConfiguration()` reads removal, background and picture from the Look. Mirror is not in `StageConfiguration` (the meeting's picture and the recordings never flip, `CameraLookRules.stageMirrors`).

**R4. The settings file goes through the module.** (D5) built
- R4.1 `exported` gives the strings the file carries for removal, background and picture, equal to what `SettingsTransfer` held before.
- R4.2 `importing(removal:background:picture:)` applies each field that is present and known, and leaves the others. A value that is not a known case is ignored. An absent field changes nothing.
- R4.3 The picture is applied with the mode as one result, so the Image mode never shows an empty picture (the order the old code enforced).
- R4.4 Mirror still travels as `mirrorSelfView` through `SettingsDefaultsBridge`. After an import the coordinator re-reads the Look from the store, so its copy matches the key.

**R5. No other copies.** (D2) built
- R5.1 `CoordinatorController` stores no look field other than `look`. The four old names are computed.
- R5.2 `LayoutSettingsTab` and `HomeCameraPanel` bind Mirror through the coordinator, not their own `@AppStorage`, so a change in either shows in the other at once.
- R5.3 Behaviour with the app is unchanged: every screen that read a look setting still reads the same value, and a change to background, picture or removal reaches the Stage as before.

## Phases

| Phase | Delivers | Status | Commit |
| --- | --- | --- | --- |
| P1 | The spec, the glossary and the index | built | bf5ccf4 |
| P2 | `CameraLook` and its tests: R1, R2, R3.1, R4.1 to R4.3 | built | 3b9c331 |
| P3 | Wire the coordinator, the import, export and the two mirror views: R3.2 to R3.4, R4.4, R5 | built | see git log |

## Needs a live check

Nothing new is expected to differ. Worth a glance in a real meeting: change the background (Blur, Image, a custom picture) and removal in Settings → Layouts and see the Stage follow; flip Mirror on Home and see it change in Layouts; export then import a settings file.
