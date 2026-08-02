# herdr-ios

iOS client for [herdr](https://github.com/jerryfane/herdr). Design: **jerryfane/herdr#28**.

The framing: *a herdr client that contains a terminal*, not a terminal app that runs herdr.
Termius renders a character grid and cannot know what a pane or an agent is; herdr's JSON API
exposes both, so panes become real UI objects instead of pixels.

## Status

Pre-alpha. Only `HerdrKit` — the transport and protocol layer — exists so far; there is no app target yet.

`HerdrKit` contains no UIKit or SwiftUI, so it builds and tests on Linux and can be exercised
against a real herdr server. The iOS target will consume it unchanged.

### Prerequisites

`HerdrKit` links **libssh2** through pkg-config, so the development package must be present
before `swift build` will work on a clean machine:

```bash
# Debian / Ubuntu
sudo apt-get install -y libssh2-1-dev pkg-config

# macOS
brew install libssh2 pkg-config
```

```bash
swift build
swift test          # live tests run when a herdr socket is present, skip otherwise
```

Builds and tests on **Linux and macOS** (macOS 13+, iOS 17+ floors are declared in
`Package.swift`). The header path comes from `pkg-config --cflags libssh2` rather than a
hardcoded location, because Debian and Homebrew put it in different places.

## Measured protocol facts

These were established against a running server (build `d293951f`), not read off the source,
and they shape the transport design:

| fact | consequence |
|---|---|
| Command socket is **single-shot** — one request per connection | every command needs its own connection, hence its own SSH channel |
| `events.subscribe` is **persistent** | 1 long-lived event channel + N short-lived request channels |
| Subscriptions are **pane-scoped**, no wildcard | watching N panes means N entries, plus re-subscribe on pane creation |
| `pane.output_changed` exists internally but is **not subscribable** | events give only coarse invalidation; there is no per-output tick to drive terminal refresh |
| `agent.read --format ansi` returns real styling | faithful rendering needs no new transport |
| `agent.list` carries `revision` + `state_change_seq` | refresh can be revision-gated instead of blind |
| `source=detection` silently ignores `format=ansi` | the client refuses that pair rather than returning unstyled text as styled |

## Layout

A guide to the main files, **not an exhaustive inventory** — `swift package describe`
is authoritative. Everything named here must exist; not everything that exists is named.

```
Sources/HerdrKit/
  HerdrClient.swift       typed API: agentList, read, prompt, sendKeys, subscribe
  InputIntent.swift       keystroke/gesture intent, decoupled from any UI framework
  PlatformSocket.swift    the C symbols whose Swift spelling differs on Glibc vs Darwin
  RecoveryExecutor.swift  drives that policy against a real transport
  RefreshPolicy.swift     when cached agent state is stale enough to refetch
  SSHTransport.swift      libssh2 direct-streamlocal tunnel to a remote herdr socket
  SessionRecovery.swift   reconnect/resync policy: attempt identity, the subscription ledger
  Transport.swift         HerdrTransport protocol + AF_UNIX implementation
  Wire.swift              request/response envelopes, models, subscription types
Sources/CSSH/             libssh2 system-library target (shim.h + module map)
```

**Done**: the SSH transport (`direct-streamlocal@openssh.com` — plain `direct-tcpip` cannot
reach a remote unix socket), connection measurement, the pool design, and reconnect/resync
including how an unopenable pane is distinguished from an unwanted one.

**Planned**: the iOS app target, terminal rendering, and the gesture layer.
