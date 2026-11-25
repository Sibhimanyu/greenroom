#!/bin/bash
# Light and dark renders, off screen, sample data: Home's dock and name field and the
# Home pop-outs (frosted and solid, and the Mac switching appearance after launch),
# Settings -> Layouts, and the meeting bar.
# Usage: scripts/render/appearance.sh [outdir]   (default $TMPDIR/greenroom-render/appearance)
NAME=appearance; source "$(dirname "$0")/lib.sh"
stage_panels
# HomeView's private dock structs and mic meters, copied out between their doc comments
# (the view itself is coordinator-bound). A missing marker stops the script.
range() { # range <first line's text> <text of the line after the last>
  local s e; s=$(grep -n "^$1" App/UI/HomeView.swift | head -1 | cut -d: -f1); e=$(grep -n "^$2" App/UI/HomeView.swift | head -1 | cut -d: -f1)
  [ -n "$s" ] && [ -n "$e" ] || { echo "render: HomeView.swift markers moved: '$1' / '$2'" >&2; exit 1; }
  sed -n "${s},$((e-1))p" App/UI/HomeView.swift
}
{ echo "import SwiftUI"
  range '/// Watches the microphone monitor on its own' '/// Wraps its children onto'
  range '/// A dock button: no box at rest' '/// White wherever the picture'
} | sed 's/^private struct/struct/' > "$STAGE/HomeDock.swift"
printf 'import AppKit\nenum WindowBackdrop: Equatable { case frosted, solid; static func transitionDuration(reduceMotion: Bool) -> TimeInterval { 0 } }\nenum WindowShareController { static func attach(to: NSWindow, dark: Bool, accessory: Bool = true) {} }\n' > "$STAGE/Stub.swift"
render home-render appearance-main.swift $PANEL_FILES "$STAGE/HomeDock.swift" App/UI/WindowFrost.swift "$STAGE/Stub.swift" App/UI/Fields.swift App/UI/SolidSheet.swift App/Audio/MicLevelMonitor.swift
stage_layouts
render layouts-render appearance-layouts-main.swift $LAYOUT_FILES
render bar-render appearance-bar-main.swift $LAYOUT_FILES
finish
