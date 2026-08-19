#!/bin/bash
# Measures how long quitting Greenroom actually takes, end to end.
#
#   scripts/measure-quit.sh [settle-seconds]
#
# Why this exists: quit waits on OTHER processes (OBS over Apple Events, the
# Zoom SDK), so quit latency is an integration property that no unit test can
# see. This is the harness that caught the 5.8s quit - OBS drops a single quit
# Apple Event when its main thread is busy, and nothing used to re-send it.
#
# The interesting variable is how long OBS has been up: a settled OBS answers
# the quit event in ~200ms, a still-initializing one drops it. Pass a small
# settle time (5) to exercise the dropped-event path, a large one (30) for the
# steady state. Run both before and after touching windDownForQuit or
# quitAndWait.
#
# Per-phase costs come from the app itself: ~/Library/Logs/Greenroom-quit.log
set -uo pipefail

SETTLE="${1:-30}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Greenroom-*/Build/Products/Debug/Greenroom.app 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Greenroom-*/Build/Products/Release/Greenroom.app 2>/dev/null | head -1)
fi
if [ -z "$APP" ]; then
  echo "No built Greenroom.app in DerivedData. Build it first:" >&2
  echo "  xcodebuild -project Greenroom.xcodeproj -scheme Greenroom -configuration Debug build" >&2
  exit 1
fi
echo "app:    $APP"
echo "settle: ${SETTLE}s"

if pgrep -x Greenroom >/dev/null; then
  echo "Greenroom is already running - quit it first so this measures a clean launch." >&2
  exit 1
fi

open "$APP"
sleep "$SETTLE"

PID=$(pgrep -x Greenroom | head -1)
if [ -z "$PID" ]; then echo "Greenroom did not stay running." >&2; exit 1; fi
echo "before quit: $(pgrep -l 'Greenroom|OBS' | tr '\n' ' ')"

START=$(python3 -c 'import time; print(time.time())')
osascript -e 'quit app "Greenroom"' 2>/dev/null
# Poll to real process exit; the quit Apple Event returns before
# applicationShouldTerminate's terminateLater work is done.
for _ in $(seq 1 600); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.05
done
END=$(python3 -c 'import time; print(time.time())')

if kill -0 "$PID" 2>/dev/null; then
  echo "RESULT: Greenroom STILL ALIVE after 30s - that is the bug, not a slow quit."
else
  python3 -c "print(f'RESULT: quit wall time {($END - $START) * 1000:.0f} ms')"
fi

if pgrep -x OBS >/dev/null; then
  echo "WARNING: OBS outlived Greenroom - quitAndWait failed to reap it."
else
  echo "OBS exited with Greenroom."
fi

echo "--- per-phase (from the app) ---"
tail -3 "$HOME/Library/Logs/Greenroom-quit.log" 2>/dev/null || echo "(no quit log yet)"
