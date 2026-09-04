#!/bin/bash
# Repoint every Download button on the site at one release artifact.
#   scripts/site-download-link.sh 0.6.0 dmg
#   scripts/site-download-link.sh 0.6.0 zip
#
# Policy: the buttons follow the NEWEST DMG (drag-to-install is the
# friendlier first download, and Sparkle brings a fresh install up to date on
# first launch), so a zip-only release does not move the link. release.sh
# calls this only when it built a DMG; "zip" exists for the day no DMG has
# ever been published. If a DMG is uploaded by hand later, run this with
# "dmg" and commit docs/ - the site's download-link.js also finds the newest
# DMG at view time in the meantime.
set -euo pipefail

VERSION="${1:?usage: site-download-link.sh <version> <dmg|zip>}"
EXT="${2:?usage: site-download-link.sh <version> <dmg|zip>}"
case "$EXT" in dmg|zip) ;; *) echo "artifact must be dmg or zip"; exit 1 ;; esac

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

sed -i '' -E \
  "s#releases/download/v[0-9.]+/Greenroom-[0-9.]+\.(zip|dmg)#releases/download/v$VERSION/Greenroom-$VERSION.$EXT#g" \
  docs/*.html

echo "Download buttons -> v$VERSION $EXT ($(grep -l "Greenroom-$VERSION.$EXT" docs/*.html | wc -l | tr -d ' ') pages)"
