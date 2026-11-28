#!/bin/bash
# Stop video (spec R49), off screen: the floating bar's camera button in every camera state, with
# video going out and stopped; the bar's and the Meeting toolbar's camera menus drawn from their
# entries (MeetingBarModel.cameraMenu; the real menu is an AppKit pop-up and cannot be drawn off
# screen); the Meeting toolbar; and the "You" tile stopped beside camera state Off.
# Usage: scripts/render/stop-video.sh [outdir]   (default $TMPDIR/greenroom-render/stop-video)
NAME=stop-video; source "$(dirname "$0")/lib.sh"
stage_layouts
# LevelMeterView lives in App/UI/MeetingWindow/MeetingMeters.swift (it sits beside the SDK-bound readiness pill); a stand-in keeps the tile's layout.
printf 'import AppKit\nfinal class LevelMeterView: NSView { var level: Double = 0 }\n' > "$STAGE/MeterStub.swift"
render stop-video-render stop-video-main.swift $LAYOUT_FILES "$STAGE/MeterStub.swift" \
  App/UI/ParticipantConsole/SelfPreviewView.swift App/UI/ParticipantConsole/SelfViewMarkView.swift App/UI/ClosureButton.swift App/UI/SelfViewRules.swift \
  App/UI/MeetingToolbar.swift
finish
