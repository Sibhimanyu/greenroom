#!/bin/bash
# The whole release ritual in one command:
#   scripts/release.sh 0.3.1 "notes.md"
# - bumps MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml
# - Release build, signature verify, ditto zip, round-trip verify
# - EdDSA-signs the zip and regenerates docs/appcast.xml (Sparkle),
#   so installed copies self-update
# - commits the bump + appcast, pushes, creates the GitHub release
#
# Requires: xcodegen, gh (authed), the Sparkle EdDSA private key in the
# login Keychain (generate_keys created it), and Vendor/ZoomSDK in place.
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
rm -rf "$DIST/verify"

# Appcast: latest release only - Sparkle just needs a newer-than-current
# entry, and single-entry keeps enclosure URLs per-release-tag simple.
"$TOOLS/bin/generate_appcast" \
  --download-url-prefix "https://github.com/Sibhimanyu/greenroom/releases/download/v$VERSION/" \
  --embed-release-notes \
  -o docs/appcast.xml "$DIST"

git add project.yml docs/appcast.xml
git commit -m "Version $VERSION"
git push

gh release create "v$VERSION" "$DIST/Greenroom-$VERSION.zip#Greenroom $VERSION (macOS app, zip)" \
  --title "Greenroom $VERSION" --latest --notes-file "$NOTES"

echo "Released v$VERSION - installed copies will see it once GitHub Pages serves the new appcast."
