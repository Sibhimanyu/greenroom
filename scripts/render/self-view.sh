#!/bin/bash
# The Meeting window's "You" tile (SelfPreviewView) in each of the four camera states, off screen,
# over a staged shared-screen picture. Usage: scripts/render/self-view.sh [outdir]
# (default $TMPDIR/greenroom-render/self-view)
NAME=self-view; source "$(dirname "$0")/lib.sh"
# The tile's button reads MeetingBarModel, which pulls in the layout model: reuse the Layouts set.
stage_layouts
# LevelMeterView lives in ParticipantGridWindow.swift (SDK-bound); a stand-in keeps the tile's layout.
printf 'import AppKit\nfinal class LevelMeterView: NSView { var level: Double = 0 }\n' > "$STAGE/MeterStub.swift"
render self-view-render self-view-main.swift $LAYOUT_FILES "$STAGE/MeterStub.swift" \
  App/UI/ParticipantConsole/SelfPreviewView.swift App/UI/ClosureButton.swift App/UI/SelfViewRules.swift
finish
