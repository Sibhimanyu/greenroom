#!/bin/bash
# Full UI tour of a RUNNING Debug Greenroom. Runs in the background: it never
# activates the app, sends no keystrokes or clicks, and ends with `restore`
# (Home, original appearance + frame, tour windows closed). Needs Greenroom
# launched from DerivedData by the user; this script does not launch it.
DIR="${TOUR_DIR:-/private/tmp/claude-502/-Users-sibhi-zstch1643-squeak-workspaces-greenroom-hong-kong/a8a46d29-7ec2-41d7-960b-ff6744402685/scratchpad/tour}"
HERE="$(cd "$(dirname "$0")" && pwd)"
POST="$HERE/post"
[ -x "$POST" ] || swiftc -O "$HERE/post.swift" -o "$POST" || exit 1
pgrep -x Greenroom >/dev/null || { echo "Greenroom is not running"; exit 1; }
mkdir -p "$DIR"
FAILS=0

# step cmd=... args... : post, wait for last.json (20s), report ok/error.
step() {
  rm -f "$DIR/last.json"
  "$POST" dir="$DIR" "$@"
  for _ in $(seq 1 200); do [ -s "$DIR/last.json" ] && break; sleep 0.1; done
  if [ ! -s "$DIR/last.json" ]; then echo "TIMEOUT: $*"; FAILS=$((FAILS+1)); return; fi
  if grep -q '"ok" : true' "$DIR/last.json"; then
    grep -q warning "$DIR/last.json" && echo "WARN $*: $(grep warning "$DIR/last.json")"
  else echo "FAIL $*: $(grep error "$DIR/last.json")"; FAILS=$((FAILS+1)); fi
}
trap 'step cmd=restore' EXIT

go()  { step cmd=goto page="$1" "${@:2}"; }
shot() { step cmd=shot name="$1"; }

for mode in light dark; do
  step cmd=appearance mode=$mode
  for page in home sessions detail report record editor onboarding chat; do
    go $page; shot "$mode-$page"
    case $page in record|editor|onboarding|chat) step cmd=goto page=home;; esac
  done
  for tab in webcam layout shortcuts zoom youtube cues transfer; do
    go settings tab=$tab; shot "$mode-settings-$tab"
  done
  go home
done

step cmd=appearance mode=system
for w in 900 1400; do
  step cmd=sessionWindowSize w=$w
  go sessions; shot "sessions-$w"
  go detail;   shot "detail-$w"
done
echo "tour done, $FAILS failure(s). PNGs and JSON in $DIR"
