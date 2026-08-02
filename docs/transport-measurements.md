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
| **first channel of a session** | **~100–1900 ms, variable** | **cause unknown** |
| every subsequent channel | 0.1 ms | free |
| missing `TCP_NODELAY` | ~30 ms | fixed, now recovered |

## The finding that matters

**The first channel opened on a fresh SSH session is expensive. Every channel
after it, on that same session, is free.**

That shape is stable and reproducible on every target tested — the live herdr
socket and a trivial echo socket with no herdr code in the path. The *magnitude*
is not stable: the same code against the same target on the same machine
produced 1804 ms once and 99.7 ms another time.

Because `roundTrip` opens a fresh session per request, **every request pays a
once-per-session cost.** That is the dominant term in the whole transport.

## How this was nearly missed

Three rounds of measurement reported percentiles and found nothing. Channel-open
looked like a modest `p50 = 40.7 ms` worth optimising.

Printing the **sequence** instead found it in one look:

```
1804.6  0.2  0.1  0.1  0.1  0.1  0.1  0.1  0.1  0.1  0.1  0.1   (ms)
```

The distribution is bimodal — one enormous sample and eleven free ones — and a
p50 across it is not a weak signal but a **confident wrong one**. A separate
"pathological p95 of 1958 ms", logged for a while as an unrelated defect, turned
out to be the same phenomenon sampled differently.

**Prefer the sequence to the summary when hunting a cause.** A summary statistic
over a bimodal distribution manufactures a plausible number that describes
nothing real.

## What was ruled out

- **herdr is not the cause.** A trivial echo socket, with zero herdr code in the
  path, paid *more* on its first channel (1877.8 ms) than herdr did (99.7 ms).
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

- Sessions are worth pooling because they carry both the ~39 ms of real crypto
  *and* the once-per-session first-channel cost. Pooling pays both once instead
  of once per request.
- Channels are not worth pooling: they are free after the first, and herdr's
  command socket is single-shot, so each request needs its own regardless.
- The eviction threshold **needs its own basis.** The original plan inherited
  ~3 s from herdr's `INITIAL_REQUEST_TIMEOUT`, but that governs herdr's socket,
  not sshd's session — a different object with different lifetime rules.

This conclusion holds whatever the unknown cause turns out to be, because the
cost is per-session either way. That is why the investigation stopped here
rather than continuing: the design needs the *shape*, and the shape is known.
