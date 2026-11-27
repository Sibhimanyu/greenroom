#!/bin/bash
# Quit every running Greenroom (any DerivedData path), then open THIS
# worktree's Debug build without stealing focus. Build it first with
# scripts/check.sh (or xcodebuild with -derivedDataPath .build/DerivedData).
# Extra arguments go to the app as launch arguments, e.g.
#   scripts/run-debug.sh -zoomRecord YES -zoomCoachOff YES
set -u
cd "$(dirname "$0")/.."
APP="$PWD/.build/DerivedData/Build/Products/Debug/Greenroom.app"
if [ ! -d "$APP" ]; then
  # Fall back to an Xcode-built copy whose WorkspacePath is this worktree.
  for info in "$HOME"/Library/Developer/Xcode/DerivedData/Greenroom-*/info.plist; do
    [ -f "$info" ] || continue
    ws=$(/usr/libexec/PlistBuddy -c "Print :WorkspacePath" "$info" 2>/dev/null || true)
    if [ "$ws" = "$PWD/Greenroom.xcodeproj" ]; then
      APP="$(dirname "$info")/Build/Products/Debug/Greenroom.app"; break
    fi
  done
fi
[ -d "$APP" ] || { echo "No Debug build for $PWD. Run scripts/check.sh first." >&2; exit 1; }

osascript -e 'tell application id "com.sibhimanyu.greenroom" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Greenroom >/dev/null || break; sleep 0.5; done
pkill -x Greenroom 2>/dev/null || true

if [ $# -gt 0 ]; then open -g "$APP" --args "$@"; else open -g "$APP"; fi
echo "branch: $(git rev-parse --abbrev-ref HEAD)"
echo "commit: $(git rev-parse --short HEAD)"
echo "opened: $APP"
[ $# -eq 0 ] || echo "args:   $*"
