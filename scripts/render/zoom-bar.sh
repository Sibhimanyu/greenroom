#!/bin/bash
# The Greenroom bar at the top of the Zoom window (docs/specs/zoom-setup-assist.md, R13), off screen, in its
# states (scopes step with Copy scopes and "Copied", a part set up with Next, both done with Back to Greenroom,
# signed out with Sign in, and the widest case) at 900pt (the window's minimum) and 1400pt; light and dark.
# Usage: scripts/render/zoom-bar.sh [outdir]   (default $TMPDIR/greenroom-render/zoom-bar)
NAME=zoom-bar; source "$(dirname "$0")/lib.sh"
write_brand
render zoom-bar-render zoom-bar-main.swift "$STAGE/Brand.swift" App/UI/ZoomBarView.swift \
  App/Zoom/ZoomBarRules.swift App/Zoom/ZoomRunRules.swift App/Zoom/ZoomActorRules.swift App/Zoom/ZoomCoachRules.swift App/Zoom/ZoomSignInStateRules.swift App/Zoom/ZoomMarketplacePages.swift App/Zoom/ZoomGuideFollowRules.swift \
  App/Zoom/ZoomGuideFlowRules.swift App/Zoom/ZoomSetupCheckRules.swift App/Zoom/ZoomCheckActionRules.swift App/Zoom/ZoomMarketplaceGuide.swift \
  App/Zoom/ZoomStartOverRules.swift App/Zoom/ZoomScopes.swift App/Zoom/ZoomUserAuthRules.swift App/Zoom/ZoomRouteRules.swift \
  App/Zoom/ZoomRouteChoiceRules.swift App/Zoom/ZoomSignInAvailability.swift App/Zoom/ZoomPersonalRoom.swift \
  App/Zoom/ZoomServerToServerClient.swift App/Zoom/NewMeetingRequest.swift
finish
