#!/bin/bash
# The whole release ritual in one command:
#   scripts/release.sh 0.3.1 "notes.md"
# - bumps MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml
# - Release build, signature verify, ditto zip, round-trip verify
# - EdDSA-signs the zip and regenerates docs/appcast.xml (Sparkle),
#   so installed copies self-update
# - packages the drag-to-install DMG (scripts/make-dmg.sh)
# - commits the bump + appcast, pushes, creates the GitHub release
#   with both the zip and the DMG attached
#
# Requires: xcodegen, gh (authed), create-dmg, Pillow (for the DMG
# backdrop), the Sparkle EdDSA private key in the login Keychain
# (generate_keys created it), and Vendor/ZoomSDK in place.
set -euo pipefail

VERSION="${1:?usage: release.sh <version> <notes-file>}"
NOTES="${2:?usage: release.sh <version> <notes-file>}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$REPO_DIR/.sparkle-tools"
DIST="$REPO_DIR/dist"
cd "$REPO_DIR"

# Sparkle command-line tools (gitignored, fetched on first use)
if [ ! -x "$TOOLS/bin/generate_appcast" ]; then
  echo "Fetching Sparkle tools..."
  mkdir -p "$TOOLS"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz" \
    | tar -xJ -C "$TOOLS"
fi

# Version bump (build number = monotonically increasing count of releases)
BUILD=$(( $(grep -o 'CURRENT_PROJECT_VERSION: "[0-9]*"' project.yml | grep -o '[0-9]*') + 1 ))
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml

xcodegen generate
xcodebuild -project Greenroom.xcodeproj -scheme Greenroom -configuration Release build | grep -E "BUILD" | tail -1

APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Greenroom-*/Build/Products/Release/Greenroom.app | head -1)
codesign --verify --deep --strict "$APP"

rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Greenroom-$VERSION.zip"
ditto -x -k "$DIST/Greenroom-$VERSION.zip" "$DIST/verify"
codesign --verify --deep --strict "$DIST/verify/Greenroom.app"

# Linkage gate: codesign passes on bundles missing frameworks entirely
# (it verifies what exists, not what the binary needs) - v0.3.0 shipped
# crashing exactly that way. Resolve every @rpath load command against
# the bundle and refuse to release if any is unresolvable.
BINARY="$DIST/verify/Greenroom.app/Contents/MacOS/Greenroom"
FRAMEWORKS="$DIST/verify/Greenroom.app/Contents/Frameworks"
MISSING=0
while read -r lib; do
  name="${lib#@rpath/}"; top="${name%%/*}"
  if [ ! -e "$FRAMEWORKS/$top" ]; then
    echo "LINKAGE ERROR: binary needs $lib but $top is not in Contents/Frameworks"
    MISSING=1
  fi
done < <(otool -L "$BINARY" | awk '/@rpath/ {print $1}')
[ "$MISSING" -eq 0 ] || exit 1

# Smoke launch: a bundle that dies at startup must never ship. Quit any
# running copy first (the dev build), launch the exact zip contents,
# require a live process after 5s.
pgrep -x Greenroom >/dev/null && osascript -e 'tell application "Greenroom" to quit' >/dev/null 2>&1 && sleep 2
open "$DIST/verify/Greenroom.app"
sleep 5
pgrep -x Greenroom >/dev/null || { echo "SMOKE TEST FAILED: app did not survive launch"; exit 1; }
osascript -e 'tell application "Greenroom" to quit' >/dev/null 2>&1 || true
sleep 2
rm -rf "$DIST/verify"

# Appcast: latest release only - Sparkle just needs a newer-than-current
# entry, and single-entry keeps enclosure URLs per-release-tag simple.
# The EdDSA key is read from a file: the Keychain copy is inaccessible
# to non-interactive shells (errSecUserCanceled -128). Export it with
#   .sparkle-tools/bin/generate_keys -x ~/.greenroom-sparkle-ed25519
KEY_FILE="$HOME/.greenroom-sparkle-ed25519"
[ -f "$KEY_FILE" ] || { echo "Missing $KEY_FILE - export it (see comment above)"; exit 1; }
"$TOOLS/bin/generate_appcast" \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "https://github.com/Sibhimanyu/greenroom/releases/download/v$VERSION/" \
  --embed-release-notes \
  -o docs/appcast.xml "$DIST"

# Drag-to-install disk image. Built AFTER generate_appcast on purpose:
# generate_appcast scans $DIST and treats a .dmg as another update archive,
# so a DMG sitting there beforehand lands in the appcast as an enclosure.
# Sparkle updates ship as the zip; the DMG is only for manual installs.
#
# BEST-EFFORT: hdiutil (which create-dmg drives) is blocked by corporate
# endpoint security on some Macs - it fails "Resource busy" and never
# succeeds. The zip is the auto-update artifact and the primary
# download, so a missing DMG must not sink the whole release; it can be
# built on another machine and uploaded later. Only the zip is required.
if "$REPO_DIR/scripts/make-dmg.sh" "$APP" "$VERSION" "$DIST"; then
  DMG_ARG=("$DIST/Greenroom-$VERSION.dmg#Greenroom $VERSION (macOS app, dmg)")
else
  echo "WARNING: DMG packaging failed (hdiutil blocked?) - releasing zip only."
  DMG_ARG=()
fi

# The site's Download buttons link straight to this release's zip (the one
# artifact every release has; the DMG is best-effort above). Repoint them so
# the link never goes stale.
sed -i '' -E "s#releases/download/v[0-9.]+/Greenroom-[0-9.]+\.zip#releases/download/v$VERSION/Greenroom-$VERSION.zip#g" docs/*.html

git add project.yml docs/appcast.xml docs/*.html
git commit -m "Version $VERSION"
git push

# The "${DMG_ARG[@]+...}" form is required: under `set -u`, expanding an
# empty array as "${DMG_ARG[@]}" is an "unbound variable" error in macOS's
# bash 3.2, which previously aborted the release AFTER the version bump was
# already pushed (v0.3.3 shipped that way and had to be finished by hand).
gh release create "v$VERSION" \
  "$DIST/Greenroom-$VERSION.zip#Greenroom $VERSION (macOS app, zip)" \
  ${DMG_ARG[@]+"${DMG_ARG[@]}"} \
  --title "Greenroom $VERSION" --latest --notes-file "$NOTES"

echo "Released v$VERSION - installed copies will see it once GitHub Pages serves the new appcast."
