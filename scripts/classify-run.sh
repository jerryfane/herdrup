#!/usr/bin/env bash
# Classify one mutation run from its log and exit status. No Swift, no
# filesystem mutation, no network — a pure function of (log, status).
#
# EXTRACTED SO IT CAN BE DEMONSTRATED. The classifier had three mis-reports
# fixed in one PR and nothing exercised it: the evidence was that re-running the
# usual mutants produced the usual answers, which is REGRESSION evidence, not
# FIRING evidence — none of the usual mutants was one of the broken cases. A
# harness whose fixes are attested only by its author is an instrument agreeing
# with itself, which is the exact failure this lane spent a day correcting
# elsewhere. Separating it from `swift test` is what makes classify-selftest.sh
# possible.
#
# Usage: classify-run.sh <name> <filter> <status> <run-log>
# Prints the verdict; exits 0 KILLED, 1 SURVIVED, 2 INVALID, 3 ESCAPED.
set -uo pipefail

NAME="$1"; FILTER="$2"; STATUS="$3"; RUN_LOG="$4"

if [ "$STATUS" -eq 124 ]; then
    echo "ESCAPED: '$NAME' made $FILTER hang. A hang is not a kill."
    exit 3
fi

# A CRASH ANYWHERE IN THE RUN IS NOT A KILL, even when an earlier suite already
# recorded a failure. A two-suite probe made suite 1 fail one assertion and
# suite 2 die with signal 4; the failure line and suite 1's count were both
# present, so this reported "KILLED (1 tests)" and hid the crash entirely — the
# exact rule this harness exists to enforce, broken by the harness.
if grep -qE "Exited with unexpected signal code|Program crashed|Fatal error" "$RUN_LOG"; then
    echo "INVALID: '$NAME' crashed the run. A crash is not a kill, even after a failure."
    grep -m2 -E "Exited with unexpected signal code|Program crashed|Fatal error" "$RUN_LOG"
    exit 2
fi

# A SIGNAL-DERIVED STATUS IS NOT A FAILURE, even when the log looks complete.
# Shells report a signalled child as 128+N, so 137 is SIGKILL and 139 SIGSEGV.
# SwiftPM keeps working AFTER XCTest prints its aggregate — its own footer comes
# later — so a kill can land past the terminator with no crash text flushed. A
# synthetic complete summary plus status 137 was classified KILLED before this.
# 124 is the timeout, handled above as ESCAPED.
# 129..192 is 128+signal for signals 1..64. ABOVE that a status is not
# necessarily a signal — GNU timeout propagates the command's own status, and
# this host's shell does not recognise 193+ as signalled (kill -l 65 is
# rejected). Still INVALID, because an exit above 128 from `swift test` is not a
# verdict either way, but the message no longer invents a signal number.
# The 124 timeout is handled above as ESCAPED and never reaches here.
if [ "$STATUS" -ge 129 ] && [ "$STATUS" -le 192 ]; then
    echo "INVALID: '$NAME' was terminated by signal $((STATUS - 128)) (status $STATUS). Not a kill."
    exit 2
fi
if [ "$STATUS" -gt 192 ]; then
    echo "INVALID: '$NAME' exited $STATUS — above the range swift test reports. Not a verdict."
    exit 2
fi

# THE RUN MUST HAVE COMPLETED. XCTest closes with an AGGREGATE suite line —
# "All tests" unfiltered, "Selected tests" under --filter — and without it the
# run ended early however normal its earlier lines look.
#
# Taking the last "Executed N" without this check classified an OOM/SIGKILL as a
# KILL: a probe supplied a genuine failed test, its completed COMPONENT-suite
# summary, then status 137 and no aggregate. That reported KILLED with exit 0.
# An incomplete run is indistinguishable from a completed one by its prefix, so
# the terminator is the only evidence that there was no more to come.
AGGREGATE=$(grep -oE "^Test Suite '(All tests|Selected tests)' (passed|failed)" "$RUN_LOG" \
            | tail -1 | grep -oE "(passed|failed)$")
if [ -z "$AGGREGATE" ]; then
    echo "INVALID: '$NAME' produced no aggregate suite summary — the run did not complete (status $STATUS)."
    tail -3 "$RUN_LOG"
    exit 2
fi

# THE AGGREGATE VERDICT AND THE EXIT STATUS MUST AGREE. Matching the terminator
# and then discarding what it SAID let two contradictions through: a failed test
# with "Selected tests passed" and status 1 classified KILLED, and a failed
# aggregate with status 0 classified SURVIVED. XCTest does not produce either,
# so seeing one means the log and the status came from different places — a
# wrapper, a tee, a truncated read — and no verdict drawn from them is sound.
if [ "$AGGREGATE" = "passed" ] && [ "$STATUS" -ne 0 ]; then
    echo "INVALID: '$NAME' — aggregate says PASSED but the run exited $STATUS. Contradictory; no verdict."
    exit 2
fi
if [ "$AGGREGATE" = "failed" ] && [ "$STATUS" -eq 0 ]; then
    echo "INVALID: '$NAME' — aggregate says FAILED but the run exited 0. Contradictory; no verdict."
    exit 2
fi

# THE AGGREGATE AND THE CASE DETAIL MUST DESCRIBE THE SAME RUN. The two checks
# above compare the aggregate to the exit STATUS; these compare it to the log's
# own contents. Probes got confident verdicts out of logs XCTest cannot emit: a
# failed case under a passed aggregate with status 0 returned SURVIVED, and one
# terminal case line against "Executed 3" returned SURVIVED with a denominator
# of 3.
#
# NOT compared: the aggregate's FAILURE COUNT against the number of failed case
# lines. One case with two failing assertions reports "2 failures", so those
# numbers legitimately differ — the boolean "any failure at all" is the only
# safe comparison on that axis.
if [ "$AGGREGATE" = "passed" ] && grep -q "^Test Case .* failed" "$RUN_LOG"; then
    echo "INVALID: '$NAME' — aggregate says PASSED but a test case FAILED. Contradictory; no verdict."
    exit 2
fi

# From the AGGREGATE summary — the Executed line following that terminator — not
# the largest component and not merely the last line. A filter spanning two
# suites reports each separately and then a total.
EXECUTED=$(awk "/^Test Suite '(All tests|Selected tests)' (passed|failed)/{f=1;next} f&&/Executed [0-9]+ tests?/{print;exit}" "$RUN_LOG" \
           | grep -oE "[0-9]+" | head -1)
EXECUTED=${EXECUTED:-0}
if [ "$EXECUTED" -eq 0 ]; then
    echo "INVALID: filter '$FILTER' matched no tests — nothing was exercised"
    exit 2
fi

# SKIPS ARE ACCOUNTED FOR ABOVE BOTH VERDICTS, not on the kill path only. The
# first version printed them after the KILLED branch, so the SURVIVED branch
# exited before looking: a filter matching ONE skipping test reported "SURVIVED
# — the test does not guard it", which is the worst output this tool can
# produce, because SURVIVED is an instruction to go rewrite a guard that never
# executed.
SKIPPED=$(grep -oE "^Test Case '[^']+' skipped" "$RUN_LOG" \
          | sed -E "s/^Test Case '([^']+)' skipped/\1/" | sort -u)
SKIP_COUNT=$(printf '%s\n' "$SKIPPED" | grep -c . || true)

# EVERY EXECUTED TEST MUST HAVE A TERMINAL LINE, and the aggregate's skip count
# must match the skipped lines. Without this the denominator came from one
# surface and the numerator from another, and neither noticed the other was
# describing a different run.
TERMINAL_CASES=$(grep -cE "^Test Case '[^']+' (passed|failed|skipped)" "$RUN_LOG" || true)
if [ "$TERMINAL_CASES" -ne "$EXECUTED" ]; then
    echo "INVALID: '$NAME' — aggregate says $EXECUTED executed but the log has $TERMINAL_CASES terminal case lines. Contradictory; no verdict."
    exit 2
fi
AGG_SKIPS=$(awk "/^Test Suite '(All tests|Selected tests)' (passed|failed)/{f=1;next} f&&/Executed [0-9]+ tests?/{print;exit}" "$RUN_LOG" \
            | grep -oE "[0-9]+ tests? skipped" | grep -oE "^[0-9]+")
AGG_SKIPS=${AGG_SKIPS:-0}
if [ "$AGG_SKIPS" -ne "$SKIP_COUNT" ]; then
    echo "INVALID: '$NAME' — aggregate says $AGG_SKIPS skipped but the log has $SKIP_COUNT skipped case lines. Contradictory; no verdict."
    exit 2
fi
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

echo "KILLED: $FILTER ($RAN of $EXECUTED ran) fails when '$NAME' is broken."
grep -m3 -E "^/.*error: .*XCTAssert|^Test Case .* failed" "$RUN_LOG"

# WHICH tests killed it, not just that something did. A kill is a PATTERN: on
# #13 round one a compiling no-op survived the two tests written for it and was
# killed by an unrelated one, and that SPLIT was the evidence those two were
# vacuous — available a round before any premise mutation and discarded because
# the output said only "KILLED".
#
# If a mutation is killed only by tests OTHER than the one written for it, that
# named test is a premise-mutation suspect.
KILLERS=$(grep -oE "^Test Case '[^']+' failed" "$RUN_LOG" \
          | sed -E "s/^Test Case '([^']+)' failed/\1/" | sort -u)
KILL_COUNT=$(printf '%s\n' "$KILLERS" | grep -c . || true)
echo "  killed by $KILL_COUNT of $RAN that ran:"
printf '%s\n' "$KILLERS" | sed 's/^/    /'
report_skips
exit 0
