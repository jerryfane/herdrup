# SSH transport cost, measured

Goal v1b task 2. Everything here was measured on this box against a live herdr
server over a real SSH tunnel. Nothing is inferred, and where a cause is unknown
it says so rather than guessing.

**Loopback is a floor, not a prediction for cellular.** Every number below is the
best case.

## The breakdown

| phase | cost | nature |
|---|---|---|
| TCP connect | 0.1 ms | negligible |
| SSH handshake / key exchange | 18.6 ms | **real cryptographic work** |
| public-key authentication | 20.4 ms | **real cryptographic work** |
| **channel opened immediately after auth** | **~96 ms (p50 of 30)** | **readiness delay** |
| channel on a session aged 100 ms | 0.28–0.54 ms | ready |
| every subsequent channel | 0.1 ms | free |
| missing `TCP_NODELAY` | ~30 ms | fixed, now recovered |

## The finding that matters — CORRECTED

An earlier version of this document claimed *"the first channel opened on a
fresh session is expensive; every channel after it is free."* **That is false**,
and a reviewer disproved it with a measurement I had not thought to run.

| condition | first-channel cost |
|---|---|
| opened **immediately** after authentication | 89.6–102.1 ms |
| session **aged 100 ms** before its first channel | **0.28–0.54 ms** |
| pre-opened sessions | ~0.22 ms |

**It is not the first channel that is expensive. It is a channel opened
immediately after authentication.** Waiting 100 ms makes the cost vanish. So
this is a *post-authentication readiness delay*, not an intrinsic per-session
cost — the session needs a moment to become ready, and a channel requested
inside that window pays for it.

The distinction matters for the design: a pool that merely holds sessions does
not fix this, because a freshly authenticated session handed straight out still
pays. **Sessions must be prewarmed or validated before checkout.**

Because `roundTrip` opens a fresh session per request and uses it immediately,
**every request pays the readiness delay.** Pooling alone does not remove it —
a pooled session handed out before it is ready pays exactly the same. The cost
is avoided by *prewarming*, not by *reusing*.

## The method lesson — also corrected

An earlier version claimed the `p50 = 40.7 ms` was a "confident wrong number"
produced by a median over a bimodal distribution. **That reasoning conflated two
datasets.** The displayed sequence — eleven samples near 0.1 ms and one at
1804.6 ms — has a median near 0.1 ms, not 40.7 ms. The 40.7 ms came from a
different run under different conditions.

A median is not inherently misleading. **The actual error was aggregating
measurements taken in heterogeneous session states** — some channels opened
immediately after auth, some on aged sessions — into one statistic, as though
they were samples of the same thing. They were not.

The surviving lesson is narrower and more useful than the one first written:
**print the sequence when hunting a cause**, because it exposes whether your
samples are even measuring the same condition. The bimodality was real; the
explanation attached to it was wrong.

## What was ruled out

- **herdr is not the cause.** A trivial echo socket, with zero herdr code in the
  path, paid *more* in one sampled run (1877.8 ms) than herdr did (99.7 ms).
- **Not `UseDNS`** — unset, and modern OpenSSH defaults it off.
- **Not GSSAPI** — `gssapiauthentication no`, `gssapikeyexchange no`.
- **Not herdr's two-write response pattern.** An earlier claim that this cost
  ~100 ms per request and was worth ~190x was **retracted**: it compared two
  structurally different relay programs and attributed the whole difference to
  write shape. Controlled A/B puts it at roughly 2x, sub-millisecond.
  `jerryfane/herdr#29` stays parked on this evidence.

## What remains unknown

**Why the first channel of a session costs what it does, and why the magnitude
varies by an order of magnitude between runs.** It lives somewhere in the first
`direct-streamlocal` forward of a session. A variable 100 ms–1900 ms penalty
resembles a timeout or a retry more than it resembles work, but that is a
hypothesis and it is not tested here.

## Consequence for the connection design

**Pool authenticated sessions. Keep channels per-request.**

- Sessions are worth pooling for the ~39 ms of real crypto, which pooling pays
  once instead of once per request.
- The readiness delay is **not** solved by pooling. It is solved by prewarming a
  session — opening and freeing a sacrificial channel — **before** it is handed
  out. A pool without prewarming still pays it on every checkout.
- Channels are not worth pooling: they are free after the first, and herdr's
  command socket is single-shot, so each request needs its own regardless.
- The eviction threshold **needs its own basis.** The original plan inherited
  ~3 s from herdr's `INITIAL_REQUEST_TIMEOUT`, but that governs herdr's socket,
  not sshd's session — a different object with different lifetime rules.

This holds whatever the cause turns out to be, because prewarming addresses it
either way. That is why the investigation stopped: the design needs the shape,
and the shape is known.

The falsifier is cheap and needs no implementation — compare an immediate
first-channel open against one on an aged session. If ageing stops helping,
prewarming is not the answer and this conclusion is wrong.
