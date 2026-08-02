#!/usr/bin/env bash
# Dispatch a review AND sample the job payload's head_sha twice: once as close
# to QUEUE time as the CLI allows, and once after the job reaches a terminal
# state.
#
# Why this exists: gitmoot #1415's model says the job record is re-derived from
# the (reused, stale) worktree at EXECUTION. A single post-hoc read cannot
# distinguish that from a stale value written at DISPATCH — both leave the same
# end state. gitmoot-coc measured one job as correct at queue and stale after
# running; this lane measured one job as stale, but at an unknown point in its
# lifecycle, so it could not confirm which write site was responsible.
#
# The failure mode being avoided is letting ONE read stand for a value that
# mutates during its own lifetime. The queue sample is therefore taken in the
# same command as the dispatch, before anything else runs.
#
# Usage: scripts/dispatch-and-sample-head.sh <agent> <pr> <head-sha> <message-file>
set -uo pipefail

AGENT="$1"; PR="$2"; HEAD_SHA="$(git rev-parse "$3")"; MESSAGE_FILE="$4"
# FULL sha, always. The engine's head-mismatch guard compares the checkout head
# to the job head as LITERAL STRINGS, so an abbreviated --head-sha fails closed
# against the very commit it names: "checkout head is 0871cb381e51..., not
# review job head 0871cb3". Three auto-retries burn and the job dies.
#
# It had never surfaced because on a REUSED worktree the resync overwrites the
# head before the guard runs, so the guard never fired on this lane's dispatches
# at all. PR #15 was a FRESH task, the worktree was correct, the guard ran — and
# rejected a matching commit on formatting.
REPO="jerryfane/herdr-ios"

payload_head() {   # $1 = job id; prints head_sha or empty
  gitmoot job show "$1" --json 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    p=d.get('payload'); p=json.loads(p) if isinstance(p,str) else p
    print((p or {}).get('head_sha',''))
except Exception:
    print('')
"
}
job_state() {
  gitmoot job show "$1" --json 2>/dev/null | python3 -c "
import sys,json
try: print((json.load(sys.stdin).get('job') or {}).get('State',''))
except Exception: print('')
"
}

DISPATCH="$(gitmoot orchestrate "$AGENT" "$(cat "$MESSAGE_FILE")" \
  --repo "$REPO" --pr "$PR" --head-sha "$HEAD_SHA" --action review 2>&1)"
JOB="$(printf '%s\n' "$DISPATCH" | grep -o 'local-review-[A-Za-z0-9._-]*' | tail -1)"
if [ -z "$JOB" ]; then
  printf 'dispatch produced no job id:\n%s\n' "$DISPATCH" >&2; exit 2
fi

# SAMPLE 1 — as early as reachable. The state is recorded ALONGSIDE the value:
# a queue sample that was actually taken after the job started running proves
# nothing, and recording the state is the only way to know which happened.
Q_STATE="$(job_state "$JOB")"
Q_HEAD="$(payload_head "$JOB")"

printf 'job=%s\nrequested=%s\nsample1_state=%s\nsample1_head=%s\n' \
  "$JOB" "$HEAD_SHA" "${Q_STATE:-unknown}" "${Q_HEAD:-unreadable}"

# SAMPLE 2 — after the job stops moving.
for _ in $(seq 1 240); do
  case "$(job_state "$JOB")" in
    succeeded|failed|cancelled|error|timeout) break ;;
  esac
  sleep 15
done
T_STATE="$(job_state "$JOB")"
T_HEAD="$(payload_head "$JOB")"
printf 'sample2_state=%s\nsample2_head=%s\n' "${T_STATE:-unknown}" "${T_HEAD:-unreadable}"

# The verdict is stated here rather than left to the reader, because the whole
# point is which WRITE SITE is implicated, not which values appeared.
if [ "$Q_HEAD" = "$HEAD_SHA" ] && [ "$T_HEAD" != "$HEAD_SHA" ]; then
  echo "verdict=execution_overwrite (correct at sample 1, stale at sample 2)"
elif [ "$Q_HEAD" != "$HEAD_SHA" ] && [ "$Q_STATE" = "queued" ]; then
  echo "verdict=dispatch_write (already stale while still queued: a SECOND write site)"
elif [ "$Q_HEAD" != "$HEAD_SHA" ]; then
  echo "verdict=inconclusive (stale at sample 1, but state was '${Q_STATE}', not queued)"
else
  echo "verdict=no_overwrite_observed (requested head held at both samples)"
fi
