# herdr-ios v1b: SSH transport layer

Implement the plan task by task. Each task must be developed, reviewed, opened
as its own pull request, merged, and verified before moving on.

Build the transport that carries herdr's JSON API from a phone to a remote
machine: a Swift SSH client over libssh2, a connection pool sized by measurement
rather than guesswork, and reconnect behaviour that survives a phone's network.
Every task here is Linux-buildable and verifiable against the live herdr server
on this box.

**Explicitly excluded:** anything requiring macOS — SwiftUI, SwiftTerm,
gestures, Keychain, Simulator, XcodeGen. Those are held until the owner's trust
confirmation routes through jarvis. Do not start them, and do not write UI code
speculatively.

## Repo facts

- Repo `jerryfane/herdr-ios`, base branch `main`.
- **Merge rule: never self-merge.** The coordinator (jarvis) reviews at head and
  merges. Open the PR and stop.
- Build/test gate:
  `export PATH=/opt/swift/usr/bin:$PATH && swift build && swift test`
- Lint gate before every push: `swift build` must be warning-clean.
- A live herdr server runs at `~/.config/herdr/herdr.sock`, so live tests
  execute rather than skip. `HERDR_SOCKET_PATH` overrides the path.
- `CSSH` is already declared as a `systemLibrary` target in `Package.swift`,
  with `Sources/CSSH/module.modulemap` mapping `/usr/include/libssh2.h` and
  linking `ssh2`. Verified working: libssh2 1.11.0,
  `libssh2_channel_direct_streamlocal_ex` resolves from Swift.

## Core Rules

- Work one task at a time in the listed order. Tasks 1–4 are strictly
  dependent; task 5 is independent and may run in parallel on its own branch.
- Do not start dependent work until the prerequisite task has passed checks,
  been pushed, opened as a PR, and **received a clean review verdict at its
  current head**. Not until it is merged — merging is the coordinator's and
  gating on it reintroduces exactly the unreachable-condition bug that this
  file's Definition of Done section corrects. A clean verdict means the design
  is settled enough to build on; the merge is bookkeeping that follows.
- Do not commit build artifacts, `.build/`, logs, generated data, credentials,
  or SSH keys.
- Preserve existing behaviour unless the task explicitly changes it.
  `UnixSocketTransport` stays working throughout — `SSHTransport` is added
  alongside it, not in place of it.
- Avoid duplication. `HerdrTransport` already encodes the single-shot vs
  persistent split; conform to it rather than inventing a parallel abstraction.
- Verify real contracts with local commands before editing. libssh2's API, herdr's
  socket behaviour, and timeout constants are all checkable on this box — check
  them rather than reasoning from names.

## Verification rule — read this before writing any test

This seat has shipped **twelve** tests in one week that asserted less than their
names implied. Every single one shared the same shape: **they exercised the
plumbing around the logic rather than the logic itself.** Examples, so the
pattern is recognisable:

- a single-shot test that opened two independent connections and proved nothing
- a guard test that injected synthetic closures and never reached the guard, so
  deleting the production check failed nothing
- a test that asserted a freeze was correct behaviour, codifying the defect
- a retirement predicate whose test manufactured a state production cannot reach
- a positive guard deleted as collateral while rewriting its neighbour, leaving
  a neutered feature shipping green

Therefore, for every task:

1. **State the axis the test covers** in the PR body. If you cannot name the
   axis in one sentence, the test is probably testing plumbing.
2. **Mutation-verify every test**, and **assert that the mutation applied**
   before trusting the result. Three silent no-op mutations this week made green
   runs look like working guards. A mutation script must fail loudly if its
   target string is absent.
3. **Repeat any timing- or connection-sensitive test 10+ times.** Two flakes
   this week appeared only on repeat runs, one at ~50%.
4. Prefer a test that fails when the feature is *absent*, not only when it is
   *wrong*. The turn-baseline fix was silently lost twice to merge and rebase,
   and both times a human check caught it because no test could.

## Escalation rule

When blocked, facing a design decision, or holding a finding that changes scope:

```
gitmoot org escalate --to jarvis --workflow herdr/fork-sync --org-role herdr-app "HERDR-APP: <question>"
```

Pane replies reach nobody — this is measured, not assumed. Sign every outbound
message `HERDR-APP:`. Do not guess on a decision that is the owner's or the
coordinator's to make.

## Reporting rule

Report to the owner over Telegram at these points, and only these, to keep the
signal high:

- **Task start:** `agentgram send "HERDR-APP: starting task N — <one line>"`
- **Task complete:** the PR URL, what was verified, and anything left open.
- **Blocked:** immediately, with what is needed to unblock.
- **A finding that changes the plan:** immediately.

Do not report routine progress within a task.

---

## Task 1 — `SSHTransport`

Implement `SSHTransport` in `Sources/HerdrKit/` conforming to the existing
`HerdrTransport` protocol (`Sources/HerdrKit/Transport.swift`).

**It must use `libssh2_channel_direct_streamlocal_ex`.** Plain `direct-tcpip`
cannot reach a remote unix socket — that limitation is the entire reason
libssh2 was chosen over Citadel and SwiftNIO-SSH, neither of which exposes
streamlocal. Verified present: libssh2 1.11.0 on this box.

Conform to the protocol's existing split, which encodes measured server
behaviour:

- `roundTrip` — one request, one response, connection closed. herdr's command
  socket is **single-shot**; a second request on the same connection gets
  nothing back.
- `stream` — `events.subscribe` holds its connection open and streams. Reuse the
  cancellation discipline already in `UnixSocketTransport.stream`: `Task.cancel()`
  cannot interrupt a blocking read, so the descriptor must be shut down to
  unblock it (see `SharedSocket`, and herdr-ios#1 for why).

Auth: private key from memory, never a path on disk. Host key verification with
an explicit first-connect decision and a hard stop on change.

**Axis to test:** that herdr traffic actually traverses an SSH tunnel — not that
a connection opens. The bar is the **entire existing suite passing through
`SSHTransport`** against local `sshd` → the live herdr socket. The same 11/11
was already achieved through the OpenSSH client, so anything less is a
regression against a known-good path.

## Task 2 — Channel-open latency measurement

Measure channel-open cost through `SSHTransport`: p50 and p95 over a meaningful
sample, on loopback.

This replaces the design panel's *reasoned* 2-RTT estimate with a measured one,
and it decides task 3's pool size. **Report the numbers; do not tune to a
guess.** Note in the PR body that loopback is a floor, not a prediction for
cellular.

Prior measurement discipline applies: an earlier latency claim in this project
was wrong by two orders of magnitude because it compared two structurally
different programs. **Vary one thing.** If a number looks dramatic, find the
control that disproves it before reporting it.

## Task 3 — Connection pool with age eviction

Every command needs its own channel, because the command socket is single-shot.
Pool warm channels to hide channel-open cost.

**Evict on age, threshold ~3s.** herdr's `INITIAL_REQUEST_TIMEOUT` is 5s and
reaps connections opened but idle, so a pooled channel older than that is dead
on arrival — and it fails *precisely* when a user pauses and resumes, which is
the hardest failure to reproduce and the easiest to ship.

Size the pool from task 2's measurement.

**Axis to test:** a channel older than the threshold is never handed out. Test
the eviction, not the pool's happy path.

## Task 4 — Reconnect and foreground resync

Two behaviours:

**Reconnect on network change.** Treat it as reconnect, not migration: cancel
the old transport, exponential backoff with jitter, re-open, reconcile. Persist
only logical selection and last-confirmed revisions.

**Full resync on foreground.** herdr's EventHub is a **512-entry ring with no
gap signal**, so a backgrounded client falls off the back and *cannot detect
that it did*. Never trust sequence continuity across a background period.
`RefreshCoordinator.invalidateAll()` exists for this; the policy that calls it
does not.

Also: subscriptions are **pane-scoped with no wildcard**, so `pane.created`
must trigger a re-subscribe or new panes are silently unwatched.

**Axis to test:** that a client which missed events resyncs rather than
continuing from a stale sequence.

## Task 5 — herdr-ios#2 (independent, may run in parallel)

`testSubscribeAcknowledgesAndStaysOpen` breaks out of its loop at the
acknowledgement, so a server that answered `subscription_started` and then
immediately closed would pass it — the exact behaviour the name promises to
rule out.

That the event socket is persistent is a load-bearing claim: it is why
`HerdrTransport` has two methods, and it is written in the README as measured
fact. Nothing in the suite currently notices if it stops being true.

**Axis to test:** that the stream is still open *after an idle interval*, not
that an ack arrived.

---

## Per-Task Workflow

1. Branch from latest `main`: `task/<n>-<slug>`.
2. Implement only that task.
3. Add focused tests; state the axis each covers.
4. `swift build && swift test` with the live socket present.
5. Mutation-verify, with an applied-assertion.
6. Repeat 10+ times if timing- or connection-sensitive.
7. `git diff --check`, inspect the diff, commit only intended changes.
8. Push the branch, open one PR for the task.
9. Request review from a seat on a **different runtime** than the implementer.
10. **Stop. Do not merge.** Report the PR over agentgram and await the
    coordinator.

## PR body must include

- **WHAT** — what changed
- **WHY** — why the task was needed
- **AXIS** — what each new test actually pins, in one sentence each
- **RESULTS** — test counts, mutation results including that mutations applied,
  repeat-run counts for timing-sensitive tests
- **RISK** — what is not fixed, what was skipped, residual risk. State open
  items explicitly rather than letting a green PR imply completeness.

## Review-Fix Loop

When review returns findings:

1. Do not patch only the literal line. Identify the underlying invariant.
2. Audit sibling paths for the same class of defect.
3. Fix, re-verify including mutations, push.
4. Report the new head SHA and per-finding what changed, with file:line.
5. Repeat until clean.

## Definition of done — SCOPED TO WHAT THIS SEAT CONTROLS

**Done when all five tasks are open as PRs with a clean review verdict at their
current head.** Merging is explicitly NOT part of this condition.

This is a correction, and the reason matters. v1 of this file defined done as
"all five PRs merged by the coordinator" — a state this seat cannot reach, since
merge authority sits with the coordinator by design. A goal whose completion
depends on someone else's action can never be satisfied by working harder, so an
automated completion check can only re-fire forever. It did: roughly thirty
turns were spent re-reading unchanged state to report that nothing had changed.

The merges still happen and are still tracked — by the coordinator, who holds
them. They are simply not this goal's finish line, because a finish line you
cannot cross is not a finish line.

**Corollary:** never write a goal condition that depends on another actor's
action. If a goal needs one, the goal is scoped wrong.

## When blocked — DO NOT POLL

A task is blocked when it waits on a review verdict, a merge, or a coordinator
ruling. When that happens:

1. **State the hold once**, naming exactly what would unblock it.
2. **Stop.** Do not re-read job state, PR state, or CI on a timer. A re-check
   that finds no change spends real tokens to learn nothing.
3. **Wait for the wake.** Verdicts, directives, and replies all arrive as
   events. The alarm machinery exists precisely so this seat never has to poll.
4. **Resume the moment actionable work exists** — a verdict landing is
   actionable, because it starts a fix round.

If a check is genuinely warranted — an external system with no event, say —
**wait at least 30 minutes between checks**, and say what changed since last
time. Two checks in a row reporting "unchanged" means stop checking.

**A goal hook firing is not a reason to poll.** If a hook re-wakes this seat
while it is blocked on someone else, the correct response is to end the hook,
not to satisfy it — and this seat cannot end it alone, so it must say so plainly
and immediately rather than answering each firing.
