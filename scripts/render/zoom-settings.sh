#!/bin/bash
# Settings -> Zoom, off screen, sample data (no real names or keys): the choice between your own
# Zoom apps and Sign in with Zoom (Coming soon), the own-apps summary (status, check, one
# "Set up…" / "Edit setup…" button) for no own apps, half set up, ready, and someone signed in
# before with and without own apps; the open sign-in (switch off); plus the check button row and
# results panels, with failures and their buttons; light and dark. The tab struct,
# the coordinator-fed `live` helper and the two coordinator-fed check rows are cut out (stand-ins
# draw the same shared ZoomCheckButtonRow); ZoomPageContent and its pieces are what render.
# Usage: scripts/render/zoom-settings.sh [outdir]   (default $TMPDIR/greenroom-render/zoom-settings)
NAME=zoom-settings; source "$(dirname "$0")/lib.sh"
write_brand
cut_out() { # cut_out <file> <first line's text> <text of the line after the last> -> stdout without that range
  local s e; s=$(grep -n "^$2" "$1" | head -1 | cut -d: -f1); e=$(grep -n "^$3" "$1" | head -1 | cut -d: -f1)
  [ -n "$s" ] && [ -n "$e" ] || { echo "render: $1 markers moved: '$2' / '$3'" >&2; exit 1; }
  sed "${s},$((e-1))d" "$1"
}
cut_out App/UI/ZoomSettingsTab.swift '// MARK: - The tab' '// MARK: - The page' > "$STAGE/ZoomSettingsTab.swift"
awk '/^extension ZoomSignInSection \{/{skip=1} skip&&/^}/{skip=0; next} !skip' App/UI/ZoomSignInSection.swift > "$STAGE/ZoomSignInSection.swift"
# The check rows are fed by ZoomSignInChecker / ZoomSetupChecker (network, the SDK): cut out;
# stand-ins keep the types and draw the same shared button row with sample lines.
awk '/^struct (ZoomSignInCheckRow|ZoomSetupCheckRow): View \{/{skip=1} skip&&/^}/{skip=0; next} !skip' App/UI/ZoomCheckPanel.swift > "$STAGE/ZoomCheckPanel.swift"
cat > "$STAGE/CheckRowStub.swift" <<'SWIFT'
import SwiftUI
struct ZoomSignInCheckRow: View {
    var lines: [ZoomCheckLine] = []
    var body: some View { ZoomCheckButtonRow(title: ZoomRouteCheck.signIn.title, lines: lines, isRunning: false, onCheck: {}, onView: {}) }
}
struct ZoomSetupCheckRow: View {
    var lines: [ZoomCheckLine] = []
    var body: some View { ZoomCheckButtonRow(title: ZoomRouteCheck.setup.title, lines: lines, isRunning: false, onCheck: {}, onView: {}) }
}
SWIFT
printf 'enum SessionNotes { static let enabledKey = "sessionNotesEnabled" }\nenum CoordinatorController { static let copyInviteOnStartKey = "copyInviteOnStart" }\n' > "$STAGE/Stub.swift"
render zoom-settings-render zoom-settings-main.swift "$STAGE/ZoomSettingsTab.swift" "$STAGE/ZoomSignInSection.swift" \
  "$STAGE/Brand.swift" "$STAGE/Stub.swift" App/UI/SettingsKit.swift App/UI/Segmented.swift App/UI/SegmentedMath.swift App/UI/Tiles.swift App/UI/TileAppearance.swift App/UI/Glass.swift App/Zoom/ZoomScopes.swift App/Zoom/ZoomMarketplaceGuide.swift \
  App/Zoom/ZoomUserAuthRules.swift App/Zoom/ZoomRouteRules.swift App/Zoom/ZoomRouteChoiceRules.swift App/Zoom/ZoomSignInAvailability.swift App/Zoom/ZoomGuideFlowRules.swift App/Zoom/ZoomSetupCheckRules.swift App/Zoom/ZoomCheckActionRules.swift \
  "$STAGE/ZoomCheckPanel.swift" "$STAGE/CheckRowStub.swift"
finish
