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
  The app hands its terminal size back when it goes to the background or an agent stays hidden
  for 25 s, so another device viewing the same agent gets its own width back (herdr applies the
  narrower size after its 20 s debounce) instead of waiting for the claim to expire.
  Sideways scrolling follows the visible rows: moving into a narrow section returns to its left edge.
  Search, link lookup, and copying include the full width of archived rows.
  Resizing preserves your reading position, including after a momentum scroll; live followers
  stay at the tail. The on-screen Ctrl key arms one native terminal chord in direct input,
  or a control character in the reply field.
  Keys typed into a pane on the connected machine go out the moment you type them, in order,
  on one held `pane.input.stream` channel per pane (herdr 0.9.3+) instead of waiting for the
  previous key's reply; federated panes and older herdr builds keep using `pane.send_text`.
  Settings → Typing latency measures how long your own keys take to reach the screen, per
  machine and per network (Wi-Fi or cellular): the wait to send, the server's reply, the echo
  and the painted frame, typical and slow (90%). Type in a terminal, then open it; Copy report
  gives plain text to paste into an issue. It is always on and keeps the last 1000 keys each.
  Instant typing (Settings → Typing; Auto, Always or Off) draws what you type at once, mosh-style,
  then checks each guess against the machine's own screen once it has the key: a right guess
  stays, a wrong one disappears. Nothing shows until the pane has echoed a key once, so a
  password prompt never shows your typing. Auto shows guesses only on a slow link (round trip
  over 30 ms) and underlines unconfirmed ones over 80 ms. Typing latency also reports key to
  prediction and how many guesses were shown, confirmed and wrong.
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

After `herdr pair`, start herdr on that computer with `herdr`; pairing alone doesn't start it. If you
install the fork over a herdr that is already running, restart it so the new version runs:
`herdr server stop`, then `herdr`. Stopping closes the agents and terminals running in herdr. The app
shows these commands where they're needed (first run, after pairing, "herdr isn't running", and the
missing-features notice).

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
The app and test bundles are built before the timed UI runs. The first simulator boot
allows ten minutes for cold data migration; later readiness checks allow five minutes.
Both force termination after another 15 seconds and retain a boot log.
Debug resize receipts are per pane, so a background terminal's fixed grid
cannot overwrite the foreground terminal's keyboard-resize result.
The built-version check selects `Herdr.app`, not the separate UI test runner bundle.
Gram search regressions check matching results and older-page fetch counts, not prompt wording.
Gram state checks poll completed accessibility queries directly, preserving their conditions
when a slow lookup consumes the waiter's deadline. Synchronous queries can exceed that deadline.
Terminal UI queries match the exact `terminal-surface` accessibility identifier rather than
searching unrelated labels and values. Focus, input and viewport assertions remain unchanged.

The four simulator jobs run in parallel. Gram shares the iPhone terminal job; the other
iPhone job runs font, status-motion and remaining app tests. A failed first run still fails
its job even if the diagnostic rerun passes; manual reruns execute the entire selected job.
The optimized Settings job builds only the selected simulator architecture and caches
`Build/Products` for the same workflow run, commit, Xcode/SDK, OS, architecture and workspace.
It saves a successful build before testing, so a test failure does not discard the build.
Cache hits still run the Settings regression and attached-crash check; test results are
never cached. Release archives and TestFlight builds are unchanged.

The shared native composer reconciles external text edits after the SwiftUI layout pass,
using the current binding rather than a captured layout value. This preserves newer
keystrokes while still applying dictation, mention completion, restored drafts, and send clears.

## Architecture

```
App/                     the SwiftUI app (terminal, status board, Gram, Settings) — iOS only
Sources/HerdrKit/        pure-Swift transport + typed API — Linux-testable, no UI framework
  CitadelTransport.swift   pure-Swift SSH transport: one-off requests over `herdr api-bridge`
  RequestChannel.swift     held `api-bridge --multi` channel per herdr session (when herdr has it)
  HerdrClient.swift        typed API: agentList, read, prompt, sendKeys, gram, subscribe
  AgentStatusStream.swift  all-pane status stream lines (events v2) and row patching
  AgentList.swift          agent-list model with fail-open-visible unknown statuses
  HostKeyPinning.swift     TOFU host-key policy + the nio-ssh validator bridge
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

Live agent rows use system text, equal-height previews and a name-based avatar with a stable
colour; the badge still carries status. Archive entries share the name colour but keep their
archive icon. The Gram feed uses the same avatars; guest-view identity styling is unchanged.
Previews omit leading CLI prompt/spinner marks. Search is a plain field; Clear appears while
text is present.
Agents, Gram and Settings share one compact bar with a small centred title on iPhone, iPad and
Designed-for-iPad Mac. Back sits on the left on iPhone, Mac and a full-screen iPad. In an
iPad window, whose controls take the top-left corner, Back joins the actions and sidebar
toggle on the right, and the bar's capsules line up with the window controls inside the
window's top edge. On Mac, Back sits below the separate system window-title row; other
actions stay on the right. Pushed Settings pages follow the same Back placement. The leading
control is declared before the title, matching
the visual reading order. The sidebar rail and ⌘K remain available.
Settings builds its compact index in a separate view body, keeping the large section tuple
off the adaptive navigation stack. CI checks resize/resume in an optimized simulator build
with a device-sized 1008 KiB main stack, and rejects attached crashes even if XCTest reports a pass.

Gram reads like iMessage in herdr's colours: your messages are violet bubbles on the right,
agents' sit on the left under their name, machine (“vetrina · mac-studio”) and avatar, with
time separators, an amber unread rule and green/grey Grabbed/Delivered lines. Long reports
fold to eight lines with Read more; fenced code sits in a monospaced box with its own Copy;
images and files are cards that open on a tap (Save to Files is in the long-press / right-click
menu), pictures show inline, and a download draws the composer's ring. On iPad and Mac the
sidebar holds Gram's search field (⌘F; no mic, the composer keeps dictation) and its two
conversations, Gram and Saved, as Messages rows, with Read all and Refresh in the bar.
Unread-count updates redraw the badge and sidebar readers, not the whole tab host, so they
do not interrupt a message's open context menu.
Saved reads like the feed: oldest at the top, opening at the newest, older ones drawn as you scroll up.
Search filters the loaded messages, newest match at the bottom; scrolling to the top of the results (or
“Search older messages” when none match) fetches older pages until another match turns up.

Gram's composer is the terminal's: attach, mic and send sit where they do in a pane. Type @ to
send to one agent: a “Send to one agent” list opens above the composer, and picking one puts a
violet @name in the text, which addresses that exact agent and, when it leads, is not sent with
it (nor is a following “,” or “:”). Two agents with one name are listed with their machines;
a typed name they share, or a leading @name that matches no agent in Gram, holds Send and says
why above the composer. With no @ the message goes to the shared queue, where any agent can
grab it. A long message shows its first eight lines and a Read more link (Show less folds it
back). Bubble tails mark text only, never an image or file card. The header floats over the
feed, so messages scroll under it.

## License

[Apache-2.0](LICENSE).
