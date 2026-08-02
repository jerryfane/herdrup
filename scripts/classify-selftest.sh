#!/usr/bin/env bash
# Demonstrates the mutation classifier against synthetic run logs.
#
# WHY THIS EXISTS: three mis-reports were fixed in the classifier and nothing in
# the diff showed the fixes FIRE. Re-running the usual mutants shows the answers
# did not change — regression evidence — but none of the usual mutants is a
# crash-after-failure, an all-skipped run, or a mixed-skip denominator, so the
# broken cases were attested only by their author. Every case below is one the
# classifier got WRONG before, expressed as a log it must now read correctly.
#
# Synthetic logs rather than real runs, deliberately: a crash-after-failure is
# hard to provoke on demand and impossible to provoke reliably, and the
# classifier's input IS the log, so feeding it the log tests the whole of what
# it does.
set -uo pipefail
cd "$(dirname "$0")/.."
CLASSIFY=scripts/classify-run.sh
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILURES=0

# expect <case> <expected-exit> <expected-substring> <status> <log-body>
expect() {
    local case_name="$1" want_exit="$2" want_text="$3" status="$4" body="$5"
    local log="$TMP/$case_name.log"
    printf '%s\n' "$body" > "$log"
    local out; out="$("$CLASSIFY" "probe" "SomeFilter" "$status" "$log" 2>&1)"; local got=$?
    if [ "$got" -ne "$want_exit" ] || ! printf '%s' "$out" | grep -qF "$want_text"; then
        echo "FAIL $case_name: exit $got (want $want_exit), output:"
        printf '%s\n' "$out" | sed 's/^/      /'
        FAILURES=$((FAILURES+1))
    else
        echo "ok   $case_name"
    fi
}

# 1. THE HIGH FROM ROUND ONE. A completed failure followed by a crash was
#    reported KILLED, hiding the crash and taking its denominator from the one
#    suite that finished.
expect crash-after-failure 2 "A crash is not a kill" 1 "Test Case 'S.testA' failed (0.1 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds
error: Exited with unexpected signal code 4"

# 2. THE HIGH FROM ROUND TWO. Every matched test skipped was reported SURVIVED —
#    'the test does not guard it' — about a guard that never ran.
expect all-skipped 2 "every matched test SKIPPED" 0 "Test Case 'S.testOnly' skipped (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 0.0 seconds"

# 3. THE DENOMINATOR. A skip must not be counted as a test that ran.
expect survived-with-skip 1 "1 of 2 ran" 0 "Test Case 'S.testRuns' passed (0.0 seconds)
Test Case 'S.testSkips' skipped (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.0 seconds"

expect killed-with-skip 0 "killed by 1 of 1 that ran" 1 "Test Case 'S.testKills' failed (0.0 seconds)
Test Case 'S.testSkips' skipped (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 2 tests, with 1 test skipped and 1 failure (0 unexpected) in 0.0 seconds"

# 4. THE PARTIAL-SUITE DENOMINATOR. Two suites report separately and then a
#    total; the largest COMPONENT is not the total.
expect terminal-denominator 0 "killed by 1 of 5 that ran" 1 "Test Case 'A.testX' failed (0.0 seconds)
Test Suite 'A' failed at 2026-01-01 00:00:00.000
	 Executed 4 tests, with 1 failure (0 unexpected) in 0.1 seconds
Test Suite 'B' passed at 2026-01-01 00:00:00.000
	 Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds
Test Suite 'Selected tests' failed at 2026-01-01 00:00:00.000
	 Executed 5 tests, with 1 failure (0 unexpected) in 0.2 seconds"

# 4b. AN INCOMPLETE RUN IS NOT A KILL. A genuine failure and a completed
#     COMPONENT summary, then SIGKILL and no aggregate: previously KILLED.
# Status 1, NOT 137: a signalled status is caught by the signal check above, so
# using one here would have tested that check twice and the aggregate check
# never. Isolating it needs an ordinary failure exit with no terminator.
expect incomplete-run 2 "did not complete" 1 "Test Case 'A.testX' failed (0.0 seconds)
Test Suite 'A' failed at 2026-01-01 00:00:00.000
	 Executed 4 tests, with 1 failure (0 unexpected) in 0.1 seconds"

# 4c. A SIGNAL AFTER THE AGGREGATE IS NOT A KILL. SwiftPM keeps working after
#     XCTest's terminator, so a SIGKILL can land past it with no crash text.
expect signal-after-aggregate 2 "terminated by signal 9" 137 "Test Case 'A.testX' failed (0.0 seconds)
Test Suite 'Selected tests' failed at 2026-01-01 00:00:00.000
	 Executed 4 tests, with 1 failure (0 unexpected) in 0.1 seconds"

# 5. THE ESTABLISHED CASES, so this file also pins what already worked.
expect hang 3 "A hang is not a kill" 124 "Test Case 'S.testA' started"
expect no-tests-matched 2 "matched no tests" 0 "Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.0 seconds"
expect broke-not-failed 2 "the run broke, it did not fail" 1 "Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.1 seconds"
expect plain-survived 1 "still passes" 0 "Test Case 'S.testA' passed (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.1 seconds"
expect plain-killed 0 "killed by 1 of 3 that ran" 1 "Test Case 'S.testA' failed (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 3 tests, with 1 failure (0 unexpected) in 0.1 seconds"

# 6. THE KILLER SET IS NAMED, not just counted — the split is the finding.
expect names-its-killers 0 "S.testSecond" 1 "Test Case 'S.testFirst' failed (0.0 seconds)
Test Case 'S.testSecond' failed (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 4 tests, with 2 failures (0 unexpected) in 0.1 seconds"

# 7. THE HARNESS MUST UN-EDIT THE TREE — ASSERTED BY RUNNING IT.
#
#    The first version grepped mutate.sh for the literal `exec
#    scripts/classify-run.sh`. That caught the exact regression I had made and
#    NOTHING ELSE: review replaced the spelling with `trap - EXIT` immediately
#    before the classifier, every self-test including this one passed, and a
#    real invocation left its target mutated. A check that tests a SPELLING
#    tests the last bug, not the property.
#
#    So it runs mutate.sh against a disposable file and compares bytes. The
#    filter matches no tests deliberately: the classification is irrelevant here
#    and INVALID is the fastest terminal path through the caller, but the file
#    must come back either way.
PROBE="$TMP/restore-probe.txt"
printf 'before\n' > "$PROBE"
BEFORE_HASH="$(cksum < "$PROBE")"
RESTORE_OUT="$(scripts/mutate.sh restore-probe 'before' 'after' \
    'NoSuchTestFilterExistsHere' "$PROBE" 2>&1)"
AFTER_HASH="$(cksum < "$PROBE")"
# THE MUTATION MUST HAVE BEEN APPLIED FOR THE BYTE COMPARISON TO MEAN ANYTHING.
# The first version discarded mutate.sh's output and status, so pointing it at
# an ABSENT target made it exit before touching the file — and "restored
# byte-for-byte" passed on a file nothing had ever changed. A restoration test
# that passes when there was nothing to restore is the vacuous-precondition
# shape, in the file written to catch vacuous preconditions.
if ! printf '%s' "$RESTORE_OUT" | grep -q "applied and compiles"; then
    echo "FAIL restore-trap: the mutation was never applied — the byte comparison proves nothing"
    printf '%s\n' "$RESTORE_OUT" | sed 's/^/      /' | head -3
    FAILURES=$((FAILURES+1))
elif [ "$BEFORE_HASH" != "$AFTER_HASH" ]; then
    echo "FAIL restore-trap: mutate.sh left its target modified — the EXIT trap did not restore it"
    echo "      content now: $(cat "$PROBE")"
    FAILURES=$((FAILURES+1))
else
    echo "ok   restore-trap (applied, then restored byte-for-byte)"
fi

echo
if [ "$FAILURES" -ne 0 ]; then echo "$FAILURES case(s) FAILED"; exit 1; fi
echo "all classifier cases pass"
