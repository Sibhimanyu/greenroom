#!/bin/bash
# The Meeting window's "You" tile (SelfPreviewView) in each of the four camera states, and the Self view
# window's tile (MeetingVideoTile) in the same states plus video stopped, off screen, over a staged
# shared-screen picture. Usage: scripts/render/self-view.sh [outdir]
# (default $TMPDIR/greenroom-render/self-view)
NAME=self-view; source "$(dirname "$0")/lib.sh"
# The tile's button reads MeetingBarModel, which pulls in the layout model: reuse the Layouts set.
stage_layouts
# LevelMeterView lives in App/UI/MeetingWindow/MeetingMeters.swift (it sits beside the SDK-bound readiness pill); a stand-in keeps the tile's layout.
printf 'import AppKit\nfinal class LevelMeterView: NSView { var level: Double = 0 }\n' > "$STAGE/MeterStub.swift"
# The view-window tile's right-click opens a MeetingMenuPanel, which logs through the coordinator.
printf 'enum CoordinatorController { static func sessionLog(_ s: String) {} }\n' > "$STAGE/LogStub.swift"
render self-view-render self-view-main.swift $LAYOUT_FILES "$STAGE/MeterStub.swift" "$STAGE/LogStub.swift" \
  App/UI/ParticipantConsole/SelfPreviewView.swift App/UI/ParticipantConsole/SelfViewMarkView.swift \
  App/UI/ClosureButton.swift App/UI/SelfViewRules.swift \
  App/UI/MeetingVideo/VideoTiles.swift App/UI/MeetingTileChrome.swift App/UI/MeetingMenuPanel.swift
finish
