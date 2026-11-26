#!/bin/bash
# The setup guide's YouTube step ("Share recordings on YouTube"), off screen, sample data (a made-up
# channel, no real keys): the two cards (Your YouTube account, After each recording), one open,
# and the Studio footnote, for: not signed in, signed in with Greenroom's Google app, your own
# Google app not set up (the deep link Settings' Set up... uses), and Upload automatically picked
# without the Made for Kids answer; light and dark. YouTubeGuideStep is what renders.
# Usage: scripts/render/youtube-guide.sh [outdir]   (default $TMPDIR/greenroom-render/youtube-guide)
NAME=youtube-guide; source "$(dirname "$0")/lib.sh"
write_brand
cut_out() { # cut_out <file> <first line's text> <text of the line after the last> -> stdout without that range
  local s e; s=$(grep -n "^$2" "$1" | head -1 | cut -d: -f1); e=$(grep -n "^$3" "$1" | head -1 | cut -d: -f1)
  [ -n "$s" ] && [ -n "$e" ] || { echo "render: $1 markers moved: '$2' / '$3'" >&2; exit 1; }
  sed "${s},$((e-1))d" "$1"
}
cut_out App/UI/YouTubeUploadSheet.swift '// MARK: - The sheet' '// MARK: - The content' > "$STAGE/YouTubeUploadSheet.swift"
{ echo "import SwiftUI"; awk '/^struct AdvancedDisclosure/{p=1} p{print} p&&/^}/{exit}' App/UI/ZoomSignInSection.swift; } > "$STAGE/AdvancedDisclosure.swift"
{ echo "import Foundation"
  awk '/^\/\/\/ The upload sheet.s starting values/{p=1} /^\/\/\/ An upload that did not go through/{exit} p{print}' App/YouTube/CoordinatorController+YouTube.swift
} > "$STAGE/YouTubeTypes.swift"
grep -q YouTubeUploadDraft "$STAGE/YouTubeTypes.swift" || { echo "render: YouTubeUploadDraft moved" >&2; exit 1; }
render youtube-guide-render youtube-guide-main.swift App/UI/YouTubeGuideStep.swift App/UI/YouTubeAccountViews.swift \
  "$STAGE/YouTubeUploadSheet.swift" "$STAGE/AdvancedDisclosure.swift" "$STAGE/YouTubeTypes.swift" "$STAGE/Brand.swift" \
  App/UI/SettingsKit.swift App/UI/Fields.swift App/UI/Segmented.swift App/UI/SegmentedMath.swift App/UI/Tiles.swift \
  App/UI/TileAppearance.swift App/UI/Glass.swift \
  App/YouTube/YouTubeAccountChoiceRules.swift App/YouTube/YouTubeGuideFlowRules.swift App/YouTube/YouTubeOAuth.swift \
  App/YouTube/YouTubeRouteRules.swift App/YouTube/YouTubeUploadRules.swift App/YouTube/YouTubeErrorRules.swift
finish
