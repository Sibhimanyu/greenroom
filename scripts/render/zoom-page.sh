#!/bin/bash
# The Zoom page reader (docs/specs/zoom-setup-flow.md, ZoomPage): the real ZoomPageScript run in an off-screen WKWebView against
# mock Zoom pages (scripts/render/actor-mocks/*.html and the zoom-coach-*.html mocks), asserting the ZoomPageSnapshot for each
# page and each state it moves through (menu open, dialogs, name typed, Meeting SDK on, activated, keys readable / hidden /
# copyable) and that reading changes nothing on the page. Windows are borderless and far off screen. Prints PASS/FAIL and a
# one-line summary per snapshot; exits 1 on a failure.
# Usage: scripts/render/zoom-page.sh [outdir]   (outdir is unused; kept for the shared lib)
NAME=zoom-page; source "$(dirname "$0")/lib.sh"
write_brand
export ACTOR_MOCKS="$ROOT/scripts/render/actor-mocks"
export COACH_DIR="$ROOT/scripts/render"
render zoom-page-render zoom-page-main.swift "$STAGE/Brand.swift" \
  App/Zoom/ZoomPageSnapshot.swift App/Zoom/ZoomPageScript.swift \
  App/Zoom/ZoomActorRules.swift App/Zoom/ZoomKeyReaderScript.swift App/Zoom/ZoomActorScript.swift App/Zoom/ZoomFinderScript.swift App/Zoom/ZoomDialogScript.swift App/Zoom/ZoomAppListScript.swift \
  App/Zoom/ZoomCoachRules.swift App/Zoom/ZoomCoachScript.swift App/Zoom/ZoomMarketplacePages.swift App/Zoom/ZoomGuideFollowRules.swift \
  App/Zoom/ZoomMarketplaceGuide.swift App/Zoom/ZoomStartOverRules.swift App/Zoom/ZoomGuideFlowRules.swift App/Zoom/ZoomSetupCheckRules.swift \
  App/Zoom/ZoomCheckActionRules.swift App/Zoom/ZoomScopes.swift App/Zoom/ZoomUserAuthRules.swift App/Zoom/ZoomRouteRules.swift \
  App/Zoom/ZoomRouteChoiceRules.swift App/Zoom/ZoomSignInAvailability.swift App/Zoom/ZoomPersonalRoom.swift \
  App/Zoom/ZoomServerToServerClient.swift App/Zoom/NewMeetingRequest.swift
echo "zoom-page: done"
