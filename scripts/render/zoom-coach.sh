#!/bin/bash
# The Zoom window's coach (docs/specs/zoom-setup-flow.md), off screen: the real ZoomCoachScript, a renderer of a CoachDrawing,
# run in a WKWebView on the Created apps mock (scripts/render/actor-mocks/created-apps.html): a ring around a control with
# the card (counter, title, why, status, button), a card alone, a card beside an open dialog; light and dark. Asserts the
# card's text equals the CoachDrawing JSON (nothing is copied from the page) and the buttons post 'act' / 'hide'.
# Usage: scripts/render/zoom-coach.sh [outdir]   (default $TMPDIR/greenroom-render/zoom-coach)
NAME=zoom-coach; source "$(dirname "$0")/lib.sh"
write_brand
export COACH_MARK="$ROOT/Branding/greenroom-mark/png/App-icon-64.png"
export ACTOR_MOCKS="$ROOT/scripts/render/actor-mocks"
printf 'enum ZoomOwnApp: Equatable, Hashable { case sdk, s2s }\n' > "$STAGE/OwnAppStub.swift"
render zoom-coach-render zoom-coach-main.swift "$STAGE/Brand.swift" \
  App/Zoom/ZoomPageSnapshot.swift App/Zoom/ZoomPageScript.swift App/Zoom/ZoomPage.swift App/Zoom/ZoomActorRules.swift App/Zoom/ZoomCoachScript.swift \
  App/Zoom/ZoomMarketplacePages.swift App/Zoom/ZoomScopes.swift "$STAGE/OwnAppStub.swift"
finish
