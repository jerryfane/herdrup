# Standing review header — jerryfane/herdr-ios

Prepend verbatim to every review dispatch in this lane.

## 1. Establish which code you reviewed, and NAME it

**Archive the PR's current head yourself and review that.** Do not trust the
job's pinned SHA, and do not review the shared worktree
(`/root/.gitmoot/worktrees/jerryfane--herdr-ios/review-pr-<N>-<id>`) without
first confirming its HEAD matches the head you intend.

**State in `Tests Run`: the exact head you archived, and the diff range you
examined.** That line is load-bearing evidence, not a formality — it is
currently the only channel that reports which code a verdict actually covers.

**Why this is a requirement and not a courtesy:** C1 of gitmoot#1354 made the
review task id stable rather than head-derived, so the worktree keyed by it is
reused and never re-synced. On this repo, five consecutive dispatches recorded a
head two commits stale while the verdicts were correct. The correctness came
from *somewhere* — reviewer habit, or an explicitly-passed `--head-sha`; the
lane's own data cannot distinguish them. A compensating behaviour nobody
designed as a safeguard is not a safeguard. This header makes it one.

## 2. Standing verification clauses

- Mutants must BUILD. A mutation that fails to compile proves nothing about the
  tests; classify it INVALID, not KILLED.
- A crash (signal 4) is not a kill. An assertion followed by a force-unwrap
  turns a real failure into an unclassifiable run — use `XCTUnwrap`.
- Check the PRECONDITION arms the hazard. A test whose setup never reaches the
  condition under test passes for reasons unrelated to its name; on this repo
  that has been the cause more often than a weak assertion.
- Restore per-file after probing; leave the worktree clean.

## 3. What this lane wants from a review

Disagreement, with a demonstration. Every round on #10 and #11 that found
something real found it by running a probe, not by reading. A verdict that
agrees is worth less than one that reproduces.
