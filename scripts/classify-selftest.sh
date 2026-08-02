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

# Builds an INTERNALLY CONSISTENT XCTest log: one terminal line per test, an
# aggregate whose counts match those lines, and a verdict matching whether any
# failed. Hand-written fixtures drifted — several described logs XCTest cannot
# emit (a failed case under a passed aggregate, one case line against "Executed
# 3"), which taught the classifier those were normal. A fixture is a
# SPECIFICATION of what the tool really produces, so the consistent shape is
# generated and only the deliberate contradictions are written by hand.
#
# mklog <passed> <failed> <skipped>
mklog() {
    local np="$1" nf="$2" ns="$3" i out=""
    for i in $(seq 1 "$np"); do out="${out}Test Case 'S.testPass$i' passed (0.0 seconds)\n"; done
    for i in $(seq 1 "$nf"); do out="${out}Test Case 'S.testFail$i' failed (0.0 seconds)\n"; done
    for i in $(seq 1 "$ns"); do out="${out}Test Case 'S.testSkip$i' skipped (0.0 seconds)\n"; done
    local total=$((np + nf + ns))
    local verdict=passed; [ "$nf" -gt 0 ] && verdict=failed
    # XCTest's ACTUAL grammar, not a convenient uniform one. It uses singular at
    # 1 ("Executed 1 test", "1 test skipped", "1 failure") and OMITS the skip
    # clause entirely at zero. Emitting plural everywhere made every generated
    # fixture agree with a parser that only handled plural: mutating the parser
    # from `tests?` to `tests` left all 18 fixtures passing while a real
    # one-test log classified INVALID. A generator that is wrong is wrong in
    # every fixture at once — which I named as the risk when I introduced it,
    # and then shipped anyway.
    local t="tests"; [ "$total" -eq 1 ] && t="test"
    local fl="failures"; [ "$nf" -eq 1 ] && fl="failure"
    local skipclause=""
    if [ "$ns" -gt 0 ]; then
        local st="tests"; [ "$ns" -eq 1 ] && st="test"
        skipclause="with $ns $st skipped and "
    else
        skipclause="with "
    fi
    out="${out}Test Suite 'Selected tests' $verdict at 2026-01-01 00:00:00.000\n"
    out="${out}\t Executed $total $t, ${skipclause}$nf $fl (0 unexpected) in 0.1 seconds"
    printf '%b' "$out"
}

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
expect crash-after-failure 2 "A crash is not a kill" 1 "$(mklog 0 1 0)
error: Exited with unexpected signal code 4"

# 2. THE HIGH FROM ROUND TWO. Every matched test skipped was reported SURVIVED —
#    'the test does not guard it' — about a guard that never ran.
expect all-skipped 2 "every matched test SKIPPED" 0 "$(mklog 0 0 1)"

# 3. THE DENOMINATOR. A skip must not be counted as a test that ran.
expect survived-with-skip 1 "1 of 2 ran" 0 "$(mklog 1 0 1)"
expect killed-with-skip 0 "killed by 1 of 1 that ran" 1 "$(mklog 0 1 1)"

# 4. AN INCOMPLETE RUN IS NOT A KILL. A genuine failure and a completed
#    COMPONENT summary, then no aggregate: previously KILLED. Status 1, not 137,
#    or the signal check catches it first and this never reaches the aggregate
#    requirement it was written for.
expect incomplete-run 2 "did not complete" 1 "Test Case 'A.testX' failed (0.0 seconds)
Test Suite 'A' failed at 2026-01-01 00:00:00.000
	 Executed 4 tests, with 1 failure (0 unexpected) in 0.1 seconds"

# 4b. A SIGNAL AFTER THE AGGREGATE IS NOT A KILL. SwiftPM keeps working after
#     XCTest's terminator, so a SIGKILL can land past it with no crash text.
expect signal-after-aggregate 2 "terminated by signal 9" 137 "$(mklog 0 1 0)"

# 4c. CONTRADICTORY INPUTS ARE NOT VERDICTS — written by hand, because these are
#     precisely the logs XCTest cannot emit.
expect aggregate-passed-status-nonzero 2 "Contradictory" 1 "Test Case 'S.testPass1' passed (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 1 tests, with 0 tests skipped and 0 failures (0 unexpected) in 0.1 seconds"

expect aggregate-failed-status-zero 2 "Contradictory" 0 "Test Case 'S.testFail1' failed (0.0 seconds)
Test Suite 'Selected tests' failed at 2026-01-01 00:00:00.000
	 Executed 1 tests, with 0 tests skipped and 1 failures (0 unexpected) in 0.1 seconds"

expect failed-case-under-passed-aggregate 2 "a test case FAILED" 0 "Test Case 'S.testFail1' failed (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 1 tests, with 0 tests skipped and 1 failures (0 unexpected) in 0.1 seconds"

expect case-count-disagrees 2 "terminal case lines" 0 "Test Case 'S.testPass1' passed (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 3 tests, with 0 tests skipped and 0 failures (0 unexpected) in 0.1 seconds"

expect skip-count-disagrees 2 "skipped case lines" 0 "Test Case 'S.testPass1' passed (0.0 seconds)
Test Case 'S.testPass2' passed (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 2 tests, with 1 tests skipped and 0 failures (0 unexpected) in 0.1 seconds"

# 4d. A STATUS ABOVE THE SIGNAL RANGE IS NOT A SIGNAL.
expect status-above-signal-range 2 "above the range" 200 "$(mklog 0 1 0)"

# 4e. EACH GRAMMAR BRANCH. Singular at one, the omitted zero-skip clause, and
#     singular "failure" — the forms a plural-only parser silently breaks on.
expect singular-one-test 1 "1 of 1 ran" 0 "$(mklog 1 0 0)"
expect singular-one-failure 0 "killed by 1 of 1 that ran" 1 "$(mklog 0 1 0)"
expect singular-one-skip 2 "every matched test SKIPPED" 0 "$(mklog 0 0 1)"

# 4f. THE AGGREGATE MUST AGREE WITH ITS OWN FAILURE COUNT.
expect passed-aggregate-nonzero-failures 2 "reports 1 failures" 0 "Test Case 'S.testPass1' passed (0.0 seconds)
Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds"

expect failed-aggregate-zero-failures 2 "reports 0 failures" 1 "Test Case 'S.testFail1' failed (0.0 seconds)
Test Suite 'Selected tests' failed at 2026-01-01 00:00:00.000
	 Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds"

# 5. THE ESTABLISHED CASES, so this file pins what already worked.
expect hang 3 "A hang is not a kill" 124 "Test Case 'S.testA' started"
expect no-tests-matched 2 "matched no tests" 0 "Test Suite 'Selected tests' passed at 2026-01-01 00:00:00.000
	 Executed 0 tests, with 0 tests skipped and 0 failures (0 unexpected) in 0.0 seconds"
# Previously "broke-not-failed", expecting the no-failure-line branch. The
# failure-count check now catches this log FIRST and says something more precise,
# so the expectation moves rather than the log. Worth recording: with the
# consistency checks in place, the no-failure-line branch is unreachable for any
# internally consistent log — an aggregate can only say FAILED with a nonzero
# count, and a nonzero count with no failed case line is itself rejected. It is
# kept as a backstop for logs no check anticipated, not because a fixture can
# still reach it.
expect failed-aggregate-no-failures 2 "reports 0 failures" 1 "Test Case 'S.testPass1' passed (0.0 seconds)
Test Suite 'Selected tests' failed at 2026-01-01 00:00:00.000
	 Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds"
expect plain-survived 1 "still passes" 0 "$(mklog 3 0 0)"
expect plain-killed 0 "killed by 1 of 3 that ran" 1 "$(mklog 2 1 0)"

# 6. THE KILLER SET IS NAMED, not just counted — the split is the finding.
expect names-its-killers 0 "S.testFail2" 1 "$(mklog 2 2 0)"

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
