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
# The file is REQUIRED. It used to default to Sources/HerdrKit/SSHTransport.swift,
# which no longer exists — and a missing FILE left an empty mktemp backup that the
# EXIT trap then copied BACK, resurrecting the target as a 0-byte file. Fail fast
# instead, before any backup is taken.
FILE="${5:-}"
if [ -z "$FILE" ]; then
    echo "usage: scripts/mutate.sh <name> \"<target>\" \"<replacement>\" <test-filter> <file>  (file is required)"
    exit 2
fi
if [ ! -f "$FILE" ]; then
    echo "INVALID: mutation target file '$FILE' does not exist"
    exit 2
fi
BACKUP="$(mktemp)"
BUILD_LOG="$(mktemp)"
RUN_LOG="$(mktemp)"
cp "$FILE" "$BACKUP"
# Only restore from a non-empty backup, so a botched backup can never truncate FILE.
restore() { [ -s "$BACKUP" ] && cp "$BACKUP" "$FILE"; rm -f "$BACKUP" "$BUILD_LOG" "$RUN_LOG"; }
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
# --no-parallel IS PART OF THE PARSER CONTRACT, not a preference. Under
# --parallel, XCTest emits neither "All tests" nor "Selected tests", so the
# aggregate terminator the classifier requires never appears and every run
# classifies INVALID. It was the default before and this made it explicit;
# supporting the parallel format is a separate change.
timeout 300 swift test --no-parallel --filter "$FILTER" >"$RUN_LOG" 2>&1
STATUS=$?

# CLASSIFICATION LIVES IN ITS OWN SCRIPT so it can be demonstrated without a
# Swift run — see scripts/classify-selftest.sh, which feeds it the exact logs it
# used to misread. Three mis-reports were fixed here with no evidence they fired.
#
# NOT `exec`. The first rewire used it, which REPLACES this shell and therefore
# skips the EXIT trap that restores the file — the mutation was left applied in
# the working tree, silently, and every later run would have measured mutated
# source. Caught by checking `git status` after the very first rewired run, which
# is the check worth keeping: a harness that edits the tree must be verified to
# have un-edited it.
scripts/classify-run.sh "$NAME" "$FILTER" "$STATUS" "$RUN_LOG"
exit $?
