#!/bin/bash
# Copies Syphon.framework into Vendor/Syphon from the installed OBS.
#
# Syphon is how Greenroom hands OBS a camera picture with the background
# already removed (App/OBS/CutoutPublisher.swift): OBS 32 ships a Syphon
# source that keeps transparency. Greenroom loads the framework at runtime
# (no headers needed), and Xcode embeds and re-signs this copy, so it passes
# the hardened runtime's library validation.
#
# Why OBS's build and not our own: Syphon has no Swift package, and building
# it needs Xcode's Metal toolchain, a separate ~1 GB download since Xcode 26.
# OBS ships the same BSD-licensed framework, universal (arm64 + x86_64),
# with its shaders compiled. Rerun only to move to a newer Syphon.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="/Applications/OBS.app/Contents/Frameworks/Syphon.framework"
DEST="$ROOT/Vendor/Syphon"

[ -d "$SRC" ] || { echo "error: $SRC not found. Install OBS Studio first." >&2; exit 1; }
mkdir -p "$DEST"
rm -rf "$DEST/Syphon.framework"
cp -R "$SRC" "$DEST/"
# OBS's signature is replaced by ours when Xcode embeds it.
codesign --remove-signature "$DEST/Syphon.framework" 2>/dev/null || true
rm -rf "$DEST/Syphon.framework/Versions/A/_CodeSignature"
OBS_VERSION=$(defaults read /Applications/OBS.app/Contents/Info.plist CFBundleShortVersionString)
echo "Copied from OBS $OBS_VERSION on $(date +%Y-%m-%d)" > "$DEST/SOURCE"
echo "Vendored Syphon.framework from OBS $OBS_VERSION"
