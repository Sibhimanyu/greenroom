#!/bin/bash
# Shared by scripts/render/*.sh. Off-screen renders: each script compiles the real
# App/ view sources (plus small stand-ins for coordinator- or AppKit-bound pieces)
# with one of swift/*-main.swift into a throwaway tool, which draws sample data into
# off-screen windows and writes PNGs. No app launch, no focus taken, App/ never edited.
#
#   NAME       set by the caller; default output is $TMPDIR/greenroom-render/$NAME
#   $1         output folder (optional)
#   RENDER_REF a git ref: render the committed App/ at that ref instead of the working
#              tree (immune to someone's half-done edits), e.g. RENDER_REF=HEAD
set -euo pipefail

RENDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RENDER_DIR/../.." && pwd)"
TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"
OUT="${1:-$TMP/greenroom-render/$NAME}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
STAGE="$TMP/greenroom-render-stage/$NAME"
rm -rf "$STAGE"; mkdir -p "$STAGE"; touch "$STAGE/.start"

cd "$ROOT"
if [ -n "${RENDER_REF:-}" ]; then
  mkdir -p "$STAGE/src"
  git archive "$RENDER_REF" App | tar -x -C "$STAGE/src"
  cd "$STAGE/src"
fi

# Brand without the asset catalog: the colorset's accent (#5FA83C) as a literal.
write_brand() {
  { echo "import SwiftUI"
    awk '/^enum Brand \{/{p=1} p{print} p&&/^}/{exit}' App/GreenroomApp.swift \
      | sed 's|Color("AccentColor")|Color(nsColor: NSColor(srgbRed: 0x5F/255, green: 0xA8/255, blue: 0x3C/255, alpha: 1))|'
  } > "$STAGE/Brand.swift"
}

# Settings -> Layouts and everything it pulls in. The tab struct (coordinator-bound)
# is cut out; LayoutPageContent is what renders. Sets LAYOUT_FILES.
stage_layouts() {
  write_brand
  local start end
  start=$(grep -n '^// MARK: - The tab' App/UI/LayoutSettingsTab.swift | cut -d: -f1)
  end=$(grep -n '^// MARK: - Icons' App/UI/LayoutSettingsTab.swift | cut -d: -f1)
  sed "${start},$((end-1))d" App/UI/LayoutSettingsTab.swift > "$STAGE/LayoutSettingsTab.swift"
  # PresenceBubble.swift is the floating panel (AppKit-heavy); the look group only needs the mirror key.
  printf 'enum PresenceFeed { static let mirrorKey = "camera.mirrorSelfView" }\n' > "$STAGE/PresenceStub.swift"
  # The meeting bar's pop-up menu is an AppKit bridge; a clear stand-in keeps the bar's layout.
  printf 'import SwiftUI\nstruct MenuPopUpOverlay: View { let label: String; let entries: () -> [MenuEntry]; var body: some View { Color.clear } }\n' > "$STAGE/PopStub.swift"
  LAYOUT_FILES="$STAGE/LayoutSettingsTab.swift $STAGE/Brand.swift $STAGE/PresenceStub.swift $STAGE/PopStub.swift
    $(ls App/UI/Layout*.swift | grep -v 'SettingsTab\|ChoiceMenu' | tr '\n' ' ')
    App/Layout/LayoutTemplate.swift App/Layout/LayoutBuiltIns.swift App/Layout/LayoutGeometry.swift App/Layout/LayoutCamera.swift
    App/Layout/LayoutEditorRules.swift App/Layout/LayoutEditHistory.swift App/Layout/LayoutDisplayCrossing.swift App/Layout/Visibility.swift
    App/Layout/DisplayResolver.swift App/Layout/AppCatalog.swift App/Layout/RoomScreenRules.swift App/Layout/EveryonePicture.swift
    App/UI/VisibilitySymbols.swift App/UI/VisibilityIcon.swift App/UI/MeetingTheme.swift
    App/UI/SettingsKit.swift App/UI/PreviewCameraDrag.swift App/UI/PreviewFrameRules.swift
    App/UI/Segmented.swift App/UI/GreenroomPopover.swift App/UI/Tiles.swift App/UI/Fields.swift App/UI/TileAppearance.swift
    App/UI/Glass.swift App/UI/PopoverPlacement.swift App/UI/SegmentedMath.swift App/UI/WebcamShapePreview.swift
    App/UI/CameraLookControls.swift App/UI/CameraInspector.swift App/UI/RoomScreenInspector.swift App/UI/CameraShapeTiles.swift App/UI/SharePopout.swift
    App/UI/ForThisMeetingLine.swift App/UI/MuteHintRules.swift App/UI/MenuPanelPlacement.swift App/UI/MeetingToolbarLayout.swift App/Layout/MeetingSetup.swift App/Layout/MeetingSetupLibrary.swift App/Layout/MeetingSetupLine.swift App/UI/HomeTilePanels.swift App/UI/HomeTilePanelRules.swift App/UI/HomeCalmRules.swift App/UI/DockHint.swift
    App/UI/MeetingBarContent.swift App/UI/MeetingBarModel.swift App/UI/MeetingMenuSpec.swift App/UI/StopVideoRules.swift
    App/ShareVisibilityRules.swift App/MeetingCollapseRules.swift App/ShortcutStore.swift App/ShortcutModel.swift App/LiveExitRules.swift
    App/Stage/CameraState.swift App/Stage/WebcamShape.swift App/Stage/ShareTargetModel.swift App/Stage/PresenceGeometry.swift
    App/Stage/CameraEffects.swift App/Stage/CameraBackgroundChoice.swift App/Stage/StageLayout.swift
    App/Stage/PresenceRecorderRules.swift App/Stage/MainPersonSelector.swift App/Stage/StageFrame.swift
    App/Zoom/MeetingShareRules.swift"
}

# The Home pop-outs (HomeTilePanels) and the shared pieces they use. Sets PANEL_FILES.
stage_panels() {
  write_brand
  PANEL_FILES="$STAGE/Brand.swift App/UI/HomeTilePanels.swift App/UI/HomeTilePanelRules.swift App/UI/HomeCalmRules.swift
    App/UI/Tiles.swift App/UI/TileAppearance.swift App/UI/SettingsKit.swift App/UI/VisibilitySymbols.swift App/UI/VisibilityIcon.swift
    App/UI/MeetingTheme.swift App/Stage/CameraState.swift App/UI/Glass.swift App/UI/Segmented.swift App/UI/SegmentedMath.swift"
}

# render <tool-name> <main.swift under swift/> <sources...>: compile, then run into $OUT.
# A compile failure stops the script (never runs a stale tool).
render() {
  local tool="$STAGE/$1" log="$STAGE/$1.log" main="$2"; shift 2
  # Top-level code compiles only in a file named main.swift.
  cp "$RENDER_DIR/swift/$main" "$STAGE/main.swift"
  if ! swiftc -Onone -suppress-warnings -module-name Render "$@" "$STAGE/main.swift" -o "$tool" >"$log" 2>&1; then
    grep -E "error" "$log" | sort -u | head -30
    echo "render: compiling $main failed (full log: $log)" >&2
    exit 1
  fi
  "$tool" "$OUT"
}

finish() {
  local n; n=$(find "$OUT" -maxdepth 1 -name '*.png' -newer "$STAGE/.start" | wc -l | tr -d ' ')
  echo "$NAME: $n PNGs written to $OUT"
  [ "$n" -gt 0 ] || { echo "render: no PNGs written" >&2; exit 1; }
}
