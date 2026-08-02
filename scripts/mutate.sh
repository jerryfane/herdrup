#!/usr/bin/env bash
# Mutation harness. Every mutation asserts it APPLIED before the result is
# trusted: three silent no-op mutations this week made green runs look like
# working guards, because the target string had drifted and sed matched nothing.
#
# Usage: scripts/mutate.sh <name> "<target>" "<replacement>" <test-filter>
# Exits non-zero if the mutation did not apply, or if the named test still passes
# with the production code broken.
set -uo pipefail
export PATH=/opt/swift/usr/bin:$PATH

NAME="$1"; TARGET="$2"; REPLACEMENT="$3"; FILTER="$4"
FILE="${5:-Sources/HerdrKit/SSHTransport.swift}"
BACKUP="$(mktemp)"
cp "$FILE" "$BACKUP"
restore() { cp "$BACKUP" "$FILE"; rm -f "$BACKUP"; }
trap restore EXIT

python3 - "$FILE" "$TARGET" "$REPLACEMENT" <<'PY' || { echo "MUTATION '$NAME' DID NOT APPLY — target absent, result would be meaningless"; exit 2; }
import sys
path, target, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
source = open(path).read()
if target not in source:
    sys.exit(1)
open(path, "w").write(source.replace(target, replacement, 1))
PY

echo "--- mutation '$NAME' applied; expecting $FILTER to FAIL ---"
# Bounded: a mutation that makes the suite hang has not been killed by a test,
# it has escaped one, and an unbounded run would hide that as a stall.
if timeout 300 swift test --filter "$FILTER" >/tmp/mutate-$$.log 2>&1; then
    echo "SURVIVED: $FILTER still passes with '$NAME' broken. The test does not guard it."
    tail -5 /tmp/mutate-$$.log
    rm -f /tmp/mutate-$$.log
    exit 1
fi
echo "KILLED: $FILTER fails when '$NAME' is broken."
grep -E "error:|XCTAssert|failed" /tmp/mutate-$$.log | head -4
rm -f /tmp/mutate-$$.log
