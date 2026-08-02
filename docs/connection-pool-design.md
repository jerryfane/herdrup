# Connection pool: design

Goal v1b task 3, design memo. **Not an implementation** — task 3 is gated on
task 1 receiving a clean verdict, and this records the design so that when it
ungates the shape is already settled by measurement rather than argued again.

The plan for this task was revised four times. Each revision was forced by a
measurement contradicting the previous premise, and the sequence is recorded
below because the wrong turns are more instructive than the answer.

## The design

**Pool authenticated SSH sessions. Open a fresh channel per request. Do not pool
channels.**

- A session carries ~39 ms of real cryptographic work (18.6 ms key exchange +
  20.4 ms public-key auth) **and** a once-per-session first-channel cost of
  100–1900 ms. Both are paid once per pooled session instead of once per
  request.
- Channels cost 0.1 ms after the first on a session — there is nothing to
  amortise — and herdr's command socket is **single-shot**, so every request
  needs its own channel regardless.

That asymmetry is the whole design. It was not obvious and was not guessable.

## How the plan was wrong, four times

1. **"Pool channels; evict at ~3 s."** Premise: channel-open is the dominant
   cost, and herdr's `INITIAL_REQUEST_TIMEOUT = 5 s` reaps idle ones.
   *Wrong:* channel-open is free after the first.
2. **"The residual is herdr's two-write response pattern."** *Wrong:* a trivial
   echo socket with no herdr code paid more. `jerryfane/herdr#29` stays parked;
   its 190× claim was retracted as a comparison of two different programs.
3. **"Session setup is a timer to be found and removed."** *Partly wrong:*
   ~39 ms of it is real cryptography that will not go away. Only the
   first-channel portion is anomalous.
4. **"The first channel costs 1.8 s."** *Wrong as stated:* the magnitude varies
   ~100 ms to ~1900 ms between runs. The stable fact is the *shape* — first
   expensive, rest free — not the number.

## Eviction

**The ~3 s threshold from the original plan does not transfer.** It was derived
from herdr's `INITIAL_REQUEST_TIMEOUT`, which governs *herdr's socket*, not
sshd's session — a different object with different lifetime rules. Reusing it
would be inheriting a number whose justification does not apply, which is the
same error as reusing a percentile whose distribution does not apply.

Eviction needs its own basis, from at least:

- **sshd's `ClientAliveInterval` / `ClientAliveCountMax`** on the target host,
  which bound how long an idle session survives server-side.
- **What a phone actually does.** iOS suspends backgrounded apps, so a pooled
  session will routinely be idle across a suspension and must be assumed dead on
  foreground rather than probed optimistically.

Until measured, the safe default is **validate-on-borrow rather than
evict-on-age**: a session that fails is discarded and replaced, which is correct
whatever the true idle lifetime turns out to be. Age eviction can be added later
as an optimisation once there is a number to justify it.

## What it must not do

- **Do not pool channels.** Free after the first, and single-shot at the herdr
  end.
- **Do not size the pool against the 100–1900 ms figure.** Its cause is unknown
  and its magnitude unstable. Size it against concurrency demand — how many
  simultaneous requests the UI actually issues — which is a product question,
  not a latency one.
- **Do not assume a pooled session is alive.** See suspension, above.

## Open question carried forward

**Why the first channel of a session costs what it does, and why the magnitude
varies by an order of magnitude.** Not herdr, not `UseDNS`, not GSSAPI. It
resembles a timeout more than work, but that is untested.

The design does not depend on the answer — the cost is per-session either way —
which is why the investigation stopped. If it is ever explained and turns out to
be per-*connection* rather than per-*session*, **this design changes and this
memo is wrong**. That is the fifth revision, and it is recorded here so the
condition is visible rather than discovered.

## Verification, when implemented

The axis is **not** that a pool returns a session. It is that **the second
request to a host does not pay the first-channel cost.** A test that borrows
twice and compares the cost of the two is the guard; one that merely checks a
session comes back proves nothing.
