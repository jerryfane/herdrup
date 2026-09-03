# herdrup

**Answer your AI coding agents from your phone.**

herdrup is an iOS client for [herdr](https://github.com/jerryfane/herdr) — a calm status
board for the coding agents running on your machine, with a real terminal one tap behind each.
When an agent needs you, you see it at a glance and can reply from anywhere.

[**⬇ Download on the App Store**](https://apps.apple.com/app/id6798087089) · 🌐 [herdrup.themartian.app](https://herdrup.themartian.app)

The framing is *a herdr client that contains a terminal*, not a terminal app that happens to run
herdr. A generic SSH terminal renders a character grid and cannot know what a pane or an agent is;
herdr's JSON API exposes both, so panes and agents become real UI objects instead of pixels.

## What it does

- **Status board** — every agent grouped by what it needs: *needs you* (amber), *working*, *done*,
  *stopped*. Colour is meaning, not decoration — the one signal that matters reads instantly.
- **Live terminal** — a full SwiftTerm terminal for any pane, one tap behind its card, with gestures
  to page between agents, tail the output, and scroll history.
- **Gram** — direct messaging between you and your agents: get pinged when one needs input, send text,
  and share images, videos, or files (several at once) straight to an agent.

## Requirements

herdrup is a client — it talks to a **herdr** daemon running on your own machine over SSH (nothing is
public; it rides your own network). You need the fork that adds the gram / push / live-terminal APIs:
[**jerryfane/herdr**](https://github.com/jerryfane/herdr). The app tells you if it's talking to a
daemon that doesn't have them.

The SSH transport is **pure Swift** (swift-nio-ssh + [Citadel](https://github.com/orlandos-nl/Citadel)) —
there is no system libssh2 to install, which is exactly what lets the protocol layer link into iOS.

## Getting it

**[Download on the App Store](https://apps.apple.com/app/id6798087089)** — herdrup is live, free, and
iPhone + iPad (it also installs on Apple Silicon Macs as a Designed-for-iPad app).

You can also [build it yourself](#building-from-source); it is Apache-2.0 and the whole client is in
this repository.

## Building from source

The Xcode project is **generated** from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (there is no committed `.xcodeproj`), so the app can be
authored and reviewed without an opaque project blob.

```bash
# The app (macOS + Xcode)
brew install xcodegen
xcodegen generate
xcodebuild -scheme Herdr -destination 'generic/platform=iOS Simulator' build

# The protocol layer, HerdrKit — builds and tests on Linux and macOS
swift build
swift test          # live tests run when a herdr socket + sshd are present; skip otherwise
```

`HerdrKit` contains no UIKit or SwiftUI, so it stays Linux-buildable and can be exercised against a real
herdr server; the iOS app consumes it unchanged. Floors: macOS 14+, iOS 17+ (declared in `Package.swift`
— macOS 14 because Citadel requires it).

## Architecture

```
App/                     the SwiftUI app (terminal, status board, Gram, Settings) — iOS only
Sources/HerdrKit/        pure-Swift transport + typed API — Linux-testable, no UI framework
  CitadelTransport.swift   pure-Swift SSH transport: execs `herdr api-bridge` per channel
  HerdrClient.swift        typed API: agentList, read, prompt, sendKeys, gram, subscribe
  AgentList.swift          agent-list model with fail-open-visible unknown statuses
  HostKeyPinning.swift     TOFU host-key policy + the nio-ssh validator bridge
  SessionRecovery.swift    reconnect/resync policy: attempt identity, the subscription ledger
Tests/HerdrKitTests/     protocol/transport unit tests (run on Linux)
```

A guide to the main files, not an exhaustive inventory — `swift package describe` is authoritative.

### Measured protocol facts

These were established against a running server, not read off the source, and they shape the transport:

| fact | consequence |
|---|---|
| The command socket is **single-shot** — one request per connection | every command needs its own SSH channel |
| `events.subscribe` is **persistent** | one long-lived event channel + N short-lived request channels |
| Subscriptions are **pane-scoped**, no wildcard | watching N panes means N entries + re-subscribe on pane creation |
| `agent.read --format ansi` returns real styling | faithful rendering needs no new transport |
| `agent.list` carries `revision` + `state_change_seq` | refresh can be revision-gated instead of blind |

## Design

Dark, deep-desaturated navy — never black. The design system (`App/DesignSystem.swift`) is taken from the
Claude Design kit (design: [jerryfane/herdr#28](https://github.com/jerryfane/herdr/issues/28)): colour is
*meaning* (amber = waiting on you, red = died, blue = working, green = done), monospace is the machine
voice and a proportional sans is the app voice.

## License

[Apache-2.0](LICENSE).
