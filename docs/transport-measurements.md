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
- **Retain every raw sample**: arm, latency, session age at open, and sequence
  index. Summaries are what made the earlier `p50 = 40.7 ms` unexplainable after
  the fact.
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

Ordered and exhaustive: take the first step that applies and stop. **20 ms** is
the margin throughout — roughly the floor for a difference a person notices —
and it is **inclusive on the effective side**, so a difference of exactly 20 ms
counts as effective.

1. **If `A95` ≤ 20 ms — adopt neither.** The delay did not reproduce, so there
   is nothing for a readiness transition to remove. Hand sessions out directly.
2. Otherwise classify each candidate: **B is effective if `A95 − B95` ≥ 20 ms**;
   **C is effective if `A95 − C95` ≥ 20 ms**.
3. **Neither effective — adopt neither**, and record that the readiness
   hypothesis failed. The mechanism is then genuinely unknown and the open
   question below is the next work, not a pool feature.
4. **Exactly one effective — adopt that one.**
5. **Both effective — adopt C only if `B95 − C95` ≥ 20 ms; otherwise adopt B.**
   Ties and near-ties go to B because B costs herdr nothing (see below). This is
   the single tie-break; there is no separate "approximately equal" test.
6. **Outlier veto.** If the arm selected above does not have a *lower* outlier
   rate than A, do not adopt it — it moved the median and left the tail, and the
   tail is what gets reported as "it hangs sometimes". Fall back to the other
   effective arm if there is one, otherwise adopt neither.
7. **Replenishment veto, C only.** If C survives to here but its `t_ready` p95
   exceeds **50 ms**, reject C and take B if B is effective, otherwise adopt
   neither. A transition that blocks a pool slot longer than the delay it hides
   has moved the cost rather than removed it.

Worked, against the two cases that broke the previous rules:

- `A95` = 100, `B95` = 80, `C95` = 80 → both effective (step 2); `B95 − C95` = 0
  < 20 → **adopt B** (step 5). One answer.
- `A95` = 100, `B95` = 50, `C95` = 70 → both effective; `B95 − C95` = −20 < 20 →
  **adopt B**, regardless of C's outlier rate. One answer.

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
