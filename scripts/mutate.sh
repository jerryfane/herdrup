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
# A CRASH ANYWHERE IN THE RUN IS NOT A KILL, even when an earlier suite already
# recorded a failure. A two-suite probe made suite 1 fail one assertion and
# suite 2 die with signal 4; the failure line and suite 1's count were both
# present, so this reported "KILLED (1 tests)" and hid the crash entirely. That
# is the exact rule this harness exists to enforce, broken by the harness.
if grep -qE "Exited with unexpected signal code|Program crashed|Fatal error" "$RUN_LOG"; then
    echo "INVALID: '$NAME' crashed the run. A crash is not a kill, even after a failure."
    grep -m2 -E "Exited with unexpected signal code|Program crashed|Fatal error" "$RUN_LOG"
    exit 2
fi

# From the TERMINAL summary, not the largest component suite. A filter spanning
# two suites reports each separately and then a final total; taking the largest
# component silently made the denominator a partial count whenever a later suite
# was bigger or never finished.
EXECUTED=$(grep -E "^\s+Executed [0-9]+ tests?" "$RUN_LOG" | tail -1 | grep -oE "[0-9]+" | head -1)
EXECUTED=${EXECUTED:-0}
if [ "$EXECUTED" -eq 0 ]; then
    echo "INVALID: filter '$FILTER' matched no tests — nothing was exercised"
    exit 2
fi

# SKIPS ARE EXTRACTED BEFORE EITHER VERDICT, not on the kill path only.
#
# The first version of this printed skips after the KILLED branch, so the
# SURVIVED branch exited before ever looking. A filter matching ONE test that
# immediately XCTSkips then reported "SURVIVED — the test does not guard it",
# which is the worst possible misreport: SURVIVED sends someone to rewrite a
# guard that never executed. Same shape as the crash defect fixed above — one
# branch corrected and the other left alone — and it is the second time in this
# file, so the extraction now happens where BOTH paths must pass through it.
SKIPPED=$(grep -oE "^Test Case '[^']+' skipped" "$RUN_LOG" \
          | sed -E "s/^Test Case '([^']+)' skipped/\1/" | sort -u)
SKIP_COUNT=$(printf '%s\n' "$SKIPPED" | grep -c . || true)
report_skips() {
    [ -n "$SKIPPED" ] || return 0
    echo "  SKIPPED (did not run — arm these before reading this result):"
    printf '%s\n' "$SKIPPED" | sed 's/^/    /'
}
RAN=$((EXECUTED - SKIP_COUNT))
if [ "$RAN" -le 0 ]; then
    echo "INVALID: every matched test SKIPPED — nothing ran, so '$NAME' is unverified, not survived."
    report_skips
    exit 2
fi

if [ "$STATUS" -eq 0 ]; then
    echo "SURVIVED: $FILTER ($RAN of $EXECUTED ran) still passes with '$NAME' broken. The test does not guard it."
    report_skips
    exit 1
fi

if ! grep -q "^Test Case .* failed" "$RUN_LOG"; then
    echo "INVALID: $FILTER exited $STATUS with no test-case failure — the run broke, it did not fail"
    tail -3 "$RUN_LOG"
    exit 2
fi

echo "KILLED: $FILTER ($EXECUTED tests) fails when '$NAME' is broken."
grep -m3 -E "^/.*error: .*XCTAssert|^Test Case .* failed" "$RUN_LOG"

# WHICH tests killed it, not just that something did.
#
# A kill is a PATTERN, not a verdict. On herdr-ios #13 a compiling no-op
# survived the two tests written for it and was killed by an unrelated one —
# and that SPLIT was the evidence those two tests were vacuous, available a
# full round before anyone ran a premise mutation. Reading the outcome as
# pass/fail threw it away. Named here so an uneven split is visible without
# re-reading the log.
#
# If a mutation is killed only by tests OTHER than the one written for it,
# that named test is a premise-mutation suspect (run 4).
KILLERS=$(grep -oE "^Test Case '[^']+' failed" "$RUN_LOG" \
          | sed -E "s/^Test Case '([^']+)' failed/\1/" | sort -u)
KILL_COUNT=$(printf '%s\n' "$KILLERS" | grep -c . || true)
echo "  killed by $KILL_COUNT of $RAN that ran:"
printf '%s\n' "$KILLERS" | sed 's/^/    /'

# SKIPPED TESTS ARE NOT PASSING TESTS: a probe where the INTENDED regression
# skipped and an unrelated test killed the mutant printed "killed by 1 of 2",
# indistinguishable from the premise-suspect pattern while the intended test
# never ran its body. This repo has conditional live-server and descriptor-canary
# skips, so it is not hypothetical.
report_skips
