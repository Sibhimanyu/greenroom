#!/bin/bash
# Settings -> Layouts to PNGs, off screen, sample data: the page in its states (one and
# two displays, look group, share pop-out, scrolling strip) plus Preview: Everyone.
# Usage: scripts/render/layouts.sh [outdir]   (default $TMPDIR/greenroom-render/layouts)
NAME=layouts; source "$(dirname "$0")/lib.sh"
stage_layouts
render layouts-render layouts-main.swift $LAYOUT_FILES
render everyone-render layouts-everyone-main.swift $LAYOUT_FILES
finish
