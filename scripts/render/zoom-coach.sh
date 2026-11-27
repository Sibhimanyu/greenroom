#!/bin/bash
# The Zoom window's coach (docs/specs/zoom-setup-assist.md, R6), off screen: the real ZoomCoachScript
# and ZoomCoachRules text, run in a WKWebView on a static mock of Zoom's "What kind of app" page
# (scripts/render/zoom-coach-page.html, sample text only). The dim layer, the spotlight cut-out with
# the Brand.green ring and the callout card, for the Hosting app (light and dark) and the Meeting app.
# Usage: scripts/render/zoom-coach.sh [outdir]   (default $TMPDIR/greenroom-render/zoom-coach)
NAME=zoom-coach; source "$(dirname "$0")/lib.sh"
write_brand
export COACH_MARK="$ROOT/Branding/greenroom-mark/png/App-icon-64.png"
export COACH_HTML="$ROOT/scripts/render/zoom-coach-page.html"
render zoom-coach-render zoom-coach-main.swift "$STAGE/Brand.swift" \
  App/Zoom/ZoomCoachRules.swift App/Zoom/ZoomCoachScript.swift App/Zoom/ZoomMarketplacePages.swift \
  App/Zoom/ZoomGuideFollowRules.swift App/Zoom/ZoomStartOverRules.swift App/Zoom/ZoomMarketplaceGuide.swift App/Zoom/ZoomGuideFlowRules.swift \
  App/Zoom/ZoomSetupCheckRules.swift App/Zoom/ZoomCheckActionRules.swift App/Zoom/ZoomRouteRules.swift \
  App/Zoom/ZoomScopes.swift App/Zoom/ZoomUserAuthRules.swift App/Zoom/ZoomRouteChoiceRules.swift App/Zoom/ZoomSignInAvailability.swift \
  App/Zoom/ZoomPersonalRoom.swift App/Zoom/ZoomServerToServerClient.swift App/Zoom/NewMeetingRequest.swift
finish
