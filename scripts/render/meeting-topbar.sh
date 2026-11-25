#!/bin/bash
# The Meeting window's top bar with the share eye in the title bar, off screen: the real
# MeetingTopBarView in a window styled like the Meeting window (dark, see-through title bar,
# full-size content), at the minimum widths (760 meeting, 320 placed slot) and a normal one.
# Checks that Smaller and View end before the eye.
# Usage: scripts/render/meeting-topbar.sh [outdir]   (default $TMPDIR/greenroom-render/meeting-topbar)
NAME=meeting-topbar; source "$(dirname "$0")/lib.sh"
# WindowShareController drags in the whole share registry; the harness takes only the
# real reserve function, and its main.swift adds the eye the way addTitleAccessory does.
{ echo "import AppKit"
  echo "enum WindowShareController {"
  awk '/static func trailingTitleReserve/{p=1} p{print} p&&/^    }$/{exit}' App/UI/WindowShareController.swift
  echo "}"
} > "$STAGE/ShareStub.swift"
# The View menu's AppKit pop-up is coordinator-bound; nothing is clicked here.
printf 'import AppKit\n@MainActor enum MeetingMenuBuilder { static func popUp(_ entries: [MenuEntry], above view: NSView, below: Bool = false) {} }\n' > "$STAGE/MenuStub.swift"
grep -q trailingTitleReserve "$STAGE/ShareStub.swift" || { echo "render: trailingTitleReserve not found" >&2; exit 1; }
write_brand
# The model files the share rules pull in (LayoutPiece and what it holds), as in stage_layouts.
MODEL="App/Layout/LayoutTemplate.swift App/Layout/LayoutBuiltIns.swift App/Layout/LayoutGeometry.swift App/Layout/LayoutCamera.swift
  App/Layout/Visibility.swift App/Layout/RoomScreenRules.swift App/Layout/DisplayResolver.swift App/Layout/AppCatalog.swift
  App/Stage/CameraState.swift App/Stage/WebcamShape.swift App/Stage/ShareTargetModel.swift App/Stage/PresenceGeometry.swift
  App/Stage/CameraEffects.swift App/Stage/CameraBackgroundChoice.swift App/Stage/StageLayout.swift App/Stage/StageFrame.swift
  App/Stage/PresenceRecorderRules.swift App/Stage/MainPersonSelector.swift App/Zoom/MeetingShareRules.swift
  App/ShareVisibilityRules.swift App/MeetingCollapseRules.swift App/ShortcutStore.swift App/ShortcutModel.swift App/LiveExitRules.swift"
render topbar-render meeting-topbar-main.swift $MODEL "$STAGE/Brand.swift" "$STAGE/ShareStub.swift" "$STAGE/MenuStub.swift" \
  App/UI/MeetingTopBar.swift App/UI/MeetingTopBarLayout.swift App/UI/MeetingTheme.swift App/MeetingShrinkRules.swift \
  App/UI/Glass.swift App/UI/MeetingMenuSpec.swift App/UI/MeetingVideo/ShowOnShareViews.swift App/UI/ClosureButton.swift \
  App/UI/VisibilitySymbols.swift App/UI/MeetingVideo/MeetingViewRules.swift
finish
