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

# Judged by xcodebuild's own exit status, not by grepping its output.
#
# The grep that used to decide this matched any line containing "error:",
# which on an Xcode whose CoreDevice plug-in fails to load includes
#   Details: No locator class for device extension ... error: Error Domain=...
# printed on every single invocation. The bench then reported "build failed"
# for a build that had succeeded. Environment noise is not a compile error.
_BENCH_LOG=$(mktemp)
xcodebuild -project Greenroom.xcodeproj -scheme CuesBench \
        -configuration Debug build >"$_BENCH_LOG" 2>&1
_BENCH_RC=$?
if [ "$_BENCH_RC" -ne 0 ]; then
    # Compiler diagnostics only: they start with an absolute path.
    grep -E "^/.*(error|warning): " "$_BENCH_LOG" | sort -u | head -20 >&2
    grep -E "\*\* BUILD FAILED" "$_BENCH_LOG" >&2
    rm -f "$_BENCH_LOG"
    echo "build failed" >&2
    exit 2
fi
rm -f "$_BENCH_LOG" 

BIN=$(xcodebuild -project Greenroom.xcodeproj -scheme CuesBench \
        -configuration Debug -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')

exec "$BIN/CuesBench" "$(pwd)/Bench/fixtures/detector.json" "$@"
