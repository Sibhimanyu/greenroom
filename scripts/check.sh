#!/bin/bash
# One check: generate the project, build Debug, run the full GreenroomTests
# suite. Uses its own derived-data path under .build/ so parallel worktrees
# and agents never lock each other's build. Prints only errors, failing tests
# and the "Executed N tests" line. Exits non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."
DD="${DERIVED_DATA:-$PWD/.build/DerivedData}"  # override to keep a running build untouched
LOG="$PWD/.build/check.log"
mkdir -p .build

fail() { echo "CHECK FAILED: $1"; exit 1; }

python3 scripts/check-test-target.py || fail "a test names a type whose source file is not in GreenroomTests.sources"

xcodegen generate >"$LOG" 2>&1 || { tail -20 "$LOG"; fail "xcodegen generate"; }

xcodebuild build -project Greenroom.xcodeproj -scheme Greenroom -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD" >"$LOG" 2>&1
if [ $? -ne 0 ]; then grep -E "error:" "$LOG" | sort -u | head -30; fail "Debug build"; fi

xcodebuild test -project Greenroom.xcodeproj -scheme GreenroomTests \
  -destination 'platform=macOS' -derivedDataPath "$DD" >"$LOG" 2>&1
rc=$?
grep -E "^/.*: error:|^error:|Test Case .* failed" "$LOG" | sort -u | head -40
grep -E "Executed [0-9]+ tests?" "$LOG" | tail -1 | sed 's/^[[:space:]]*//'
[ $rc -eq 0 ] || fail "GreenroomTests"
echo "CHECK OK"
