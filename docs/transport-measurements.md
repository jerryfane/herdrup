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

**Pooling alone does not fix this** — a pooled session handed out before it is
ready pays the same. Something must make a session *ready* before it is handed
out, and there are two candidates:

- **Age gate** — do not hand out a session until it is 100 ms old.
- **Sacrificial channel** — open and free one channel on the session, then hand
  it out.

**Neither is chosen here, and this document does not prescribe one.** Every
measurement below varies *elapsed time*; not one opens a sacrificial channel, so
there is no evidence bearing on the second candidate at all. Earlier versions
named it as the design response anyway. The experiment further down selects
between them, and until it is run the pool should treat both as open.

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
- **A readiness transition is required before checkout** — pooling alone leaves
  the delay on the request path — but *which* transition is undecided. See the
  experiment below; do not implement one before running it.
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
| **A** immediate | open the measured channel straight after auth | the cost as it stands today |
| **B** age-only | idle 100 ms, then open the measured channel | whether merely waiting is enough |
| **C** prewarmed | open and free a sacrificial `direct-streamlocal` channel, then open the measured channel | the actual proposed treatment |

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

**20 ms** is the margin throughout — roughly the floor for a difference a person
notices — and it is **inclusive on the qualifying side**, so a difference of
exactly 20 ms qualifies.

A candidate **qualifies** when all of the following hold:

| | B (age gate) | C (sacrificial channel) |
|---|---|---|
| effective | `A95 − B95` ≥ 20 ms | `A95 − C95` ≥ 20 ms |
| tail not worsened | outlier count ≤ A's + 1 | outlier count ≤ A's + 1 |
| replenishment affordable | — | `t_ready` p95 ≤ 50 ms |

The tail condition is **non-regression, not strict improvement**. Requiring
strict improvement had a hole: when A records zero outliers — which the
controlled ~96 ms batch could easily produce — no candidate can have *fewer*, so
a treatment that removed the delay entirely would be rejected and the readiness
hypothesis declared failed. `A95` = 100, `B95` = `C95` = 5, all outlier counts
zero was a real input that adopted neither.

Sampling is why there is a **tolerance of one**, and why it is counts rather than
rates. At n = 100 a single sample is 1%; a one-outlier difference is not evidence
of anything in either direction, so making one extra observed outlier a hard veto
contradicted the very rationale stated for using counts. It did, in the previous
version: `A95` = 100, `B95` = 5, `C95` = 100 with counts A = 0 and B = 1 rejected
the only effective treatment over a single event.

**What this tolerance cannot do, stated so it is not mistaken for safety:** at
n = 100 a genuine tail regression of a percentage point or two is invisible. This
condition rejects *gross* regressions and nothing finer. It does not certify that
an adopted arm leaves the tail alone — it only ensures the tail is not obviously
worse. Certifying that would need a much larger n, and this experiment is
deliberately cheap.

**If A has outliers and the adopted arm does not reduce them, the tail stays an
open question** and must not be reported as solved: the arm was adopted on its
**p95**, which is the only metric this procedure decides on, and the multi-second
hangs are still unexplained. That is a reporting
obligation, not a veto — vetoing it was what produced the hole above.

Then, in order:

1. **`A95` ≤ 20 ms → adopt neither.** The delay did not reproduce; there is
   nothing to remove. Hand sessions out directly.
2. **Neither qualifies → adopt neither**, and record that the readiness
   hypothesis failed. The mechanism is then genuinely unknown, and the open
   question below becomes the next work rather than a pool feature.
3. **Exactly one qualifies → adopt it.**
4. **Both qualify → adopt C if `B95 − C95` ≥ 20 ms, otherwise B.** Ties and
   near-ties go to B, which costs herdr nothing. This is the only tie-break.

The "tail improved" condition is a qualification rather than a veto applied
afterwards, and that is deliberate: **an earlier version of this section stated
the vetoes as fallback steps** — *"fall back to the other effective arm"* —
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
connections herdr sees per checkout." **That was wrong, and wrong in the
direction that made C look worse than it is:** C's cost is per *insertion*, and
pooling exists precisely so that checkouts outnumber insertions. Against the
mandatory per-checkout probe, C's added load is small. The denominator was the
error, and it would have biased the decision before the experiment ran.

No pool implementation is required — only a measurement harness.
