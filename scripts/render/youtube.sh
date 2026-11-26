#!/bin/bash
# Settings -> YouTube and the upload sheet, off screen, sample data (a made-up channel, no real
# names or keys), light and dark. Settings: Greenroom's Google app not signed in / signed in /
# signing in / still a placeholder / sign-in failed; your own Google app not set up / set up and
# signed in / chosen while signed in through Greenroom's; automatic uploads without the Made for
# Kids answer. Sheet: signed in with the
# answer missing and given, not signed in, not available yet. The coordinator-fed tab and sheet
# structs and the Thriveni row are cut out; YouTubePageContent and YouTubeUploadSheetContent are
# what render.
# Usage: scripts/render/youtube.sh [outdir]   (default $TMPDIR/greenroom-render/youtube)
NAME=youtube; source "$(dirname "$0")/lib.sh"
write_brand
cut_out() { # cut_out <file> <first line's text> <text of the line after the last> -> stdout without that range
  local s e; s=$(grep -n "^$2" "$1" | head -1 | cut -d: -f1); e=$(grep -n "^$3" "$1" | head -1 | cut -d: -f1)
  [ -n "$s" ] && [ -n "$e" ] || { echo "render: $1 markers moved: '$2' / '$3'" >&2; exit 1; }
  sed "${s},$((e-1))d" "$1"
}
cut_out App/UI/YouTubeSettingsTab.swift '// MARK: - The tab' '// MARK: - The page' \
  | awk '/^\/\/ MARK: - Shared channel/{exit} {print}' > "$STAGE/YouTubeSettingsTab.swift"
cut_out App/UI/YouTubeUploadSheet.swift '// MARK: - The sheet' '// MARK: - The content' > "$STAGE/YouTubeUploadSheet.swift"
# The fold shared with Settings -> Zoom, alone (the rest of that file is Zoom's).
{ echo "import SwiftUI"; awk '/^struct AdvancedDisclosure/{p=1} p{print} p&&/^}/{exit}' App/UI/ZoomSignInSection.swift; } > "$STAGE/AdvancedDisclosure.swift"
grep -q AdvancedDisclosure "$STAGE/AdvancedDisclosure.swift" || { echo "render: AdvancedDisclosure moved" >&2; exit 1; }
# The mode enum and the draft, out of the coordinator extension.
{ echo "import Foundation"
  awk '/^enum YouTubeUploadMode/{p=1} /^\/\/\/ An upload that did not go through/{exit} p{print}' App/YouTube/CoordinatorController+YouTube.swift
} > "$STAGE/YouTubeTypes.swift"
render youtube-render youtube-main.swift "$STAGE/YouTubeSettingsTab.swift" "$STAGE/YouTubeUploadSheet.swift" \
  "$STAGE/AdvancedDisclosure.swift" "$STAGE/YouTubeTypes.swift" "$STAGE/Brand.swift" \
  App/UI/SettingsKit.swift App/UI/Segmented.swift App/UI/SegmentedMath.swift App/UI/Tiles.swift App/UI/TileAppearance.swift App/UI/Glass.swift \
  App/UI/YouTubeAccountViews.swift App/YouTube/YouTubeAccountChoiceRules.swift \
  App/YouTube/YouTubeOAuth.swift App/YouTube/YouTubeRouteRules.swift App/YouTube/YouTubeUploadRules.swift App/YouTube/YouTubeErrorRules.swift
finish
