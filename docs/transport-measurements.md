# SSH transport cost, measured

Goal v1b task 2.

**Read the caveats with the numbers.** This document has been corrected three
times, each time because a claim outran what was actually measured. What follows
distinguishes what was observed from what was concluded, and says which
conclusions remain unverified.

**Loopback is a floor, not a prediction for cellular.**

> **Batch note, added 2026-08-02:** the tables and figures in the next three
> sections are the earlier 30-sample-era batches, kept as recorded history. The
> randomised runs (Results, below) measured immediate opens at 140.2–177.9 ms
> (run 1) and 143.5–1855.4 ms with a 173.87 ms p95 (run 2, the validated run) —
> both entirely outside the 89.6–102.1 ms range recorded here. Batches differ;
> neither table corrects the other.

## Measured phase latencies

| phase | latency | what it is |
|---|---|---|
| TCP connect | 0.1 ms | negligible |
| SSH handshake / key exchange | 18.6 ms | measured latency of the handshake phase |
| public-key authentication | 20.4 ms | measured latency of the auth phase |
| channel opened immediately after auth | ~96 ms (p50 of one 30-sample batch) | the immediate-open case |
| channel on a session aged 100 ms | 0.28–0.54 ms | the aged-open case |
| missing `TCP_NODELAY` | ~30 ms | fixed, recovered |

These are **phase latencies**, not proof of where the time goes inside each
phase. The handshake and auth figures are plausibly dominated by cryptographic
work, but this measurement times the API call — it does not establish that the
latency is computation rather than round trips or waiting.

## The finding: immediate opens cost more than aged opens

Naming note, after review: earlier versions called this a "readiness delay" and
called aged sessions "ready". Those are **state words for a state nothing here
observed** — the batches establish an association between elapsed time since
authentication and channel-open latency, and no measurement distinguishes "a
session becoming ready" from any other explanation of that association. The
observational vocabulary is used from here on; "readiness experiment" survives
below only as the experiment's proper name.

An earlier version claimed *"the first channel of a session is expensive; every
channel after it is free."* **That is false** — the controls below show a first
channel that is cheap, which the claim forbids.

What replaces it is narrower than the claim it replaces. In these batches,
channel ordinal alone did not predict cost, and elapsed time since
authentication was strongly associated with it. That is an observation about
these runs, not a general statement about what the cost tracks.

| condition | first-channel cost |
|---|---|
| opened immediately after authentication | 89.6–102.1 ms |
| session aged 100 ms first | 0.28–0.54 ms |
| pre-opened sessions | mostly fast, **but included first-open outliers up to 2594 ms** |

**A short delay after authentication is strongly associated with a cheap first
channel.** It is not established that ageing *causes* the improvement, nor that
100 ms is a threshold — the pre-opened control still produced multi-second
outliers, so ageing does not reliably eliminate the cost. An earlier version
said waiting "makes the cost vanish"; that overstates it.

### Consequence for the design

Because `roundTrip` opens a session per request and uses it immediately, every
request lands inside the window where the delay appears.

**Pooling alone would not move this cost** — a pooled session handed out inside
that window pays it too. *If the delay reproduces on the request path*, two
candidate treatments are available:

- **Age gate** — do not hand out a session until it is 100 ms old.
- **Sacrificial channel** — open and free one channel on the session, then hand
  it out.

**The experiment below has now been run and selected the age gate** (see
Results). Before it ran, this section refused to choose — earlier versions named
the sacrificial channel as the design response with no measurement bearing on
it, and a later one said a transition was *required*, which was the conclusion
the experiment existed to reach. The 100-trial C arm is now the first evidence
about the sacrificial channel at all: it cleared the latency margin and was
blocked by the replenishment cap.

## The method lesson — corrected twice

The first version claimed a `p50 = 40.7 ms` was a "confident wrong number" from
a median over a bimodal distribution. **That conflated two datasets:** the
displayed sequence has a median near 0.1 ms; 40.7 ms came from a different run.

The second version blamed "aggregating heterogeneous session states." That is
the likely explanation, but **it cannot be verified**: the original harness kept
only summaries for its 20 sequential opens, and the raw sequence and session-age
metadata were not retained. The attribution is a reasonable reconstruction, not
a demonstrated fact.

What survives, and is directly supported: **print the sequence, and retain it.**
Had the raw samples and their session ages been kept, this would be settled
instead of reconstructed.

## What was ruled out, and how narrowly

- **herdr is not *necessary* for a large delay.** A trivial echo socket with no
  herdr code in the path produced 1877.8 ms in one sampled run against herdr's
  99.7 ms in another. That shows herdr is not required to produce the effect —
  it does **not** show herdr cannot contribute to it independently. Two single
  observations cannot separate those.
- **Not `UseDNS`** — unset; modern OpenSSH defaults it off.
- **Not GSSAPI** — `gssapiauthentication no`, `gssapikeyexchange no`.
- **Not herdr's two-write response pattern.** An earlier claim of ~100 ms per
  request and ~190x was **retracted**: it compared two structurally different
  relay programs. Controlled A/B puts it at roughly 2x, sub-millisecond.
  `jerryfane/herdr#29` stays parked on that evidence.

## What remains unknown

**What explains the immediate-versus-aged latency difference.** The effect is
associated with the period just after authentication, but its mechanism is not
identified — and "the session was not yet ready" is a restatement of the
observation, not an explanation of it, and this document should not be read as locating it in any
particular layer — earlier versions placed it in "the first
`direct-streamlocal` forward of a session," which the measurements do not
support.

**Why some opens take seconds rather than ~96 ms.** Outliers up to 2594 ms
appeared even in the pre-opened control. A multi-second penalty resembles a
timeout or retry more than work, but that is a hypothesis and is untested.

## Consequence for the connection design

**Pool authenticated sessions. Keep channels per-request.**

- Sessions are worth pooling for the ~39 ms of handshake and auth latency, paid
  once instead of per request.
- **The request-path delay reproduced in both randomised runs, and the
  validated run selected the age gate under the preregistered rule** (Results,
  below — including a cap-symmetry caveat found in review after the run). The
  single-run and non-causal limitations stand: a future run under the same
  preregistered rule could select differently, and no treatment effect has been
  estimated.
- Channels are not worth pooling: they are *typically* cheap on an aged
  session — sub-millisecond at the median, but 43 of 100 aged opens in the
  validated run still cost ~100 ms, so "consistently" was falsified — and herdr's command socket is single-shot, so each request needs its
  own regardless.
- The eviction threshold **needs its own basis.** The original plan inherited
  ~3 s from herdr's `INITIAL_REQUEST_TIMEOUT`, which governs herdr's socket, not
  sshd's session.

## The readiness experiment — CANONICAL

**This section is the single source for the experiment and its decision
procedure.** `docs/connection-pool-design.md` references it and must not restate
any threshold; two copies of a rule drifted apart once already and prescribed
different outcomes for the same numbers.

An earlier version compared an immediate first-channel open against an aged one
and called that the falsifier. It tests **waiting**, and waiting is only one of
the two candidates — an experiment that never opens a sacrificial channel cannot
say anything about opening one.

Three arms, each starting from a **fresh authenticated session**:

| arm | treatment | what it isolates |
|---|---|---|
| **A** immediate | open the measured channel straight after auth | request `p95` with no treatment |
| **B** age-only | idle 100 ms, then open the measured channel | request `p95` after a 100 ms idle |
| **C** prewarmed | open and free a sacrificial `direct-streamlocal` channel, then open the measured channel | request `p95` after a sacrificial open |

Method:

- **n = 100 per arm**, 300 sessions total, arms **interleaved in randomised
  order**. This balances machine load and thermal drift across arms **in
  expectation only** — one 300-session run can still land drift unevenly. A
  blocked run of A followed by a blocked run of C would confound treatment with
  time outright; randomisation removes the systematic version of that, not the
  sampled one. The realised order and a per-trial start timestamp are retained
  so temporal imbalance can be inspected rather than assumed away.
- **Retain every raw sample**: arm, **`t_request`**, **`t_ready`** (the full
  sacrificial open-and-free duration for C, the idle interval for B, zero for A),
  session age at open, sequence index, and **start timestamp**. Both durations, because the
  replenishment condition is stated in terms of `t_ready` and a contract that
  retains one latency cannot recompute it. Summaries are what made the earlier
  `p50 = 40.7 ms` unexplainable after the fact.
- Measure the **first channel that carries a real request** in each arm, since
  that is the one a user waits on.

### What exactly is measured

Ambiguity here makes every number below uncomparable, so:

- **`t_request`** — from the call opening the `direct-streamlocal` channel that
  carries the request, to the complete response line having been read. This is
  what a person waits through, and it is the quantity all decisions below use.
- **`t_ready`** — the cost paid *off* the request path to make the session
  eligible: the sacrificial open-and-free in arm C, the 100 ms wait in arm B,
  zero in arm A. It matters because it blocks a pool slot during replenishment,
  so an arm can win on `t_request` and still be the wrong choice.
- **p95** — nearest-rank on the sorted sample: with n = 100, the 95th smallest
  value. No interpolation, so two people computing it get the same number.
- **outlier rate** — the fraction of an arm's samples with `t_request` > 500 ms.

Write `A95`, `B95`, `C95` for each arm's p95 `t_request`.

### Decision procedure, fixed before running

**The selector selects; it does not estimate a treatment effect or quantify
uncertainty — in either direction.** Adoption means an arm cleared preregistered
cutoffs *in this batch*; non-adoption means it did not. Neither is, by itself,
evidence about the treatment. An earlier version attached that disclaimer only
to non-adoption, which left adoption readable as a finding; the asymmetry was
the whole leak.

Scoped to the selector deliberately, because a previous version overcorrected
into "no analysis in this document could establish effectiveness" — too
absolute. The experiment *randomises* concrete interventions across fresh
sessions, so the retained per-trial samples can support a separate randomised
contrast analysis, with uncertainty stated. This document does not perform that
analysis; it only refuses to let the cutoff rule impersonate one.

The vocabulary follows: candidates are **p95-qualified** or not. Nothing here is
"effective", because the selector cannot establish effectiveness.

**Every threshold in this procedure is a preregistered operational cutoff.**
None is derived from data or from a cited result. They are fixed here, before the
run, so they cannot be chosen after seeing the numbers — that is the entire claim
being made for them:

| cutoff | value | what it is not |
|---|---|---|
| p95 margin | 20 ms | *not* a measured perceptual threshold. Earlier drafts called it "roughly the floor a person notices"; nothing here supports that, and no source was cited. |
| outlier definition | `t_request` > 500 ms | *not* a boundary between two established regimes. |
| tail cutoff | A's count + 1 | *not* an evidence threshold — see below. |
| replenishment cap | `t_ready` p95 ≤ 50 ms | *not* a measured budget. |
| samples | n = 100 per arm | chosen for cost. |

The margin is **inclusive on the qualifying side**, so a difference of exactly
20 ms qualifies.

This table exists because these cutoffs were corrected one at a time, three
rounds running, each round leaving the others still dressed as evidence. Declaring
them together is the only version that does not leak.

A candidate **qualifies** when all of the following hold:

| | B (age gate) | C (sacrificial channel) |
|---|---|---|
| p95 margin met | `A95 − B95` ≥ 20 ms | `A95 − C95` ≥ 20 ms |
| outlier count within tolerance | ≤ A's + 1 | ≤ A's + 1 |
| replenishment affordable | — | `t_ready` p95 ≤ 50 ms |

The tail condition is an **outlier-count tolerance**. Requiring strict
improvement had a hole: when A records zero outliers — which the controlled
~96 ms batch could easily produce — no candidate can have *fewer*, so a treatment
that removed the delay entirely would be rejected and the readiness hypothesis
declared failed. `A95` = 100, `B95` = `C95` = 5, all outlier counts zero was a
real input that adopted neither.

**The `+1` is a preregistered operational cutoff, not an evidence threshold**,
and the distinction is the whole of what this paragraph is for.

Three versions of this rule have now overstated what it can support, each
correcting the last and introducing the next:

1. Exact non-regression, while arguing that one sample in 100 proves nothing — a
   contradiction inside one section.
2. A cutoff of two, called a *clear* regression. The same overclaim one step
   along: at n = 100, 0 against 2 observed outliers is **two-sided Fisher exact
   p ≈ 0.50**.
3. "n = 100 cannot support an evidence-based tail criterion at all." Also false,
   in the opposite direction — a **large enough** difference is perfectly
   detectable at n = 100.

The accurate limitation is narrower than any of them, and is the only one
stated: **n = 100 does not justify the `+1` boundary.** Whether n = 100 would
support some *other* tail criterion is not asserted either way — that depends on
a baseline rate, a margin, an alpha and a power, none of which are defined here,
so any claim about adequacy would be the same unbacked kind this paragraph exists
to stop. `+1` is fixed before the run so it cannot be chosen after seeing the
numbers. It is declared, not defended.

**What follows, so the tolerance is not mistaken for safety:** this condition
establishes neither that an adopted arm improves the tail nor that it leaves it
alone. It rejects **observed differences beyond the cutoff** — an observed
difference is not by itself an established regression, and at these counts it
usually is not one. An inference rule instead of a cutoff would need a baseline
rate, a margin, an alpha and a power stated up front, and then whatever n those
imply; naming a sample size without them is the same kind of unbacked number this
paragraph exists to stop. If the tail turns out to matter more than the p95, that
calculation is the next piece of work, and it is a different experiment.

**This procedure makes no inference about the tail, in any outcome.** Not when
the adopted arm's count is higher, not when it is lower, not when both are zero.
It decides on `p95`; the outlier cutoff is an admission gate, not a measurement
of anything.

So the reporting obligation is unconditional: **always report the raw outlier
count for all three arms alongside the decision**, and never describe an adoption
as having addressed the tail. An earlier version made the obligation conditional
— it fired only when A had outliers and the adopted arm did not reduce them —
which left two ways to read a result causally that it does not support: a
baseline of zero followed by one in the adopted arm produced no warning at all,
and an apparent reduction among tiny counts escaped the obligation entirely and
read as "tail solved".

If the tail matters, it needs its own experiment. That is stated under the
cutoffs above and is not this one.

Then, in order:

1. **`A95` ≤ 20 ms → adopt neither.** The delay did not reproduce *above the
   operational margin, in this run*. That is a statement about this batch, not
   about whether the delay exists. Hand sessions out directly, and say which
   condition ended it.
2. **Neither qualifies → adopt neither**, and **record which condition blocked
   each arm** — p95 margin, tail cutoff, or replenishment cap. Non-adoption is
   an operational outcome, not a finding: an arm can improve `p95` substantially
   and still fail on an arbitrary cutoff, and that says nothing about whether the
   treatment works. Do **not** conclude from this step that the readiness
   hypothesis failed or that the mechanism is unknown; establishing either needs
   a separate analysis of treatment effect, which this procedure does not perform.
3. **Exactly one qualifies → adopt it.**
4. **Both qualify → adopt C if `B95 − C95` ≥ 20 ms, otherwise B.** Ties and
   near-ties go to B, which costs herdr nothing. This is the only tie-break.

The outlier-tolerance condition is a qualification rather than a veto applied
afterwards, and that is deliberate: **an earlier version of this section stated
the vetoes as fallback steps** — *"fall back to the other qualifying arm"* —
without saying whether the vetoes re-applied to the fallback. Both readings were
defensible and they disagree, so the procedure was not single-valued despite
being labelled exhaustive.

That was found by **enumerating it** (`scripts/check-decision-rule.py`, 23,328
input combinations): the fallback form was ambiguous on 13.2% of them, and this
form on none. The claim of exhaustiveness had been made by reading the rule over
and agreeing with myself, which is the weakest check available and does not
survive 23,328 cases.

The script encodes **three** readings of the superseded rule, not two. A review
pointed out that the first version returned immediately after an outlier
fallback, so a fallback to C never reached the replenishment veto — a faithful
sequential reading disagrees with that model on 1,152 inputs. The 13.2% figure
happens to hold under it, but "models both forms" was a stronger claim than the
script supported, which is the same overclaim this document keeps having to
correct.

Worked, against the two cases that broke the version before that:

- `A95` = 100, `B95` = 80, `C95` = 80 → both qualify; `B95 − C95` = 0 < 20 →
  **adopt B**.
- `A95` = 100, `B95` = 50, `C95` = 70 → both qualify; `B95 − C95` = −20 < 20 →
  **adopt B**, whatever C's outlier rate.

### The cost side, with the right denominators

Reported alongside, and load-bearing only where a step above says so:

| | extra herdr connections |
|---|---|
| age gate (B) | none |
| sacrificial channel (C) | one **per session insertion** |
| liveness probe | one **per checkout** — required either way, so not part of this comparison |

An earlier version of this document said the sacrificial channel "doubles the
connections herdr sees per checkout." **That was wrong:** C's cost is one
connection per *insertion*, not per checkout.

The correction stops there. A second version went on to say that C's added load
is therefore "small" against the per-checkout probe — which requires knowing how
many checkouts a session serves before eviction, and **that number is not
measured anywhere in this document**. It depends on pool sizing, eviction and UI
demand, none of which are settled. And this experiment **cannot supply that denominator either.** Each arm starts
100 fresh sessions and issues one request per session, so its insertion-to-
checkout ratio is mechanically 1:1 — there is no reuse, no eviction, no pool
sizing and no UI demand in it. A previous version of this paragraph said the
ratio was "an output of the experiment": it is not, and inventing a measurement
the design cannot produce is the same error as the claim it was correcting,
one step further along.

So: report the exact **per-insertion** cost, which is one connection, and record
the connection counts as exact treatment accounting — **not** as an observed reuse
ratio. The denominator stays unknown until a pool prototype or a representative
workload measures it.

Both errors ran in the same direction that the writer already favoured, first
against C and then for it, which is the reason the raw counts are required rather
than the conclusion.

No pool implementation is required — only a measurement harness. **The harness
exists and the experiment has been run**: `scripts/readiness-experiment.swift`
(the three arms, randomised, per-trial raw retention),
`scripts/analyze-readiness.py` (which imports `flat()` from
`scripts/check-decision-rule.py`, so the analysis cannot drift from the rule it
claims to apply), and `scripts/readiness-experiment-results.csv` (all 300 raw
trials). Results below.

### Results — 2026-08-02, loopback, this box (run 2, validated harness)

Environment: local `sshd`, live herdr socket, fresh authenticated session per
trial, 300 trials in randomised order over 53.8 s. Decision cutoffs committed
before any run. **n = 100 per arm, 0 error rows.** Every response was decoded
and required to be a matching-id, non-error ping result — run 1's harness
counted any newline as success, so its zero errors proved delivery, not
success; run 1 is retained (`scripts/readiness-experiment-run1.csv`) with that
limitation on record. **Run 1 is not an independent confirmed decision**: its
responses were not validated or retained, so under the current error rule its
decision is unknowable — what is true is that a timing-only analysis of run 1's
lines also outputs B. Every number below is
printed by `scripts/analyze-readiness.py`, which now emits each statistic this
section cites; the analyzer refuses to compute anything on a dataset that is
not exactly the preregistered shape (3 × 100 complete arms).

| arm | median `t_request` | p95 | max | > 500 ms |
|---|---|---|---|---|
| A immediate | 156.23 ms | 173.87 ms | 1855.44 ms | 1 |
| B age-only | 0.73 ms | 100.90 ms | 101.74 ms | 0 |
| C prewarmed | 0.41 ms | 100.59 ms | 140.85 ms | 0 |

C's `t_ready` (the sacrificial open-and-free): median 96.50 ms, p95
**125.25 ms**, max 184.99 ms.

**Decision under the preregistered rule: adopt B (the age gate).** Per the
record-the-blocker obligation:

- B: p95 margin met (`A95 − B95` = 72.97 ms ≥ 20 ms); outlier count within
  tolerance (0 vs A's 1 + 1); no replenishment condition — the preregistered
  rule applies the cap to C only.
- C: p95 margin met (73.28 ms); outlier count within tolerance (0); **blocked
  by the replenishment cap** — `t_ready` p95 of 125.25 ms against the 50 ms
  cap. That is the whole of what was established about C; the mechanism behind
  its sacrificial-open cost is as unidentified as the rest.

**The cap is asymmetric, and review caught the rationale claiming otherwise.**
`t_ready` is defined as pool-slot-blocking cost for both arms, and B's is
100.08 ms p95 — its idle *is* the treatment. Applying the stated affordability
criterion symmetrically disqualifies **both** arms. The analyzer prints this
sensitivity beside every decision by running an actual symmetric selector
(`flat_symmetric` in the canonical rule module — all qualification conditions
and ordering, not a t_ready-only comparison, which a review probe showed
mislabels datasets where an arm fails a different condition). So, precisely:

- The adoption of B is the outcome of the rule **as committed**, cap on C only.
  It does not follow from the rationale as previously written, which stated a
  criterion broader than the rule applied.
- The distinction the asymmetry rests on is **declared as an operational
  preference and nothing more**: B's `t_ready` is passive waiting; C's is
  **active work** — a real herdr connection opened and torn down per insertion,
  with observed variance (96–185 ms). An earlier version of this bullet also
  called B's delay "deterministic by construction" and said pool sizing
  "absorbs" it; review caught both as unsupported. `usleep` sets a *minimum* —
  it overshoots under scheduling, suspension and load (this run's B `t_ready`
  p95 was 100.08 ms, already above the 100 ms parameter) — and nothing here
  measured slot occupancy, cold start, bursts, eviction or request demand, so
  "absorbed" was a hypothesis wearing a conclusion. Both are now **hypotheses
  assigned to the pool prototype**, which must measure slot occupancy,
  cold-start latency and burst behaviour before the age gate's cost is treated
  as absorbed. The preference stands declared, with its post-run timing stated;
  the 50 ms number remains operational, not derived.
- Under the symmetric reading the outcome is adopt-neither: hand sessions out
  immediately and pay A's request-path p95. Anyone consuming this decision
  should know it is not robust to that reading; what IS robust across every
  reading and both runs is that C's active per-insertion cost exceeds B's idle
  cost, so no reading prefers C.

Unconditional tail report (raw counts, all arms): 1 / 0 / 0 trials above
500 ms — a single 1855.44 ms trial in **A** (sequence 296). No tail inference
is made, per the procedure.

**Descriptive observations.** These use a **post-hoc cutoff (90 ms), chosen
after seeing run 1's data** — not preregistered, no decision weight:

- Opens above 90 ms: A **100**/100 spanning 143.5–1855.4 ms; B **43**/100, all
  43 inside 100.6–101.7 ms; C **20**/100, 17 of 20 inside 100.4–102 ms with
  exceptions up to 140.8 ms. B's and C's slow opens form a tight ~100–102 ms
  band that A's range does not enter; the bands overlap A's range only through
  C's three exceptions. Whether any of these are "the same event" is a
  mechanism question this experiment does not answer. The consequence for the
  pool stands on the counts alone: an age-gated open is *typically*
  sub-millisecond, and a substantial minority still cost ~100 ms in both runs
  (33% then 43%), so a UI latency budget should assume the ~100 ms case.
- **Batches differ, again.** Run 1: A p95 165.37 ms, no A outlier, B carried
  the single >500 ms trial, C `t_ready` p95 105.16 ms. Run 2: A p95 173.87 ms
  with a 1855 ms outlier, B's worst open 101.74 ms, C `t_ready` p95 125.25 ms.
  Same box, same hour. The multi-second event moved arms between runs — one
  more reason no single batch, including this one, is the number.
- **Temporal placement, inspected rather than asserted**: B again ran early
  (quarter counts [33, 24, 23, 20], mean starts 28.07 / 23.79 / 27.01 s).
  Half-split p95s: A 173.87 / 176.65 ms, B 100.89 / 100.97 ms, C
  100.70 / 100.57 ms — the qualifying margin holds within each half
  separately.
- **Treatment accounting** (not a reuse ratio): A opened 100 herdr
  connections, B 100, C 200.

What this settles for `docs/connection-pool-design.md`: the eligibility rule,
if the pool applies one, is **the 100 ms age gate on insertion** — selected by
the preregistered rule in the validated run, with the cap-symmetry caveat above
and the deterministic ~100 ms slot-occupancy cost stated rather than hidden.
The sacrificial channel is not adopted under any reading of either run, so its
per-insertion server cost does not arise **while C stays unadopted**; a future
run could select differently.

A separate randomised-contrast analysis over the retained samples — effect
sizes with uncertainty — remains possible and **has not been performed**;
nothing above estimates a treatment effect.

**Error-row rule, added after this run and binding on future ones:** this run
had zero error rows, and only after it did review notice the procedure defined
no rule for them at all — the analyzer excluded error rows from every statistic
and still emitted a decision, warning only above 5%. The analyzer now **refuses
to emit a decision if any arm contains any error row**, or if C's retained
`t_ready` count falls short of its trial count (a missing column previously
defaulted to 0.0 and passed the 50 ms cap vacuously). Declared here with its
timing stated, because a rule quietly added after a clean run would otherwise
read as having governed it.
