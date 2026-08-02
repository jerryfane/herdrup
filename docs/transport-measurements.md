# SSH transport cost, measured

Goal v1b task 2.

**Read the caveats with the numbers.** This document has been corrected three
times, each time because a claim outran what was actually measured. What follows
distinguishes what was observed from what was concluded, and says which
conclusions remain unverified.

**Loopback is a floor, not a prediction for cellular.**

## Measured phase latencies

| phase | latency | what it is |
|---|---|---|
| TCP connect | 0.1 ms | negligible |
| SSH handshake / key exchange | 18.6 ms | measured latency of the handshake phase |
| public-key authentication | 20.4 ms | measured latency of the auth phase |
| channel opened immediately after auth | ~96 ms (p50 of one 30-sample batch) | readiness delay |
| channel on a session aged 100 ms | 0.28–0.54 ms | ready |
| missing `TCP_NODELAY` | ~30 ms | fixed, recovered |

These are **phase latencies**, not proof of where the time goes inside each
phase. The handshake and auth figures are plausibly dominated by cryptographic
work, but this measurement times the API call — it does not establish that the
latency is computation rather than round trips or waiting.

## The finding: a post-authentication readiness delay

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

**Neither is chosen here, and this document does not prescribe one — nor that
one is needed.** Every measurement below varies *elapsed time*; not one opens a
sacrificial channel, so there is no evidence bearing on the second candidate at
all. Earlier versions named it as the design response anyway, and a later version
said a transition was *required*, which is the conclusion the experiment exists to
reach. The experiment records each arm's `p95` and may select B, C or **neither**;
until it is run, the pool should treat all three outcomes as open.

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

**Why a freshly authenticated session is not immediately ready.** The effect is
associated with the period just after authentication, but its mechanism is not
identified, and this document should not be read as locating it in any
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
- **If the delay reproduces on the request path, a readiness transition or a
  validation step belongs before checkout** — pooling alone would leave the delay
  there. Stated conditionally: the experiment below can adopt neither arm, and
  the existing measurements show an association with multi-second outliers even
  in the control, so *that a transition is needed* is not established here. Which
  transition, if any, is what the experiment decides. Do not implement one before
  running it.
- Channels are not worth pooling: they are consistently cheap on a ready
  session, and herdr's command socket is single-shot, so each request needs its
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
  order** so machine load and thermal drift hit all three alike. A blocked run
  of A followed by a blocked run of C would confound the treatment with time.
- **Retain every raw sample**: arm, **`t_request`**, **`t_ready`** (the full
  sacrificial open-and-free duration for C, the idle interval for B, zero for A),
  session age at open, and sequence index. Both durations, because the
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

**This procedure selects; it does not measure a treatment effect — in either
direction.** Adoption means an arm cleared preregistered cutoffs *in this batch*.
It is not evidence that the treatment works, exactly as non-adoption is not
evidence that it fails. An earlier version attached that disclaimer only to
non-adoption, which left adoption readable as a finding; the asymmetry was the
whole leak.

The vocabulary follows: candidates are **p95-qualified** or not. Nothing here is
"effective", because effectiveness is a causal property and no analysis in this
document could establish one.

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

No pool implementation is required — only a measurement harness.
