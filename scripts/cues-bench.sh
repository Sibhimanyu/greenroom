#!/bin/bash
#
# Score the word-pattern detector against the checked-in fixtures.
#
#   scripts/cues-bench.sh              # the report
#   scripts/cues-bench.sh --verbose    # every false alarm and miss
#
# Phase 1 of docs/cues-search-improvement-plan.md. No network, no model, no
# microphone, no meeting: the same input gives the same number every time, which
# is the whole point. Run it before and after any change to the detector or its
# filters, and put both numbers in the commit message.
#
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 2; }

xcodegen generate >/dev/null

# -quiet still prints warnings; the grep keeps the report readable while letting
# a real failure through with its message intact.
if ! xcodebuild -project Greenroom.xcodeproj -scheme CuesBench \
        -configuration Debug build 2>&1 | grep -E "error:|BUILD FAILED" ; then
    :  # grep found nothing, which here means the build was clean
else
    echo "build failed" >&2
    exit 2
fi

BIN=$(xcodebuild -project Greenroom.xcodeproj -scheme CuesBench \
        -configuration Debug -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')

exec "$BIN/CuesBench" "$(pwd)/Bench/fixtures/detector.json" "$@"
