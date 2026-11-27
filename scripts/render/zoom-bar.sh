#!/bin/bash
# The Greenroom bar at the top of the Zoom window (docs/specs/zoom-setup-flow.md), off screen: ZoomBarView renders a
# hand-built SetupStep (Do this step, Open Embed, working, the Fill instruction, the permission blocker, signed out,
# Copy scopes / Copied, Back to Greenroom, Checking, and the Set up for me line with Stop) at 900pt (the window's
# minimum) and 1400pt; light and dark.
# Usage: scripts/render/zoom-bar.sh [outdir]   (default $TMPDIR/greenroom-render/zoom-bar)
NAME=zoom-bar; source "$(dirname "$0")/lib.sh"
write_brand
render zoom-bar-render zoom-bar-main.swift "$STAGE/Brand.swift" App/UI/ZoomBarView.swift \
  App/Zoom/ZoomSetupFlow.swift App/Zoom/ZoomPageSnapshot.swift App/Zoom/ZoomMarketplacePages.swift App/Zoom/ZoomScopes.swift \
  App/Zoom/ZoomPage.swift App/Zoom/ZoomSetupCheckRules.swift App/Zoom/ZoomCheckActionRules.swift App/Zoom/ZoomMarketplaceGuide.swift \
  App/Zoom/ZoomStartOverRules.swift App/Zoom/ZoomGuideFlowRules.swift App/Zoom/ZoomUserAuthRules.swift App/Zoom/ZoomRouteRules.swift \
  App/Zoom/ZoomRouteChoiceRules.swift App/Zoom/ZoomSignInAvailability.swift App/Zoom/ZoomPersonalRoom.swift \
  App/Zoom/ZoomServerToServerClient.swift App/Zoom/NewMeetingRequest.swift
finish
