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
ready pays the same. The design response is to prewarm: open and free a
sacrificial channel before checkout, so the request path does not carry it.

**Prewarming is an untested hypothesis, and nothing here supports it directly.**
Every measurement in this document varies *elapsed time*; not one opens a
sacrificial channel. The reasoning behind it — that a channel opened after
another one is cheap — is an inference from arm-B-shaped data about waiting, and
it may well turn out that waiting is the whole effect and the sacrificial
channel adds only a second connection for herdr to reap. The falsifier below
exists to settle that, and it should be run before the pool commits to it.

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
- **Prewarm before checkout.** Pooling alone leaves the readiness delay on the
  request path.
- Channels are not worth pooling: they are consistently cheap on a ready
  session, and herdr's command socket is single-shot, so each request needs its
  own regardless.
- The eviction threshold **needs its own basis.** The original plan inherited
  ~3 s from herdr's `INITIAL_REQUEST_TIMEOUT`, which governs herdr's socket, not
  sshd's session.

### The cheap falsifier

The previous version of this section compared an immediate first-channel open
against an aged one. That tests **waiting**, which is not what the design
proposes: `docs/connection-pool-design.md` proposes opening and freeing a
*sacrificial channel*. An experiment that never opens one cannot falsify it.

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

Decision rule, fixed before running:

- **Adopt prewarming** only if C's p95 is at least **20 ms** below A's p95 — the
  rough floor for a difference a person can feel — *and* C's p95 is no worse
  than B's.
- **Reject prewarming** if C's p95 is within 20 ms of A's, or if C's rate of
  samples above 500 ms is not below A's. Either result says the sacrificial
  channel is not what removes the cost.
- **Prefer B if C ≈ B.** If simply not handing out a session for its first
  100 ms performs as well, prewarming is added machinery for nothing, and the
  simpler rule wins.

Also record, because it is a cost and not just a latency: **how many connections
herdr sees per checkout in arm C.** A sacrificial open is a real connection to
herdr's socket that is then abandoned, and `INITIAL_REQUEST_TIMEOUT` reaps
connections that open and go idle — so arm C may double herdr's connection rate
and manufacture exactly the reap condition the pool is meant to avoid. If it
does, that counts against C independently of what the latency shows.

No pool implementation is required — only a measurement harness.
