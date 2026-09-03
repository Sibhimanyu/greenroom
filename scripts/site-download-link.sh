#!/bin/bash
# Repoint every Download button on the site at one release artifact.
#   scripts/site-download-link.sh 0.6.0 dmg
#   scripts/site-download-link.sh 0.6.0 zip
#
# Policy: prefer the DMG whenever the release has one (drag-to-install is
# the friendlier first download); the zip is the fallback because it is the
# one artifact every release is guaranteed to carry. release.sh calls this
# with whichever it managed to build. If a DMG is uploaded by hand later,
# run this again with "dmg" and commit docs/ - and the site's
# download-link.js upgrades the link at view time in the meantime.
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
