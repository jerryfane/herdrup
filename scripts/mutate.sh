#!/usr/bin/env bash
# Mutation harness.
#
# Reports one of four outcomes, because collapsing them is how a mutation run
# lies:
#
#   KILLED   — the mutation compiled, the named tests RAN, and at least one failed
#   SURVIVED — the mutation compiled, the tests ran, and all passed
#   INVALID  — the mutation did not compile, or matched no test: it exercised the
#              compiler or the filter, not the suite
#   ESCAPED  — the run hung and was killed by the timeout
#
# The previous version treated every non-zero `swift test` exit as KILLED. A
# mutation with a syntax error therefore reported KILLED while proving nothing,
# and so did a timeout, despite a comment claiming otherwise. Every outcome this
# harness reports is only as good as its ability to tell those cases apart.
#
# Usage: scripts/mutate.sh <name> "<target>" "<replacement>" <test-filter> [file]
set -uo pipefail
export PATH=/opt/swift/usr/bin:$PATH

NAME="$1"; TARGET="$2"; REPLACEMENT="$3"; FILTER="$4"
FILE="${5:-Sources/HerdrKit/SSHTransport.swift}"
BACKUP="$(mktemp)"
BUILD_LOG="$(mktemp)"
RUN_LOG="$(mktemp)"
cp "$FILE" "$BACKUP"
restore() { cp "$BACKUP" "$FILE"; rm -f "$BACKUP" "$BUILD_LOG" "$RUN_LOG"; }
trap restore EXIT

# The mutation must actually apply. Three silent no-op mutations made green runs
# look like working guards before this check existed.
python3 - "$FILE" "$TARGET" "$REPLACEMENT" <<'PY' || { echo "INVALID: mutation '$NAME' DID NOT APPLY — target absent"; exit 2; }
import sys
path, target, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
source = open(path).read()
if target not in source:
    sys.exit(1)
open(path, "w").write(source.replace(target, replacement, 1))
PY

# A mutation that does not compile tests the compiler.
if ! swift build --build-tests >"$BUILD_LOG" 2>&1; then
    echo "INVALID: mutation '$NAME' does not compile — it proves nothing about the tests"
    grep -m2 "error:" "$BUILD_LOG"
    exit 2
fi

echo "--- mutation '$NAME' applied and compiles; expecting $FILTER to FAIL ---"
timeout 300 swift test --filter "$FILTER" >"$RUN_LOG" 2>&1
STATUS=$?

if [ "$STATUS" -eq 124 ]; then
    echo "ESCAPED: '$NAME' made $FILTER hang. A hang is not a kill."
    exit 3
fi

# "Executed 0 tests" means the filter matched nothing, which exits 0 and would
# otherwise be indistinguishable from a survivor.
EXECUTED=$(grep -oE "Executed [0-9]+ tests?" "$RUN_LOG" | grep -oE "[0-9]+" | sort -rn | head -1)
EXECUTED=${EXECUTED:-0}
if [ "$EXECUTED" -eq 0 ]; then
    echo "INVALID: filter '$FILTER' matched no tests — nothing was exercised"
    exit 2
fi

if [ "$STATUS" -eq 0 ]; then
    echo "SURVIVED: $FILTER ($EXECUTED tests) still passes with '$NAME' broken. The test does not guard it."
    exit 1
fi

if ! grep -q "^Test Case .* failed" "$RUN_LOG"; then
    echo "INVALID: $FILTER exited $STATUS with no test-case failure — the run broke, it did not fail"
    tail -3 "$RUN_LOG"
    exit 2
fi

echo "KILLED: $FILTER ($EXECUTED tests) fails when '$NAME' is broken."
grep -m3 -E "^/.*error: .*XCTAssert|^Test Case .* failed" "$RUN_LOG"
