# Standing review header — jerryfane/herdr-ios

Prepend verbatim to every review dispatch in this lane.

## 1. Establish which code you reviewed, and NAME it

**Read the commit through local plumbing rather than trusting the working
tree.** This needs no network and no auth, so it cannot fail closed:

```
git cat-file -t <sha>                              # the gate: object present?
git diff $(git merge-base <sha> origin/main)..<sha>
git show <sha>:<path>
```

Do not review the shared worktree
(`/root/.gitmoot/worktrees/jerryfane--herdr-ios/review-pr-<N>-<id>`) without
first confirming its HEAD matches the head you intend. If you *can* reach the
PR's live head, archive it yourself and review that; if you cannot, review the
pinned SHA through the plumbing above and say which you did.

**State in `Tests Run` BOTH the SHA you reviewed AND the worktree HEAD you
found**, even when they agree — especially when they agree.

That pairing is the whole mechanism, and it is why this is a requirement rather
than advice: it turns an instruction into a **detector**. A reviewer that
quietly skips the plumbing is caught by the mismatch in its own output, at
verdict time, instead of by someone diffing afterwards — or never. *An
instruction that cannot detect its own violation is a hope.* Apply that test to
any review contract written in this lane, not just this one.

**Two traps that have already fired here:**

- `gitmoot job show`'s verdict summary begins with the **worktree** SHA. Never
  parse that field for currency; it displays the stale commit by construction.
- A `policy: read-only` reviewer has no network and no valid auth. A brief
  demanding verification against the PR's *live* head therefore fails closed
  forever — six blocked rounds elsewhere proved it. The plumbing path above is
  the reason this header does not have that failure mode. Do not "fix" it by
  granting the reviewer network: that expands privilege on the least-privileged
  party to perform a check the merge gate already does without a race.

**The job record is not evidence, and it is not a second witness.** The value is
stored correctly when the job is queued and REPLACED FROM THE WORKTREE during
execution (measured: `queued → 3b04cd0`, `running → e02e40ba`, same job). So a
stale checkout produces a record that agrees with it — self-consistent and
wrong.

The trap is subtler than "the record can be stale": *record agrees with
worktree* looks like corroboration and is not. The record is DERIVED from the
worktree, so the two agree by construction, including when both are wrong.
Counting that as two surfaces is reading one fact twice and calling it two
witnesses — a derived value is never independent evidence of the thing it was
derived from. **There are two independent surfaces:** (record ≡ worktree), and
the head the verdict names. Compare both against the PR head; agreement between
*those* means something.

**Why this is a requirement and not a courtesy:** C1 of gitmoot#1354 made the
review task id stable rather than head-derived, so the worktree keyed by it is
reused and never re-synced. On this repo, five consecutive dispatches recorded a
head two commits stale while the verdicts were correct. The correctness came
from *somewhere* — reviewer habit, or an explicitly-passed `--head-sha`; the
lane's own data could not distinguish them at the time. A compensating
behaviour nobody designed as a safeguard is not a safeguard. This header makes
it one.

That question has since been settled, and the answer removes the more
comfortable option: a dispatch passing `--head-sha c340f2b` against a reused
task recorded `e02e40ba`, three rounds stale. **`--head-sha` is not a
mitigation.** Reviewer habit — this header — is the only thing standing
between a reused worktree and a confident verdict on the wrong commit. On #11
that mattered: at the stale head the guard under review still existed, so a
review of the assigned worktree would have returned clean on a head containing
a live race.

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
