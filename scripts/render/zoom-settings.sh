#!/bin/bash
# Settings -> Zoom, off screen, sample data (no real names or keys): the "Start uses" line for
# each route, the refused-account note, the sign-in check's button row and results panel;
# each route (signed in, your own Zoom apps, both set up either way, nothing set up), light
# and dark. The tab struct and the coordinator-fed `live` helpers are cut out; ZoomPageContent
# and its pieces are what render.
# Usage: scripts/render/zoom-settings.sh [outdir]   (default $TMPDIR/greenroom-render/zoom-settings)
NAME=zoom-settings; source "$(dirname "$0")/lib.sh"
write_brand
cut_out() { # cut_out <file> <first line's text> <text of the line after the last> -> stdout without that range
  local s e; s=$(grep -n "^$2" "$1" | head -1 | cut -d: -f1); e=$(grep -n "^$3" "$1" | head -1 | cut -d: -f1)
  [ -n "$s" ] && [ -n "$e" ] || { echo "render: $1 markers moved: '$2' / '$3'" >&2; exit 1; }
  sed "${s},$((e-1))d" "$1"
}
cut_out App/UI/ZoomSettingsTab.swift '// MARK: - The tab' '// MARK: - The page' \
  | awk '/^extension ZoomRouteRow \{/{skip=1} skip&&/^}/{skip=0; next} !skip' > "$STAGE/ZoomSettingsTab.swift"
awk '/^extension ZoomSignInSection \{/{skip=1} skip&&/^}/{skip=0; next} !skip' App/UI/ZoomSignInSection.swift > "$STAGE/ZoomSignInSection.swift"
# The sign-in check row is fed by ZoomSignInChecker (ZoomUserAuth, network): cut out, a stand-in keeps the type.
awk '/^struct ZoomSignInCheckRow: View \{/{skip=1} skip&&/^}/{skip=0; next} !skip' App/UI/ZoomCheckPanel.swift > "$STAGE/ZoomCheckPanel.swift"
printf 'import SwiftUI\nstruct ZoomSignInCheckRow: View { var body: some View { EmptyView() } }\n' > "$STAGE/CheckRowStub.swift"
printf 'enum SessionNotes { static let enabledKey = "sessionNotesEnabled" }\nenum CoordinatorController { static let copyInviteOnStartKey = "copyInviteOnStart" }\n' > "$STAGE/Stub.swift"
render zoom-settings-render zoom-settings-main.swift "$STAGE/ZoomSettingsTab.swift" "$STAGE/ZoomSignInSection.swift" \
  "$STAGE/Brand.swift" "$STAGE/Stub.swift" App/UI/SettingsKit.swift App/UI/Tiles.swift App/UI/TileAppearance.swift App/UI/Glass.swift App/Zoom/ZoomScopes.swift App/Zoom/ZoomMarketplaceGuide.swift \
  App/Zoom/ZoomUserAuthRules.swift App/Zoom/ZoomRouteRules.swift App/Zoom/ZoomSetupCheckRules.swift \
  "$STAGE/ZoomCheckPanel.swift" "$STAGE/CheckRowStub.swift"
finish
