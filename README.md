# herdr-ios

iOS client for [herdr](https://github.com/jerryfane/herdr). Design: **jerryfane/herdr#28**.

The framing: *a herdr client that contains a terminal*, not a terminal app that runs herdr.
Termius renders a character grid and cannot know what a pane or an agent is; herdr's JSON API
exposes both, so panes become real UI objects instead of pixels.

## Status

Pre-alpha. Only `HerdrKit` — the transport and protocol layer — exists so far.

`HerdrKit` contains no UIKit or SwiftUI, so it builds and tests on Linux and can be exercised
against a real herdr server. The iOS target will consume it unchanged.

```bash
swift build
swift test          # live tests run when a herdr socket is present, skip otherwise
```

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

```
Sources/HerdrKit/
  Transport.swift    HerdrTransport protocol + AF_UNIX implementation
  Wire.swift         request/response envelopes, models, subscription types
  HerdrClient.swift  typed API: agentList, read, prompt, sendKeys, subscribe
```

Planned: SSH transport (`direct-streamlocal@openssh.com` — note that plain `direct-tcpip`
cannot reach a remote unix socket), terminal rendering, and the gesture layer.
