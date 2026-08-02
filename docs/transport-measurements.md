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
channel after it is free."* **That is false.** The cost tracks how long the
session has existed, not the channel's position.

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

**This is not guaranteed to work.** Prewarming is expected to help because
subsequent channels on a session are consistently cheap, but the outliers above
mean it is not proven to remove the cost in all cases. It should be validated
against real checkout behaviour, not assumed.

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

Compare an immediate first-channel open against one on an aged session, **with
the raw sequence and session ages retained**. If ageing stops helping, or if
outliers persist at the same rate, prewarming is not the answer and this
conclusion is wrong. No implementation is required to run it.
