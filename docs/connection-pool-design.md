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
  20.4 ms public-key auth), paid once per pooled session instead of once per
  request.
- A session also has a **post-authentication readiness delay**. A channel opened
  immediately after auth costs ~96 ms (p50 of 30); a session aged just 100 ms
  first opens in 0.28–0.54 ms. This is **not** an intrinsic per-session cost, and
  an earlier version of this memo wrongly described it as one.

  **Consequence: pooling alone is insufficient.** A freshly authenticated session
  handed straight out still pays.

  **Readiness, defined executably** — "prewarmed" is not a design until it names
  a transition. A session becomes eligible for checkout when a **sacrificial
  `direct-streamlocal` channel has been opened and freed on it**. That is the
  operation whose cost is being avoided, so performing it once is what proves
  readiness; an age gate would be a proxy for it and would need its own
  measurement to justify a number. Prewarm on insertion, not on borrow, so the
  cost lands off the request path.
- Channels cost 0.1 ms **on a ready session** — there is nothing to amortise — and herdr's command socket is **single-shot**, so every request
  needs its own channel regardless.

That asymmetry is the whole design. It was not obvious and was not guessable.

## How the plan was wrong, four times

1. **"Pool channels; evict at ~3 s."** Premise: channel-open is the dominant
   cost, and herdr's `INITIAL_REQUEST_TIMEOUT = 5 s` reaps idle ones.
   *Wrong:* channel-open is free on a ready session; the cost is readiness.
2. **"The residual is herdr's two-write response pattern."** *Wrong:* a trivial
   echo socket with no herdr code paid more. `jerryfane/herdr#29` stays parked;
   its 190× claim was retracted as a comparison of two different programs.
3. **"Session setup is a timer to be found and removed."** *Partly wrong:*
   ~39 ms of it is real cryptography that will not go away. Only the
   first-channel portion is anomalous.
4. **"The first channel costs 1.8 s."** *Wrong as stated:* the magnitude varies
   ~100 ms to ~1900 ms between runs. The stable fact is the *shape* — first
   readiness-gated, not position-gated. An *aged* session's first channel is
   as cheap as its tenth.

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

## Leasing — exclusive, one in-flight request per session

libssh2 permits only one thread at a time in a session. The memo previously
sized a pool against concurrent demand without saying whether a session is held
exclusively, which left the most important concurrency question unanswered.

- **One in-flight request per pooled session.** Lease exclusively; return only
  after the channel is freed.
- **A persistent stream gets its own dedicated session**, never one shared with
  request traffic — an `events.subscribe` holds its channel for the life of the
  subscription, so a shared session would be leased indefinitely.
- Multiplexing several channels across one session is **not** specified here and
  must not be assumed. If it is ever wanted, it needs complete per-session
  serialisation designed deliberately, not inherited by accident.

## Validation and retry — delivery ambiguity is the hazard

**Validate-on-borrow is not inherently safe**, and the earlier memo recommended
it without qualification.

If the validation *is* the user's request, a failure after the bytes may already
have been written has **ambiguous delivery** — and automatic retry then
duplicates the action. That is precisely the failure class herdr#26 and #31 are
about: a prompt whose delivery cannot be established, retried on top of a draft
that already landed.

So:

- **A separate pre-send liveness probe**, not the user's request doubling as the
  check.
- **Discard and replace** a session that fails the probe; never nurse it.
- **Delivery phases are defined by observed write progress, not by error
  names.** `libssh2_channel_write_ex` returns a positive accepted-byte count or
  a negative status, and `EAGAIN` means resume rather than fail. So:
  - **definitely-not-sent** — the channel never opened, or zero bytes were ever
    accepted for this request. Safe to retry automatically.
  - **possibly-sent** — any positive byte count was accepted, even partially.
    Not safe to retry, regardless of what error followed.

  Tracking accepted bytes per request is what makes the boundary decidable; an
  error code alone cannot supply it, because the same code can follow either
  state.
- **Never replay a possibly-sent mutation** without an idempotency or attempt
  identifier. herdr's `agent.prompt` has no idempotency key today
  (`jerryfane/herdr#16`), so for now a possibly-sent prompt must surface to the
  reader rather than being retried silently.

## What it must not do

- **Do not pool channels.** Free on a ready session, and single-shot at the
  herdr end.
- **Do not size the pool against the 100–1900 ms figure.** Its cause is unknown
  and its magnitude unstable. Size it against concurrency demand — how many
  simultaneous requests the UI actually issues — which is a product question,
  not a latency one.
- **Do not assume a pooled session is alive.** See suspension, above.

## Open question carried forward

**Why the post-authentication readiness delay exists.** Not herdr, not `UseDNS`,
not GSSAPI. It resembles a settling period more than work, but that is untested.

The design does not depend on the cause — prewarming addresses it either way —
which is why the investigation stopped.

**The falsifier is cheap and already available.** The earlier version of this
memo proposed a falsifier that required implementation. It does not: compare
first-channel cost on an *immediate* session against one *aged* by a short
interval. If ageing stops helping, prewarming is not the answer and this design
needs revising. That control costs one test and can be run before any pool
exists.

## Verification, when implemented

The axis is **not** that a pool returns a session. It is that **the second
request to a host does not pay the readiness cost.** A test that borrows
twice and compares the cost of the two is the guard; one that merely checks a
session comes back proves nothing.
