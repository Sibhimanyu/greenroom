#!/bin/bash
# The floating bar's camera menu as the app draws it (MeetingMenuPanel's own rows, measured as the
# panel measures them), placed by MenuPanelPlacement above the bar near the bottom of a screen: the
# owner's 1.10.0 screenshot, where the divider and Stop video were cut off. Off, then Off with video
# stopped. Prints each menu's measured size. Staged data only.
# Usage: scripts/render/bar-menu.sh [outdir]   (default $TMPDIR/greenroom-render/bar-menu)
NAME=bar-menu; source "$(dirname "$0")/lib.sh"
stage_layouts
# MeetingMenuPanel logs through the coordinator.
printf 'enum CoordinatorController { static func sessionLog(_ s: String) {} }\n' > "$STAGE/LogStub.swift"
render bar-menu-render bar-menu-main.swift $LAYOUT_FILES "$STAGE/LogStub.swift" \
  App/UI/MeetingMenuPanel.swift App/UI/MenuPanelPlacement.swift
finish
