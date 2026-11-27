#!/bin/bash
# The setup guide's Zoom step ("Connect Zoom"), off screen, sample data (no real names or keys):
# the import shortcut, the three numbered parts (Meeting app, Hosting app, Check) with only the
# current one open, Sign in with Zoom as a quiet Coming soon row, and the footer's note, for:
# nothing filled in, part 1 done, parts 1 and 2 done, all done and checked, and a check with
# failures (missing scopes, so the Hosting app opens with the missing marks), and the Zoom window's
# part: no app ID known, IDs known with the current step marked, "Filled in from Zoom", and the offer
# to use the page's keys; light and dark.
# ZoomGuideStep is what renders; the coordinator-fed check rows are cut out of ZoomCheckPanel.swift.
# Usage: scripts/render/zoom-guide.sh [outdir]   (default $TMPDIR/greenroom-render/zoom-guide)
NAME=zoom-guide; source "$(dirname "$0")/lib.sh"
write_brand
awk '/^extension ZoomSignInSection \{/{skip=1} skip&&/^}/{skip=0; next} !skip' App/UI/ZoomSignInSection.swift > "$STAGE/ZoomSignInSection.swift"
awk '/^struct (ZoomSignInCheckRow|ZoomSetupCheckRow): View \{/{skip=1} skip&&/^}/{skip=0; next} !skip' App/UI/ZoomCheckPanel.swift > "$STAGE/ZoomCheckPanel.swift"
printf 'import SwiftUI\nstruct ZoomSignInCheckRow: View { var body: some View { EmptyView() } }\n' > "$STAGE/CheckRowStub.swift"
render zoom-guide-render zoom-guide-main.swift App/UI/ZoomGuideStep.swift App/UI/ZoomScopeChecklist.swift \
  "$STAGE/ZoomSignInSection.swift" "$STAGE/ZoomCheckPanel.swift" "$STAGE/CheckRowStub.swift" "$STAGE/Brand.swift" \
  App/UI/SettingsKit.swift App/UI/Fields.swift App/UI/Glass.swift App/UI/Tiles.swift App/UI/TileAppearance.swift \
  App/Zoom/ZoomScopes.swift App/Zoom/ZoomMarketplaceGuide.swift App/Zoom/ZoomUserAuthRules.swift \
  App/Zoom/ZoomRouteRules.swift App/Zoom/ZoomRouteChoiceRules.swift App/Zoom/ZoomSignInAvailability.swift \
  App/Zoom/ZoomGuideFlowRules.swift App/Zoom/ZoomGuideFollowRules.swift App/Zoom/ZoomMarketplacePages.swift App/Zoom/ZoomSetupCheckRules.swift App/Zoom/ZoomCheckActionRules.swift \
  App/Zoom/ZoomPersonalRoom.swift App/Zoom/ZoomServerToServerClient.swift App/Zoom/NewMeetingRequest.swift
finish
