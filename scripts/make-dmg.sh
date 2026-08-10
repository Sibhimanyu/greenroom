#!/bin/bash
# Package a built Greenroom.app as the drag-to-install disk image:
#   scripts/make-dmg.sh <path-to-Greenroom.app> <version> [out-dir]
#
# The window geometry below is paired with scripts/dmg-background.py - the
# backdrop is drawn for these exact icon slots, so the two must move together.
#
# Requires: create-dmg (brew install create-dmg), and Pillow for the backdrop
# regeneration step (skipped if Branding/dmg-background.tiff is already there).
set -euo pipefail

APP="${1:?usage: make-dmg.sh <Greenroom.app> <version> [out-dir]}"
VERSION="${2:?usage: make-dmg.sh <Greenroom.app> <version> [out-dir]}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${3:-$REPO_DIR/dist}"
BG="$REPO_DIR/Branding/dmg-background.tiff"
DMG="$OUT_DIR/Greenroom-$VERSION.dmg"

# Must match dmg-background.py's WIN_W/WIN_H, APP_ICON and DEST_ICON.
WIN_W=620; WIN_H=400
APP_X=160; APP_Y=198
DEST_X=460; DEST_Y=198

[ -d "$APP" ] || { echo "No such app bundle: $APP"; exit 1; }
[ -f "$BG" ] || python3 "$REPO_DIR/scripts/dmg-background.py" "$BG"

mkdir -p "$OUT_DIR"
rm -f "$DMG"

# create-dmg copies the whole source folder, so stage a directory holding
# nothing but the app - anything else here becomes a visible install-window
# icon sitting on top of the artwork.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "${STAGE}.rw.dmg"' EXIT
cp -R "$APP" "$STAGE/Greenroom.app"

create-dmg \
  --volname "Greenroom $VERSION" \
  --volicon "$APP/Contents/Resources/AppIcon.icns" \
  --background "$BG" \
  --window-pos 200 120 --window-size "$WIN_W" "$WIN_H" \
  --icon-size 128 \
  --icon "Greenroom.app" "$APP_X" "$APP_Y" \
  --app-drop-link "$DEST_X" "$DEST_Y" \
  --format ULMO \
  --no-internet-enable \
  "$DMG" "$STAGE"

# create-dmg leaves .VolumeIcon.icns and .background/ in the volume root with
# no invisible bit - a dot prefix alone is not enough, and Finder shows them
# to anyone who has hidden files switched on. Setting the flag needs a
# writable image, so round-trip through UDRW and recompress.
echo "Hiding volume support files..."
hdiutil convert "$DMG" -format UDRW -o "${STAGE}.rw.dmg" -quiet
MOUNT="$(mktemp -d)"
hdiutil attach "${STAGE}.rw.dmg" -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet
for f in .VolumeIcon.icns .background .fseventsd .Trashes; do
  [ -e "$MOUNT/$f" ] && chflags hidden "$MOUNT/$f" && SetFile -a V "$MOUNT/$f" 2>/dev/null || true
done
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT" 2>/dev/null || true
rm -f "$DMG"
hdiutil convert "${STAGE}.rw.dmg" -format ULMO -o "$DMG" -quiet

# Verify the packaged app the same way release.sh gates the zip: a valid
# signature proves nothing about whether every linked framework made it in.
echo "Verifying..."
hdiutil verify "$DMG" >/dev/null
VERIFY="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -noautoopen -mountpoint "$VERIFY" -quiet
codesign --verify --deep --strict "$VERIFY/Greenroom.app"
MISSING=0
while read -r lib; do
  top="${lib#@rpath/}"; top="${top%%/*}"
  if [ ! -e "$VERIFY/Greenroom.app/Contents/Frameworks/$top" ]; then
    echo "LINKAGE ERROR: $lib is not in the packaged bundle"
    MISSING=1
  fi
done < <(otool -L "$VERIFY/Greenroom.app/Contents/MacOS/Greenroom" | awk '/@rpath/ {print $1}')
hdiutil detach "$VERIFY" -quiet
rmdir "$VERIFY" 2>/dev/null || true
[ "$MISSING" -eq 0 ] || { rm -f "$DMG"; echo "Refusing to ship a broken disk image."; exit 1; }

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
