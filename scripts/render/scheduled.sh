#!/bin/bash
# Home's Scheduled picker, off screen, sample data: the field with the personal room chosen,
# a scheduled meeting chosen and nothing chosen, and the menu's lines with and without the
# personal room (a stand-in list: macOS draws the real menu, so only its words and order are
# real here, from ScheduledListRules); light and dark.
# Usage: scripts/render/scheduled.sh [outdir]   (default $TMPDIR/greenroom-render/scheduled)
NAME=scheduled; source "$(dirname "$0")/lib.sh"
write_brand
render scheduled-render scheduled-main.swift App/UI/ScheduledPickerField.swift "$STAGE/Brand.swift" \
  App/Zoom/ZoomPersonalRoom.swift App/Zoom/ZoomServerToServerClient.swift App/Zoom/ZoomScopes.swift \
  App/Zoom/ZoomSetupCheckRules.swift App/Zoom/ZoomCheckActionRules.swift App/Zoom/ZoomMarketplaceGuide.swift \
  App/Zoom/NewMeetingRequest.swift App/Zoom/ZoomRouteRules.swift App/Zoom/ZoomUserAuthRules.swift \
  App/Zoom/ZoomRouteChoiceRules.swift App/Zoom/ZoomSignInAvailability.swift \
  App/Zoom/ZoomMarketplacePages.swift App/Zoom/ZoomGuideFlowRules.swift App/Zoom/ZoomStartOverRules.swift App/Zoom/ZoomSetupFlow.swift App/Zoom/ZoomPageSnapshot.swift App/Zoom/ZoomPage.swift
finish
