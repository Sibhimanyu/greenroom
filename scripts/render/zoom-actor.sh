#!/bin/bash
# Dry run of "Do this step" (docs/specs/zoom-setup-assist.md, R16): the real ZoomActorScript and ZoomCoachScript in an
# off-screen WKWebView against mock Zoom pages (scripts/render/actor-mocks/*.html: Created apps with the + menu and
# the Build dialog, the Scopes page with its Add Scopes panel, Activation, Embed; each with Regenerate / Delete
# buttons that must never be pressed). Asserts each mock's final state; prints PASS/FAIL lines and exits 1 on a
# failure. Also writes PNGs of the coach before and after each step.
# Usage: scripts/render/zoom-actor.sh [outdir]   (default $TMPDIR/greenroom-render/zoom-actor)
NAME=zoom-actor; source "$(dirname "$0")/lib.sh"
write_brand
export ACTOR_MOCKS="$ROOT/scripts/render/actor-mocks"
export COACH_MARK="$ROOT/Branding/greenroom-mark/png/App-icon-64.png"
render zoom-actor-render zoom-actor-main.swift "$STAGE/Brand.swift" \
  App/Zoom/ZoomActorRules.swift App/Zoom/ZoomKeyReaderScript.swift App/Zoom/ZoomActorScript.swift App/Zoom/ZoomFinderScript.swift App/Zoom/ZoomDialogScript.swift App/Zoom/ZoomAppListScript.swift \
  App/Zoom/ZoomCoachRules.swift App/Zoom/ZoomCoachScript.swift App/Zoom/ZoomMarketplacePages.swift App/Zoom/ZoomGuideFollowRules.swift \
  App/Zoom/ZoomMarketplaceGuide.swift App/Zoom/ZoomStartOverRules.swift App/Zoom/ZoomGuideFlowRules.swift App/Zoom/ZoomSetupCheckRules.swift \
  App/Zoom/ZoomCheckActionRules.swift App/Zoom/ZoomScopes.swift App/Zoom/ZoomUserAuthRules.swift App/Zoom/ZoomRouteRules.swift \
  App/Zoom/ZoomRouteChoiceRules.swift App/Zoom/ZoomSignInAvailability.swift App/Zoom/ZoomPersonalRoom.swift \
  App/Zoom/ZoomServerToServerClient.swift App/Zoom/NewMeetingRequest.swift
finish
