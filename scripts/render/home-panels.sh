#!/bin/bash
# Home's Camera and Screen pop-outs side by side, plus the who-sees icons, off screen,
# sample data. Usage: scripts/render/home-panels.sh [outdir]
# (default $TMPDIR/greenroom-render/home-panels)
NAME=home-panels; source "$(dirname "$0")/lib.sh"
stage_panels
render panels-render home-panels-main.swift $PANEL_FILES
finish
