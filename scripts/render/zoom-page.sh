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
# ZoomMarketplacePages only needs this tiny enum from the check rules.
printf 'enum ZoomOwnApp: Equatable, Hashable { case sdk, s2s }\n' > "$STAGE/OwnAppStub.swift"
render zoom-page-render zoom-page-main.swift "$STAGE/Brand.swift" \
  App/Zoom/ZoomPageSnapshot.swift App/Zoom/ZoomPageScript.swift App/Zoom/ZoomActorRules.swift "$STAGE/OwnAppStub.swift" App/Zoom/ZoomMarketplacePages.swift App/Zoom/ZoomScopes.swift
echo "zoom-page: done"
