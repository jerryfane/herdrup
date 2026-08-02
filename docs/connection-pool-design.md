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

  **Readiness is not settled, and this memo previously pretended it was.** It
  named the sacrificial `direct-streamlocal` open as the transition and
  dismissed an age gate as "a proxy that would need its own measurement" — while
  the two lines above report the measurement that an age gate *does* have and a
  sacrificial channel does not. Nothing measured so far opens one.

  Two candidate transitions, to be decided by the three-arm experiment in
  `transport-measurements.md` before implementation, not after:

  - **Age gate** — a session is eligible once it is 100 ms old. Has supporting
    data (0.28–0.54 ms against ~96 ms) and costs nothing at the server.
  - **Sacrificial channel** — a session is eligible once one channel has been
    opened and freed on it. Exercises the exact operation being avoided, but
    **doubles the connections herdr sees per checkout**, and herdr reaps
    connections that open and go idle (`INITIAL_REQUEST_TIMEOUT`), so it
    manufactures the condition the pool exists to avoid.

  The rule fixed in advance: **the sacrificial channel is adopted only if it
  beats the age gate by a margin worth its server-side cost.** If they tie, the
  age gate wins on simplicity. Whichever is chosen, prewarm **on insertion**, not
  on borrow, so the cost lands off the request path — that part holds either way,
  because it follows from where the cost is paid rather than from what removes it.

  **Failure handling for the transition:** a session whose prewarm fails is
  discarded, never inserted, and never counted toward pool capacity. A prewarm
  that fails is evidence about the session, not a step to retry on it.
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
  check. Specified, because "a probe" is not implementable:
  - **Operation:** open a `direct-streamlocal` channel to herdr's socket and
    send `{"id":"<probe>","method":"ping","params":{}}`.
  - **Success:** a decodable response envelope carrying the same `id`. Not
    "bytes arrived", and not "the channel opened" — herdr's socket accepts a
    connection before it commits to answering, so a channel that opens proves
    the tunnel and nothing about the server.
  - **Timeout:** 1 s. Above herdr's observed round trip by a wide margin and far
    below any interval a user would wait through. Stated as a chosen bound, not
    a measured one.
  - **On failure or timeout:** discard the session, close it, replace it. Never
    probe twice, and never send the user's request down a session that failed —
    a second probe is the same optimism the delivery rule below refuses.
  - **`ping` specifically** because it changes nothing. A probe with a side
    effect would make every checkout an unlogged write.
- **Discard and replace** a session that fails the probe; never nurse it.
- **Delivery phases are defined by observed write progress, not by error
  names.** `libssh2_channel_write_ex` returns a positive accepted-byte count or
  a negative status, and `EAGAIN` means resume rather than fail. So:
  - **definitely-not-sent** — the channel never opened, or zero bytes were ever
    accepted for this request. Safe to retry automatically.
  - **possibly-sent** — any positive byte count was accepted, even partially.
    Not safe to retry, regardless of what error followed.

  Two return values are easy to misread as progress, and both have bitten this
  codebase's read path already:

  - **`EAGAIN` is not a failure and not progress.** It means resume the *same*
    attempt with the identical buffer and length. libssh2 keeps a partially
    transmitted packet in its pending-send state and only returns a positive
    payload count once the whole channel-data packet has cleared, so a request
    can sit in EAGAIN with bytes already on the wire. Restarting the write from
    a different offset corrupts the stream.
  - **A zero return is not completion.** It means the channel window had no
    capacity, so nothing was accepted — no progress, and the request stays
    definitely-not-sent unless a previous call already returned positive.

  Cumulative progress is therefore tracked **per request across every write**,
  not per call: a request spanning several writes becomes possibly-sent at the
  first positive return and stays that way.

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

The design does not depend on the *cause*: whichever readiness transition wins,
it moves the cost off the request path without needing to know why the cost is
there. That is why the investigation stopped, and it remains a gap rather than a
closed question.

**The falsifier is cheap and needs no pool.** It is specified in
`transport-measurements.md` — three randomised arms (immediate, age-only,
prewarmed by sacrificial channel), n=100 each, raw timings and session ages
retained, with the rejection rule fixed before the run.

An earlier version of this section proposed comparing an immediate session
against an aged one and called that the falsifier for prewarming. It is not:
it never opens a sacrificial channel, so it can only falsify *waiting*. The
same mistake, phrased two ways in two documents, is why the arms are now
enumerated in one place and referenced from the other rather than described
twice.

## Verification, when implemented

The axis is **not** that a pool returns a session, and it is **not** that the
second request is cheap.

The second-request version was the axis here until review caught it, and it is
wrong in a way worth keeping on the page: delete insertion-time prewarming
entirely and the first request is slow while the second is cheap — which is
exactly what that test asserts. It passes on the broken implementation. It is
the same shape as the twelve tests this seat shipped that asserted less than
their names implied.

**The axis is that the FIRST request served from a newly eligible session does
not pay the readiness cost.** That is the only claim prewarming makes, and it is
the one a user experiences.

The guard must therefore:

- measure the **first** borrow from a session the pool has just declared
  eligible, not a subsequent one;
- be **mutation-verified by removing the prewarm transition** and confirming the
  test fails — with an assertion that the removal actually applied, since three
  silent no-op mutations this week made green runs look like working guards;
- record the raw latency, not a pass/fail, so a regression that halves the
  benefit is visible rather than rounded away.
