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
  On a herdr that advertises `events_v2`, rows change as status events arrive, including agents on
  federated machines the coordinator relays; the list is re-fetched every 30 s as a backstop and
  after a stream reconnect. An older herdr is polled every 5 s.
  On iPad and Mac, the empty detail column is a live terminal field: it stirs under the pointer
  or a finger, ripples on a tap, and your agents type their current activity into it. Hovering a
  row types that agent's line beside it. With Reduce Motion on, only the typing remains.
- **Live terminal** — a full SwiftTerm terminal for any pane, one tap behind its card, with gestures
  to page between agents, tail the output, and scroll history.
  History keeps its original row layout, including plain text, so resizing does not rewrap old
  boxes or background blocks. Pan sideways to read wide rows; text stays at your chosen size,
  including when a desktop viewer holds a wider grid. New output wraps at the current PTY width.
  Sideways scrolling follows the visible rows: moving into a narrow section returns to its left edge.
  Search, link lookup, and copying include the full width of archived rows.
  Resizing preserves your reading position, including after a momentum scroll; live followers
  stay at the tail. The on-screen Ctrl key arms one native terminal chord in direct input,
  or a control character in the reply field.
- **Gram** — direct messaging between you and your agents: get pinged when one needs input, send text,
  and share images, videos, or files (several at once) straight to an agent.
- **Composer**: Terminal and Gram share one editor. It is a single row beside the mic and
  send buttons until the text wraps; then the buttons drop to a toolbar and the text grows
  to five lines before scrolling. From three lines, a handle opens a tall editor. Dictation
  shows a live waveform and a glowing border. Attachments show per-file progress inside
  the card. Terminal quick keys stay above the card. In a terminal the composer grows
  over the terminal's bottom rows instead of shrinking it, so typing never resizes the
  agent's screen. On iPhone, Send dismisses the keyboard without forcing a history reader
  back to live output. On iPad, the composer stays focused; use Collapse keyboard to dismiss it.
- **Host picker** — native system typography for names, addresses, and guidance, with
  higher-contrast supporting text and the app's text-size preference respected.
  Copyable shell commands and terminal output retain their monospaced fonts.
- **Guest access** — share one agent with someone outside your machines from its ••• menu. They
  get a one-use invite (QR code or link), watch the live terminal and message the agent through
  a relay, end to end encrypted, with every message labelled `<name> (via HerdrUp):`. Settings →
  Shared access lists who has access on each machine, revokes it, and shows the activity log.

## Requirements

herdrup is a client — it talks to a **herdr** daemon running on your own machine over SSH (nothing is
public; it rides your own network). You need the fork that adds the gram / push / live-terminal APIs:
[**jerryfane/herdr**](https://github.com/jerryfane/herdr). The app tells you if it's talking to a
daemon that doesn't have them.

Push notifications go through the HerdrUp push relay (`push.herdrup.themartian.app`), so your machine
needs no Apple push key. The app enrolls its push tokens with the relay and gives the daemon the sealed
capability it gets back; notification text passes through the relay but is never stored or logged.
Settings → Notifications shows whether the connected machine can send them.

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

# The vendored terminal core — also Linux-buildable
swift test --package-path Vendor/SwiftTerm
```

`HerdrKit` contains no UIKit or SwiftUI, so it stays Linux-buildable and can be exercised against a real
herdr server; the iOS app consumes it unchanged. Floors: macOS 14+, iOS 17+ (declared in `Package.swift`
— macOS 14 because Citadel requires it).

SwiftTerm is vendored at [`Vendor/SwiftTerm`](Vendor/SwiftTerm), based on upstream v1.15.0,
commit `dd2fb8ac5b861e7bf617c872895e338f38165648`. Local changes retain viewport anchors and terminal
modes during geometry/font commits, preserve archived row widths when the app opts in, and expose
managed-size and completed-paint hooks. The default library mode still reflows text. The app commits
geometry only from ordered stream frames; a short retained frame covers resize transitions without
stretching text or restarting the stream. For unmarked output,
reveal uses a bounded quiet/deadline heuristic rather than assuming a semantic redraw-complete signal.
CI runs core tests on Linux and UIKit/interaction regressions on both iPhone and iPad simulators.

## Architecture

```
App/                     the SwiftUI app (terminal, status board, Gram, Settings) — iOS only
Sources/HerdrKit/        pure-Swift transport + typed API — Linux-testable, no UI framework
  CitadelTransport.swift   pure-Swift SSH transport: execs `herdr api-bridge` per channel
  HerdrClient.swift        typed API: agentList, read, prompt, sendKeys, gram, subscribe
  AgentStatusStream.swift  all-pane status stream lines (events v2) and row patching
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
| Subscriptions are **pane-scoped**, no wildcard, before events v2 | watching N panes means N entries + re-subscribe on pane creation; an `events_v2` daemon accepts all-pane status and turn entries, so the status board holds one stream |
| `agent.read --format ansi` returns real styling | faithful rendering needs no new transport |
| `agent.list` carries `revision` + `state_change_seq` | refresh can be revision-gated instead of blind |

## Design

Dark, deep-desaturated navy — never black. The design system (`App/DesignSystem.swift`) is taken from the
Claude Design kit (design: [jerryfane/herdr#28](https://github.com/jerryfane/herdr/issues/28)): colour is
*meaning* (amber = waiting on you, red = died, blue = working, green = done), monospace is the machine
voice and a proportional sans is the app voice.

## License

[Apache-2.0](LICENSE).
