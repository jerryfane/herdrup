#if canImport(UIKit)
import SwiftUI
import UIKit
import SwiftTerm
import GameController
import HerdrKit

/// One-shot claim gate: `claim()` returns true to EXACTLY ONE caller, so a
/// `CheckedContinuation` raced between two tasks (a read vs a timeout) is resumed at
/// most once. Used by the scrollback backfill to bound a read that the transport won't
/// cancel — the loser is abandoned rather than awaited.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// A live SwiftTerm terminal for a herdr pane (#40). It consumes
/// `client.streamTerminal(pane:)` — herdr's raw PTY byte firehose — and feeds the
/// bytes to a real VT emulator, so the phone renders a grid-faithful terminal
/// instead of a reflowed snapshot.
///
/// iPhone, iPad, and hardware keyboards can drive the terminal directly. On iPhone,
/// the terminal becomes first responder when the reply field is not focused and shows
/// the software keyboard; SwiftTerm's delegate forwards its key→bytes translation to
/// the PTY. The reply/Send bar remains the deliberate path for agent prompts and saved
/// messages. SCROLL remains constrained: a pan on the alternate screen sends
/// wheel/arrow sequences to the agent (see `handleScrollPan`), never a keystroke.
/// iPad accepts direct terminal keys only while a hardware keyboard is present.
///
/// Geometry: the view reports its own laid-out grid to the server via `setPTYSize`
/// so the stream is generated at the phone's width. While the terminal view is open
/// the phone OWNS the pane geometry (`lock:true`, Fix A): the server pins the shared
/// PTY to the phone's fit, so the agent's TUI lays out at the phone's width and fits
/// crisply with no horizontal overflow. A co-viewing desktop narrows to that width
/// while the phone views the pane; on teardown we fire one `lock:false` to hand
/// ownership back (see `releaseGeometryOwnership`) so the desktop reclaims its width.
struct LiveTerminalView: UIViewRepresentable {
    let client: HerdrClient
    let paneID: String
    /// Called when the reader swipes horizontally to page between agents: +1 for the
    /// next agent (swipe left), -1 for the previous (swipe right). Nil (or a no-op) when
    /// there is no list context to page through. Refreshed on every update so the
    /// closure never captures a stale view.
    var onNavigate: ((Int) -> Void)? = nil
    /// Whether this pane is the one on screen. A keep-mounted pane that goes offscreen
    /// (another agent is fronted, or we're back on the list) stays subscribed but must
    /// RELEASE the PTY width-lock so it stops pinning a co-viewing desktop to the phone's
    /// width while nobody's looking; it re-takes the lock when fronted again. Only the
    /// lock lifecycle changes — the stream and the SwiftTerm view stay warm.
    var isForeground: Bool = true
    /// Whether the terminal itself should hold keyboard focus (drive keys straight to the PTY).
    /// On iPhone this opens the software keyboard; on iPad it takes effect only with a
    /// hardware keyboard. Refreshed on every update.
    var wantsTerminalKeyFocus: Bool = false
    /// Called after a terminal tap requests direct PTY input. The parent owns the
    /// SwiftUI focus state so a reply submission can dismiss the keyboard reliably.
    var onTerminalFocusRequest: () -> Void = {}
    /// Bumped by the host to jump this pane to its newest output. `updateUIView`
    /// compares it against the value the Coordinator last executed, so each
    /// increment performs exactly one jump.
    var jumpToTailToken: Int = 0
    /// Reports whether the pane is parked at its newest output. Invoked ONLY when
    /// the value changes, so it cannot re-render SwiftUI on every scroll frame.
    var onTailStateChange: (Bool) -> Void = { _ in }
    /// The host's CURRENT belief about tail state, used to seed a fresh Coordinator on
    /// a remount. Without it a `streamGen` remount resets the Coordinator's baseline to
    /// `true` while the host still holds `false`, and the next jump's `atTail: true`
    /// dedupes away as "no change", leaving the pill visible after a completed jump.
    var isAtTail: Bool = true
    /// Terminal font size in points (the `terminal.fontSize` preference). Applied
    /// in-place via `Coordinator.applyFont` when it changes — re-lays-out the grid,
    /// no view recreation.
    var fontSize: CGFloat = 12.5
    /// Whether this pane's agent is federated/remote (`AgentInfo.machineID != nil`).
    /// A federated pane routes key-drive input via `pane.send_text` (the home daemon
    /// can't proxy the persistent `pane.input.stream` channel). Refreshed on every
    /// update since the agent can resolve as federated after the view mounts. (#139)
    var isFederated: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(client: client, paneID: paneID) }

    func makeUIView(context: Context) -> ReadOnlyTerminalView {
        context.coordinator.paneFontSize =
            min(max(fontSize, Coordinator.minFontSize), Coordinator.maxFontSize)
        let view = ReadOnlyTerminalView(frame: .zero, font: context.coordinator.paneFont)
        context.coordinator.onNavigate = onNavigate
        context.coordinator.isFederated = isFederated
        context.coordinator.onTerminalFocusRequest = onTerminalFocusRequest
        // SEED both baselines from the host before the first `updateUIView`. A remount
        // (the header refresh bumps `streamGen`) builds a fresh Coordinator while the
        // host's `@State` survives, so defaulting them replays the last jump as a second
        // Ctrl+End and mis-dedupes the tail callback.
        context.coordinator.seedBaselines(jumpToTailToken: jumpToTailToken, atTail: isAtTail)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: ReadOnlyTerminalView, context: Context) {
        context.coordinator.onNavigate = onNavigate
        context.coordinator.isFederated = isFederated
        context.coordinator.onTerminalFocusRequest = onTerminalFocusRequest
        context.coordinator.onTailStateChange = onTailStateChange
        // setForeground BEFORE performJumpToTail, deliberately. The jump sends bytes and is
        // now foreground-guarded, and a guard that reads a flag this pass has not yet
        // written is not a guard at all.
        context.coordinator.setForeground(isForeground)
        context.coordinator.performJumpToTail(ifTokenChanged: jumpToTailToken)
        // Drive terminal responder ownership from SwiftUI intent.
        //
        // RESPONDER OWNERSHIP AND KEY ROUTING ARE SEPARATE CONCERNS, and conflating them
        // cost the Copy menu on iPad without a hardware keyboard: gating the *become* on
        // `keyDriveEnabled` meant the responder was never taken there, and SwiftTerm's
        // `doubleTap` selects without taking it either, so `canPerformAction` refused Copy.
        // Owning the responder is free on every platform: iPhone shows its keyboard
        // (which is wanted, it is how you type), and every other idiom has the zero-frame
        // `emptyInputView`, so nothing appears. KEY ROUTING stays gated on
        // `keyDriveEnabled` inside the `send` delegate, which is the only place it belongs.
        //
        // A BACKGROUNDED pane drops its selection UNCONDITIONALLY and resigns if it holds
        // the responder. The clear sits OUTSIDE the first-responder test on purpose: nested
        // inside it, a pane holding a selection WITHOUT the responder kept it across
        // backgrounding, so the sentence above was still not literally true. That is the
        // third time this claim has been written wider than the code, so the code now
        // matches the claim instead of the comment being narrowed again.
        //
        // Only a FOREGROUND pane mid-selection keeps its responder, which is what stops a
        // SwiftUI body pass from hiding the Copy menu.
        if wantsTerminalKeyFocus {
            if !uiView.isFirstResponder { _ = uiView.becomeFirstResponder() }
        } else {
            if !isForeground { uiView.clearSelection() }
            if uiView.isFirstResponder, !isForeground || !uiView.hasActiveSelection {
                uiView.resignFirstResponder()
            }
        }
        context.coordinator.applyFont(size: fontSize)
    }

    static func dismantleUIView(_ uiView: ReadOnlyTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// A `TerminalView` that accepts terminal input on iPhone and on iPad with a
    /// hardware keyboard. On iPhone its normal UIKit input view is retained so the
    /// software keyboard can type directly into the PTY. An iPad without a hardware
    /// keyboard stays selection-and-copy only.
    ///
    /// SCROLL is the LIBRARY's job now. On a normal (shell) buffer the reader
    /// finger-scrolls the retained scrollback through SwiftTerm's own `UIScrollView`,
    /// native and unmodified. SwiftTerm ≥1.14.0 (we ship 1.15.0) fixed the iOS scroll
    /// wiring (issue #486 / PR #587: a `contentOffset`→`yDisp` sync plus a
    /// `terminal.userScrolling` flag), so a scrolled-up reader holds position even
    /// while output streams. We deliberately do NOT override `contentOffset`, claim the
    /// scroll delegate, or run any follow/hold logic here: doing exactly that on
    /// SwiftTerm 1.11.2 SHADOWED the (then-broken) library and dead-locked scrolling
    /// across ~7 TestFlight builds — the defect was in the library, not this file.
    /// The ONLY scroll code we keep is the ALTERNATE-screen pan
    /// (`Coordinator.handleScrollPan`), which sends wheel/arrow scroll INTO a
    /// full-screen TUI that keeps no scrollback of its own.
    final class ReadOnlyTerminalView: TerminalView {
        /// Direct terminal input is available on iPhone through the software keyboard
        /// and on iPad through a physical keyboard. A large iPhone in landscape must
        /// still use the phone path, so this keys off idiom rather than size class.
        var keyDriveEnabled: Bool {
            UIDevice.current.userInterfaceIdiom == .phone
                || (UIDevice.current.userInterfaceIdiom == .pad && GCKeyboard.coalesced != nil)
        }
        /// First responder is allowed on every platform because SwiftTerm text selection
        /// requires it. On iPhone it also presents the software keyboard; on iPad without
        /// a hardware keyboard, input remains disabled by `keyDriveEnabled`.
        override var canBecomeFirstResponder: Bool { true }
        private let emptyInputView = UIView(frame: .zero)

        override init(frame: CGRect, font: UIFont?) {
            super.init(frame: frame, font: font)
            // Inset-free, matching SwiftTerm's own iOS example host: keeps the grid
            // flush and the library's scroll-offset math (`maxContentOffsetY`) free of a
            // shifting safe-area / keyboard inset.
            contentInsetAdjustmentBehavior = .never
            // Keep iPhone's system keyboard. On iPad, suppress a software keyboard while
            // preserving hardware-key delivery and selection/copy behavior.
            if UIDevice.current.userInterfaceIdiom != .phone {
                inputView = emptyInputView
            }
            inputAccessoryView = nil
        }

        /// EMULATOR REPLIES ARE NOT USER INPUT, and this pane is never the primary viewer
        /// of its PTY, so it must not answer the host.
        ///
        /// SwiftTerm funnels two different things into ONE delegate callback. Typed input
        /// arrives via `AppleTerminalView.send(data:)`, which calls `recordUserInput()`
        /// first. Emulator-GENERATED answers arrive through THIS `open` TerminalDelegate
        /// bridge (`iOSTerminalView.swift:1408`): focus reports CSI I and CSI O, DA, DSR
        /// and CPR replies, OSC colour and OSC 52 answers, CSI-t window reports.
        ///
        /// Before iPhone typing existed, the delegate dropped everything on this idiom, so
        /// none of it left the phone. Enabling typing enabled the replies with it, and the
        /// desktop herdr owns the same PTY and already answers those queries, so a second
        /// answerer produces duplicate or contradictory replies to one host request.
        ///
        /// Overriding here drops ONLY the reply bridge; typed input never comes through
        /// this method, so it is untouched. Applied on EVERY idiom, not just phone: iPad
        /// with a hardware keyboard has been forwarding these since key drive shipped, and
        /// a co-viewer answering for the primary is wrong there for the same reason.
        override func send(source: Terminal, data: ArraySlice<UInt8>) {}
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    /// Owns the stream task and marshals frames onto the main actor. Retained by
    /// SwiftUI (via `makeCoordinator`); the `TerminalView` holds only a weak ref
    /// back through `terminalDelegate`.
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        private let client: HerdrClient
        private let paneID: String
        /// Stable per-view identity for the daemon's PTY width-lease (#137). Generated
        /// ONCE per Coordinator (= one view = one live `pane.stream`) and sent UNCHANGED
        /// on BOTH this view's `pane.stream` open AND every `pane.set_pty_size` it makes,
        /// so the lease taken by the resize is the one the daemon drops when this stream
        /// closes. A fresh UUID per instance is deliberate: sharing one id across two
        /// concurrent streams to a pane would let the FIRST close drop the shared lease
        /// while the second is still open (JARVIS review finding #2 — premature shrink).
        private let viewerID = UUID().uuidString
        /// Whether this pane lives on a REMOTE (federated) machine (`AgentInfo.machineID
        /// != nil`). The home daemon can route one-shot `pane.send_text` to a remote pane
        /// (#84) but CANNOT proxy the persistent `pane.input.stream` duplex channel, so a
        /// federated pane skips the channel and delivers every key-drive batch via
        /// `sendText` (see `deliverInput`). Refreshed by `updateUIView` because the agent
        /// can resolve as federated AFTER the view first mounts.
        var isFederated = false
        private weak var view: ReadOnlyTerminalView?
        private var streamTask: Task<Void, Never>?
        /// The single serialized resize drain, if running. Only ever ONE at a time —
        /// it awaits each set_pty_size before the next (so remote resizes can't
        /// complete out of order) and loops until `desired == lastSent`. Cancelled on
        /// teardown.
        private var resizeTask: Task<Void, Never>?
        /// The grid we WANT the PTY at — the latest size `sendPTYSize` was asked for.
        /// The drain drives `lastSent` toward this. Dedup is measured against THIS
        /// (the target), never the last committed size, so a request matching the
        /// committed size while a DIFFERENT resize is in flight is not wrongly dropped.
        private var desiredCols = 0
        private var desiredRows = 0
        /// Last geometry the server CONFIRMED (committed only after a successful
        /// set_pty_size). The drain stops once this equals `desired`.
        private var lastSentCols = 0
        private var lastSentRows = 0
        /// The EFFECTIVE winsize the daemon actually applied, from the `set_pty_size`
        /// response (#137). Under the width-lease arbiter this can EXCEED what this view
        /// requested — a wider co-viewer's lease wins — so it is recorded for truth but
        /// deliberately NOT fed back into `lastSent`: driving the drain toward the
        /// arbiter's width would re-send forever, fighting the arbiter. The view still
        /// RENDERS the applied (wider) grid because SwiftTerm reflows to the server cols
        /// carried on the `pane.stream` itself; this is the coordinator's copy of that truth.
        private var appliedCols = 0
        private var appliedRows = 0
        /// Consecutive failures for the CURRENT target, so the drain's self-retry
        /// backs off and is capped; reset whenever a new target is requested.
        private var resizeRetries = 0
        /// Set once the server sends an `exited` frame, so a normal stream end is
        /// distinguished from an unexpected EOF (which must surface, not freeze).
        private var sawExited = false
        /// Set when the SERVER permanently refused this pane (e.g. `pane_not_found`),
        /// as opposed to the stream dropping. A dropped stream deserves the reconnect
        /// loop; a refusal does not — the pane will never come back, so retrying just
        /// spins "connection lost; reconnecting…" forever with nothing behind it. Any
        /// path that could restart the stream (the backoff task, the heartbeat
        /// watchdog) honours this exactly like `sawExited`.
        private var paneGone = false
        /// Set in `stop()` so a LATE async `sizeChanged` callback (SwiftTerm
        /// dispatches them asynchronously) cannot start a NEW `lock:true` resize
        /// AFTER we've released geometry ownership — which would re-pin the pane and
        /// defeat the release (review HIGH). Once stopped, `sendPTYSize` is inert.
        private var stopped = false

        /// Scrollback backfill: the in-flight `read` (source=.recent, ANSI) fetching history
        /// produced BEFORE the live stream connected, resolved to ANSI bytes (nil on empty /
        /// error / timeout). The FIRST reset awaits it once, to prepend history above the seed.
        private var backfillTask: Task<[UInt8]?, Never>?
        /// Guards the one-time scrollback-cap raise + history prepend to the FIRST reset only.
        private var didSeedOnce = false

        /// Strips terminal graphics escape strings (kitty APC, high-volume DCS) from the raw PTY
        /// bytes before they reach SwiftTerm, which crash-loops on them (#170). Stateful — a graphics
        /// string spans stream chunks — so it is carried across `.data`/`.reset` feeds and reset at
        /// each keyframe. Only stream bytes go through it; app-generated notices are already safe.
        private var graphicsFilter = TerminalGraphicsFilter()
        private func feedFiltered(_ data: Data, into view: TerminalView) {
            let clean = graphicsFilter.filter([UInt8](data)[...])
            if !clean.isEmpty { view.feed(byteArray: clean[...]) }
        }

        /// Auto-reconnect. `reconnectAttempts` drives capped exponential backoff (reset once a
        /// fresh stream delivers a real `.reset`, i.e. it genuinely re-established). `lastStreamActivity`
        /// feeds the heartbeat watchdog: the server pings every 20s (`PING_INTERVAL`), so a long
        /// silence means a stuck / half-open stream that never errors. `streamRunID` tags each stream
        /// so a superseded (cancelled/restarted) task's `streamEnded` cannot trigger a second reconnect.
        /// `reconnectTask` is the pending backoff-delayed restart; `watchdogTask` the periodic checker.
        private var reconnectAttempts = 0
        private var lastStreamActivity = Date()
        private var streamRunID = 0
        private var reconnectTask: Task<Void, Never>?
        private var watchdogTask: Task<Void, Never>?
        /// No stream event (data, ping, resize) for this long → treat the stream as stuck and
        /// reconnect. 2.5× the server's 20s ping, so a single dropped ping is tolerated.
        private static let streamStuckTimeout: TimeInterval = 50

        /// PTY width-lease heartbeat (#137). The daemon expires a viewer's lease on a
        /// 5-minute TTL backstop (`DEFAULT_PTY_LEASE_TTL`), so a stable-size FOREGROUND
        /// view — one that never fires a fresh `sizeChanged` — would silently lose its
        /// lease. This task periodically re-asserts the current committed size (carrying
        /// the same `viewerID`) to refresh the lease. Re-armed by `start()`, cancelled by
        /// `stop()`. Backgrounded/relocking panes are skipped: they have no lease to keep.
        private var heartbeatTask: Task<Void, Never>?
        /// Lease TTL we request on every `lock:true` (`ttl_ms`). Explicit rather than the
        /// server default so the refresh cadence below is provably under it.
        private static let leaseTTLMillis: UInt64 = 300_000                 // 5 min
        /// Lease-refresh cadence — comfortably under `leaseTTLMillis` so a single missed
        /// beat can't lapse the lease (2 min refresh vs 5 min TTL).
        private static let heartbeatIntervalNanos: UInt64 = 120_000_000_000  // 2 min

        /// Page-between-agents callback (see `LiveTerminalView.onNavigate`), refreshed
        /// by `updateUIView`. +1 = next agent, -1 = previous.
        var onNavigate: ((Int) -> Void)?
        /// Requests SwiftUI terminal-input focus after a tap. The parent controls
        /// actual responder ownership so it can dismiss the keyboard after Send.
        var onTerminalFocusRequest: (() -> Void)?
        /// Publishes tail state to the host (see `LiveTerminalView.onTailStateChange`).
        /// Refreshed by `updateUIView`.
        var onTailStateChange: ((Bool) -> Void)?
        /// Last `jumpToTailToken` this Coordinator executed, so one increment performs
        /// exactly one jump even though `updateUIView` runs on every body pass. SEEDED
        /// from the host at `makeUIView`, because a remount builds a fresh Coordinator
        /// while the host's token survives: defaulting to 0 would replay the last jump.
        private var lastJumpToTailToken = 0
        /// Last value published through `onTailStateChange`. Also seeded from the host,
        /// so a remount cannot dedupe away the next genuine transition.
        private var lastReportedAtTail = true

        /// Adopt the host's current jump token and tail belief WITHOUT acting on either.
        /// Called once per Coordinator, before `attach`, so a `streamGen` remount neither
        /// re-sends a jump it already performed nor swallows the next tail callback.
        func seedBaselines(jumpToTailToken: Int, atTail: Bool) {
            lastJumpToTailToken = jumpToTailToken
            lastReportedAtTail = atTail
        }

        /// Per-pane geometry-ownership generation. Each `attach` for a pane id bumps this and
        /// records the value it claimed; the releasing `lock:false` — which can be DELAYED
        /// awaiting an in-flight `lock:true` — is skipped if a NEWER coordinator has since
        /// claimed the same pane. Without it a fast A→B→A swap can leave the pane you are
        /// LOOKING at unlocked: the outgoing coordinator's release lands after the newcomer's
        /// `lock:true`, and `sendPTYSize`'s dedup then never re-locks it. Accessed only on the
        /// main actor (attach/stop) except the post-await read in `releaseGeometryOwnership`,
        /// which hops back via `MainActor.run` — so all access is main-actor-serialized.
        private static var geometryGeneration: [String: Int] = [:]
        private var myGeometryGeneration = 0
        /// The in-flight background `lock:false` release per pane, so a re-show
        /// (`setForeground(true)`) can AWAIT it before re-locking — the re-lock can then never
        /// be overtaken by a reordered release that would leave the visible pane unlocked.
        private static var geometryReleaseTask: [String: Task<Void, Never>] = [:]
        /// Whether this (keep-mounted) pane is currently on screen. Only the FOREGROUND
        /// pane holds the PTY width-lock; a backgrounded pane releases it (see
        /// `setForeground`) so it can't pin a co-viewing desktop while hidden, and a
        /// hidden pane's async `sizeChanged` tracks the grid but never re-locks.
        private var foreground = true
        /// True between a re-show (`setForeground(true)`) and its deferred re-lock completing —
        /// i.e. while we're awaiting the in-flight background `lock:false` before re-taking the
        /// lock. During this window EVERY `sendPTYSize` caller (including `sizeChanged`) must NOT
        /// start a drain, or a `lock:true` could race the still-in-flight `lock:false` on a
        /// separate SSH channel and leave the VISIBLE pane unlocked. The deferred re-lock clears
        /// it and then drives toward the LIVE grid.
        private var relockPending = false
        /// The generation whose lock has already been handed back (a `lock:false` release). A
        /// generation is released AT MOST ONCE: `releaseGeometryOwnership` runs from both
        /// `setForeground(false)` and `stop()` (which itself can run twice — `.exited` then
        /// dismantle — and follows a hide at the SAME generation), and none of those bump the
        /// generation. Without this idempotence a second same-generation release would fire a
        /// redundant `lock:false` (re-resizing the shared PTY) AND let the first release's
        /// generation-keyed self-prune clobber the newer release's registry handle.
        private var releasedGeneration: Int?
        /// Hardware-keyboard connect/disconnect observers so key-drive focus follows the keyboard
        /// live (plug in → the front pane takes focus; unplug → it resigns). Removed in `stop()`.
        private var keyboardObservers: [NSObjectProtocol] = []

        /// IBM Plex Mono (the design's MACHINE voice) at the pane size, falling back
        /// to the system monospace if the bundled face is unavailable. The
        /// PostScript name matches `DesignSystem.Typography`'s mono regular cut.
        static let minFontSize: CGFloat = 9
        static let maxFontSize: CGFloat = 24
        static let defaultFontSize: CGFloat = 12.5
        /// Terminal font size in points, driven by the `terminal.fontSize` preference.
        /// Instance (not static) so it can change at runtime: setting `view.font` from
        /// `applyFont` flows through SwiftTerm's resetFont → resize → sizeChanged →
        /// sendPTYSize, which re-locks the PTY at the new column count.
        var paneFontSize: CGFloat = 12.5
        var paneFont: UIFont {
            UIFont(name: "IBMPlexMono", size: paneFontSize)
                ?? UIFont.monospacedSystemFont(ofSize: paneFontSize, weight: .regular)
        }

        /// Apply a new terminal font size (clamped to [minFontSize, maxFontSize]).
        /// A no-op if unchanged; otherwise setting `view.font` drives the full
        /// re-layout (cell recompute → grid resize → sizeChanged → sendPTYSize).
        func applyFont(size: CGFloat) {
            let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
            guard clamped != paneFontSize else { return }
            paneFontSize = clamped
            view?.font = paneFont
        }

        /// Scrollback backfill — so scrolling up shows output produced BEFORE this connection
        /// (open/refresh only seeds the current screen otherwise). On each connect we fetch the
        /// last `backfillLines` rendered rows (server `recent`, incl. scrollback, as ANSI) and
        /// feed them into SwiftTerm's scrollback ABOVE the live seed. `0` disables the feature.
        static let backfillLines: UInt32 = 1000            // server clamps `recent` to 1000 rows
        /// SwiftTerm scrollback ring, raised once per connect from its ~500 default. MUST stay
        /// >= backfillLines + live tail so a full backfill is retained (not truncated).
        static let scrollbackCap = 4000
        /// Safety cap so a truly hung `read` can't stall the seed forever — NOT a tight budget.
        /// The read runs concurrently with the stream's fresh SSH connect (~1-2s), and the reset
        /// only arrives after that connect, so a generous cap adds little to first paint in the
        /// normal case. The server renders `recent` instantly (~5ms); the real cost is the phone
        /// transferring up to ~200 KB of ANSI over SSH/Tailscale, which the old 1.2s budget cut off
        /// (→ zero history on real panes). On timeout we skip history and paint the seed as before.
        static let backfillTimeoutNanos: UInt64 = 6_000_000_000

        init(client: HerdrClient, paneID: String) {
            self.client = client
            self.paneID = paneID
        }

        func attach(_ view: ReadOnlyTerminalView) {
            self.view = view
            view.terminalDelegate = self
            // Turn the VIEW's touch→mouse-byte conversion OFF unconditionally. Two reasons:
            // (1) under key drive a tap SwiftTerm turned into a mouse report could leak bytes to
            // the PTY (`send` FORWARDS output there); (2) in the read-only case it lets a tap or
            // long-press start a LOCAL text selection instead of being swallowed as a mouse event
            // over a mouse-mode TUI. This touches ONLY the view's tap-to-mouse conversion — NOT
            // the emulator's `term.mouseMode` (what emitScroll/handleScrollPan read), so alt-screen
            // / Claude-Code wheel scroll is unaffected.
            view.allowMouseReporting = false
            // Track hardware-keyboard connect/disconnect so key-drive focus follows the keyboard.
            // On connect the front pane becomes first responder (iPad-gated by keyDriveEnabled);
            // on disconnect it resigns. Tokens removed in stop().
            keyboardObservers.append(
                NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self, weak view] _ in
                    // keyDriveEnabled gate keeps this iPad-only (a BT keyboard on iPhone is a no-op,
                    // preserving the read-only path). A keyboard attached MID-session also needs
                    // mouse reporting off, or a tap could leak a mouse report through the now-live send.
                    guard let self, let view, self.foreground, view.keyDriveEnabled else { return }
                    view.allowMouseReporting = false
                    _ = view.becomeFirstResponder()
                })
            keyboardObservers.append(
                NotificationCenter.default.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak view] _ in
                    view?.resignFirstResponder()
                })
            // Claim geometry ownership for this pane (see geometryGeneration): the newest
            // attach wins, and an older coordinator's delayed release checks this before
            // unlocking.
            let gen = (Self.geometryGeneration[paneID] ?? 0) + 1
            Self.geometryGeneration[paneID] = gen
            myGeometryGeneration = gen
            // Symmetric with setForeground(true): on a fast evict→reopen (or a transient
            // double-mount) of the SAME pane id, a prior coordinator's ALREADY-committed
            // lock:false could otherwise overtake this fresh mount's first lock:true and strand
            // the visible pane unlocked. Defer this mount's first lock (relockPending) until any
            // pending release for this pane has landed. A fresh pane id has no entry → awaits nil
            // → clears at once.
            relockPending = true
            let pane = paneID
            Task { @MainActor [weak self] in
                await Self.geometryReleaseTask[pane]?.value   // let a prior coordinator's release land first
                guard let self, !self.stopped, self.myGeometryGeneration == gen else { return }
                self.relockPending = false
                if self.desiredCols >= 4, self.desiredRows >= 2 {
                    self.sendPTYSize(cols: self.desiredCols, rows: self.desiredRows)
                }
            }
            // A dedicated pan that scrolls the AGENT (see handleScrollPan) — for the
            // alt screen OR any mouse-reporting program (Claude Code). It recognizes
            // SIMULTANEOUSLY with SwiftTerm's own gestures: `gestureRecognizer(_:should
            // RecognizeSimultaneouslyWith:)` returns true below, and UIKit guarantees
            // simultaneous recognition when EITHER delegate says yes — so SwiftTerm's
            // mouse-pan (which has no delegate) cannot starve this one. `allowMouseReporting` is
            // turned OFF for every pane (see attach above), so a tap/long-press starts a LOCAL
            // text selection rather than a mouse report — and under key drive it also means a
            // forwarded tap can never leak mouse bytes to the PTY.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
            scrollPan = pan
            // Two-finger tap jumps to the live tail. Every SwiftTerm recognizer is
            // single-finger, so this needs no failure requirement and costs single,
            // double and triple tap nothing. The single-finger double tap is LEFT TO
            // SwiftTerm: it is the only gesture that word-selects AND installs the
            // drag-to-extend pan, so taking it over removed selection entirely.
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.delegate = self
            twoFingerTap.cancelsTouchesInView = false
            view.addGestureRecognizer(twoFingerTap)
            // TWO TAP RECOGNIZERS, ONE JOB EACH, and the split is load-bearing.
            //
            // A single recognizer doing both jobs DESTROYS THE SELECTION IT EXISTS TO
            // ENABLE. It must not `require(toFail:)` SwiftTerm's double tap, because
            // SwiftTerm's `doubleTap` selects and presents its Copy menu WITHOUT calling
            // `becomeFirstResponder` (only its long press does) while `canPerformAction`
            // gates Copy on being first responder, so firing on tap 1 is the only thing
            // that makes Copy available. But without that failure requirement it ALSO
            // fires on tap 2, and clearing a selection there wipes the word SwiftTerm just
            // selected on the same touch-up. Both recognizers live on the same view with
            // `shouldRecognizeSimultaneouslyWith` true and UIKit does not document their
            // relative order, so it was a coin toss on whether word select survived.
            //
            // FOCUS TAP: no failure requirement, so it fires on tap 1 and establishes the
            // responder in time for tap 2's menu. Taking focus is idempotent, so firing
            // again on tap 2 costs nothing.
            let focusTap = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap(_:)))
            focusTap.delegate = self
            focusTap.cancelsTouchesInView = false
            view.addGestureRecognizer(focusTap)
            // MENU TAP: repositions the Copy menu SwiftTerm puts in the wrong place, and
            // does nothing else. A review measured the menu overlapping the pane header —
            // the back chevron, the title, the NEEDS YOU badge and the refresh icon — by
            // downloading a CI artifact and looking at it. THAT MEASUREMENT IS THE FACT HERE.
            //
            // THE MECHANISM IS NOT SETTLED. I previously wrote that
            // `makeContextMenuRegionForSelection()` builds its avoid-rect from a BUFFER row
            // while the renderer subtracts `yDisp`. A second reviewer traced the same path and
            // could not confirm it: on iOS the TerminalView IS the scroll view, and
            // `calculateTapHit` returns content-space rows — the same space
            // `makeContextMenuRegionForTap(point:)` uses — so the mismatch is not visible in
            // that path. So the defect is observed and the cause is unproven, and the real fix
            // may belong upstream. This re-present is a targeted workaround, not a diagnosis.
            //
            // IT MUST WAIT FOR THE TRIPLE TAP, and this is what made the first version INERT.
            // SwiftTerm defers `doubleTap` behind `tripleTap.require(toFail:)`
            // (iOSTerminalView.swift:1078), so its selection lands about one multi-tap timeout
            // — roughly 0.3s — AFTER tap 2's touch-up. A recognizer with no failure requirement
            // fires immediately, so the async hop ran BEFORE any selection existed, found
            // `hasActiveSelection` false and returned: on a fresh double tap the menu stayed
            // over the header, and on a re-double-tap SwiftTerm's own later presentation won
            // anyway. Final placement was SwiftTerm's in every case. Mirroring the same
            // `require(toFail:)` loop `clearTap` uses puts this after SwiftTerm's own handler,
            // and also stops it firing on tap 2 of a TRIPLE tap.
            //
            // It re-presents only and does not re-select, so the word SwiftTerm just selected
            // survives. `showStandardContextMenu(at:)` DOES call `becomeFirstResponder()`
            // (iOSTerminalView.swift:1392-1396) — an earlier comment here claimed it takes no
            // responder and that was simply false. The practical effect is small, since on
            // iPhone `focusTap` already holds the responder and on iPad the terminal's
            // inputView is zero-frame, but it does bypass the `wantsTerminalKeyFocus` gate, so
            // the hop's `foreground`/`stopped` guards are load-bearing rather than belt-and-braces.
            //
            // Declared BEFORE `clearTap` so that recognizer's "every 2-tap recognizer must
            // fail" loop keeps meaning exactly that.
            let menuTap = UITapGestureRecognizer(target: self, action: #selector(handleMenuRepositionTap(_:)))
            menuTap.numberOfTapsRequired = 2
            menuTap.delegate = self
            menuTap.cancelsTouchesInView = false
            // SwiftTerm's tripleTap is its only 3-tap recognizer; requiring it to fail is what
            // orders this after SwiftTerm's own doubleTap handler.
            for gr in view.gestureRecognizers ?? [] {
                if let t = gr as? UITapGestureRecognizer, t.numberOfTapsRequired == 3 {
                    menuTap.require(toFail: t)
                }
            }
            view.addGestureRecognizer(menuTap)
            // CLEAR TAP: requires SwiftTerm's 2-tap recognizer to fail, exactly as
            // SwiftTerm guards its own `singleTap` (setupGestures does
            // `singleTap.require(toFail: doubleTap)` for this very reason). So it can only
            // fire on a GENUINE single tap, never on tap 2 of a word select. SwiftTerm's
            // doubleTap already requires its tripleTap, so this inherits the whole chain.
            let clearTap = UITapGestureRecognizer(target: self, action: #selector(handleClearSelectionTap(_:)))
            clearTap.delegate = self
            clearTap.cancelsTouchesInView = false
            for gr in view.gestureRecognizers ?? [] {
                if let t = gr as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 {
                    clearTap.require(toFail: t)
                }
            }
            view.addGestureRecognizer(clearTap)
            // (Removed: the horizontal swipe-between-agents recognizers. A finger/mouse drag to
            // SELECT text was triggering them and paging to an unwanted agent; agent switching
            // stays fully reachable via the list/sidebar, and their removal frees horizontal drag
            // for SwiftTerm's drag-to-extend selection. `onNavigate` is left wired but unused.)
            style(view)
            startBackfill()   // fetch history CONCURRENTLY with the stream; the first reset awaits it
            start()
        }

        /// Jump the pane to its newest output. A mouse-mode or alt-screen agent (Claude
        /// Code) captures the wheel and keeps its own viewport, so send it Ctrl+End
        /// (`ESC[1;5F`, scroll-to-bottom plus re-enable auto-follow), read-only exactly
        /// like the scroll bytes and never a keystroke. A plain shell has native
        /// SwiftTerm scrollback, so jump its UIScrollView to the maximum offset.
        ///
        /// Deliberately NOT annotated `@MainActor`, matching `applyFont`: it is called
        /// from `updateUIView` and from a UIKit gesture handler, both already on the
        /// main thread, and the async send hops explicitly.
        func jumpToTail() {
            // `foreground` here too, matching the two byte-sending gesture handlers. Reached
            // from `updateUIView` as well as from the two-finger tap, which is why
            // `setForeground` now runs BEFORE `performJumpToTail`: guarding on a flag this
            // pass has not yet written would guard nothing.
            guard !stopped, foreground, let view else { return }
            let term = view.getTerminal()
            if term.isCurrentBufferAlternate || term.mouseMode != .off {
                // Report the tail ONLY once the send has actually landed. Reporting up
                // front cleared the pill while a rejected or dropped Ctrl+End left the
                // agent's viewport exactly where it was, so the reader lost the affordance
                // and the state lied at the same time.
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    do {
                        _ = try await self.client.sendText(pane: self.paneID, text: "\u{1b}[1;5F")
                        self.reportTailState(atTail: true)
                    } catch {
                        // Keep `lastReportedAtTail` untouched, so the pill stays up and the
                        // reader can retry. A failed jump must not read as a completed one.
                    }
                }
            } else {
                // animated:false — an animated jump is cancelled mid-flight on a streaming
                // pane (SwiftTerm's updateScroller writes the offset back and leaves
                // userScrolling stuck true). A direct set runs contentOffset's didSet →
                // syncYDispFromContentOffset synchronously and re-engages auto-follow.
                let maxY = max(0, view.contentSize.height - view.bounds.height)
                view.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
                // Synchronous and cannot fail, so the tail is true right now.
                reportTailState(atTail: true)
            }
        }

        /// Executes one jump per token increment. `updateUIView` runs on every SwiftUI
        /// body pass, so the token comparison is what makes this idempotent.
        func performJumpToTail(ifTokenChanged token: Int) {
            guard token != lastJumpToTailToken else { return }
            lastJumpToTailToken = token
            jumpToTail()
        }

        /// Publishes tail state to the host, and ONLY on a change, so scrolling cannot
        /// re-render SwiftUI on every frame.
        ///
        /// The publish is deferred one main-queue turn on purpose. `performJumpToTail`
        /// runs INSIDE `updateUIView`, and the jump reports `atTail: true`, so a
        /// synchronous call would mutate SwiftUI `@State` during a view update, which
        /// SwiftUI warns about and can re-enter. The dedupe above stays synchronous, so
        /// deferring cannot publish a stale duplicate.
        private func reportTailState(atTail: Bool) {
            guard atTail != lastReportedAtTail else { return }
            lastReportedAtTail = atTail
            let publish = onTailStateChange
            DispatchQueue.main.async { publish?(atTail) }
        }

        @objc private func handleTwoFingerTap(_ gr: UITapGestureRecognizer) {
            // `foreground` is defence in depth. Today a backgrounded pane is unreachable
            // because the keep-alive container renders it `opacity(0)` and
            // `allowsHitTesting(false)`, but this handler SENDS BYTES, so it should not
            // depend on a host layout decision staying the way it is.
            guard !stopped, foreground, gr.state == .ended else { return }
            jumpToTail()
        }

        /// Establishes responder ownership, and NOTHING else. Fires on tap 1 of any tap
        /// sequence because it carries no failure requirement, which is the only way the
        /// responder exists in time for SwiftTerm's double-tap menu to offer Copy:
        /// SwiftTerm's `doubleTap` selects without becoming first responder, and
        /// `canPerformAction` returns `selection.active` for Copy only to a responder.
        ///
        /// Deliberately does NOT clear a selection. Clearing here fired on tap 2 as well
        /// and wiped the word SwiftTerm had just selected on the same touch-up.
        ///
        /// No `keyDriveEnabled` gate: owning the responder costs nothing on an idiom that
        /// cannot type (zero-frame `emptyInputView`), and whether keys reach the PTY is
        /// decided in `send`.
        @objc private func handleFocusTap(_ gr: UITapGestureRecognizer) {
            guard !stopped, foreground, gr.state == .ended else { return }
            onTerminalFocusRequest?()
        }

        /// Clears an active selection on a GENUINE single tap. Guarded by
        /// `require(toFail:)` against SwiftTerm's 2-tap recognizer at attach time, so it
        /// cannot fire on tap 2 of a word select.
        ///
        /// SwiftTerm's own singleTap clears too, but only when the view is ALREADY first
        /// responder, so on an unfocused pane its tap was spent taking focus and the
        /// selection survived. `clearSelection()` flips `SelectionService.active`, whose
        /// setter notifies `selectionChanged(source:)`, which calls `setNeedsDisplay` and
        /// `disableSelectionPanGesture()`, so one call both redraws and removes the lazy
        /// extend pan.
        @objc private func handleClearSelectionTap(_ gr: UITapGestureRecognizer) {
            guard !stopped, foreground, gr.state == .ended, let view else { return }
            guard view.hasActiveSelection else { return }
            view.clearSelection()
            // So a test can distinguish "the clear reached the view" from "the highlight
            // happened to stop being drawn". No-op outside UI-test builds.
            publishSelectionProbe()
        }

        /// Re-present the Copy menu at the TAP POINT. Ordered AFTER SwiftTerm's own handler by
        /// `menuTap.require(toFail: tripleTap)` — see the `menuTap` comment in `attach` for why
        /// the first version, which had no failure requirement, was inert.
        ///
        /// Guarded on a selection actually existing, so a double tap that selects nothing —
        /// blank space past the end of a line yields an EMPTY range, which SwiftTerm still
        /// marks active but paints nothing — does not get a menu moved onto it. `foreground`
        /// is re-checked inside the hop: a pane can be backgrounded between the tap and the
        /// hop, and a hidden pane must not present a menu. Those guards also bound
        /// `showStandardContextMenu(at:)`'s undocumented `becomeFirstResponder()`, which
        /// bypasses the `wantsTerminalKeyFocus` gate.
        @objc private func handleMenuRepositionTap(_ gr: UITapGestureRecognizer) {
            guard !stopped, foreground, gr.state == .ended, let view else { return }
            let point = gr.location(in: view)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, let view = self.view else { return }
                self.publishSelectionProbe()   // records state even when the guards below refuse
                guard self.foreground, view.hasActiveSelection else { return }
                view.showStandardContextMenu(at: point)
            }
        }

        /// THE SELECTION PROBE — the instrument, and it exists because four consecutive CI runs
        /// of the selection receipt failed on my own measurement rather than on the product,
        /// and two confident diagnoses of why were both wrong.
        ///
        /// A UI test can only see PIXELS, so "no highlight" cannot distinguish between: the
        /// double tap never selected anything, it selected an EMPTY range, a resize wiped the
        /// selection (`processSizeChange` sets `selection.active = false` on any rows/cols
        /// change, AppleTerminalView.swift:232), or the selection exists and simply is not
        /// painted the colour the detector looks for. Those have different fixes and I have
        /// been guessing between them. This publishes the state itself into an accessibility
        /// element so the test reads SwiftTerm's answer instead of inferring one.
        ///
        /// UI-TEST BUILDS ONLY. Gated on the same `HERDR_SCREENSHOT_MOCK` launch environment
        /// the mock transport uses, so a real build never allocates it, never attaches it to the
        /// view tree, and cannot expose terminal contents to the accessibility layer. The label
        /// carries the SELECTED LENGTH, never the selected text.
        private func publishSelectionProbe() {
            guard ProcessInfo.processInfo.environment["HERDR_SCREENSHOT_MOCK"] != nil,
                  let view else { return }
            let probe: UIView
            if let existing = selectionProbe {
                probe = existing
            } else {
                probe = UIView(frame: .zero)
                probe.isAccessibilityElement = true
                probe.accessibilityIdentifier = "terminal-selection-probe"
                view.addSubview(probe)
                selectionProbe = probe
            }
            // `getSelection()` returns the selected TEXT as `String?` (AppleTerminalView.swift
            // :2535) — my first version called `.getSelectedText()` on it, which is the
            // SelectionService method and does not exist here. Only the LENGTH is published.
            let active = view.hasActiveSelection
            let length = view.getSelection()?.count ?? 0
            let term = view.getTerminal()
            probe.accessibilityLabel =
                "sel=\(active ? 1 : 0) len=\(length) rows=\(term.rows) "
                + "cols=\(term.cols) resizes=\(resizeCount)"
        }

        func stop() {
            stopped = true                  // no new resize/scroll may start after this
            view?.terminalDelegate = nil    // stop further SwiftTerm callbacks (sizeChanged)
            view?.isScrollEnabled = true    // restore native scroll if we disabled it mid-drag
                                            // (stop() also runs on .exited while on screen)
            scrollPan?.isEnabled = false    // no drag can send bytes to an exited/replaced pane
            scrollSendTask?.cancel()
            scrollSendTask = nil
            inputSendTask?.cancel()         // no forwarded keystroke can reach an exited/replaced pane
            inputSendTask = nil
            if let channel = inputChannel { // tear down the persistent input channel (issue #62)
                inputChannel = nil
                Task { await channel.close() }
            }
            for token in keyboardObservers { NotificationCenter.default.removeObserver(token) }
            keyboardObservers.removeAll()
            streamTask?.cancel()
            streamTask = nil
            watchdogTask?.cancel()          // stop the stream-stuck watchdog
            watchdogTask = nil
            heartbeatTask?.cancel()         // stop the PTY width-lease keep-alive (#137)
            heartbeatTask = nil
            reconnectTask?.cancel()         // cancel any pending backoff restart
            reconnectTask = nil
            backfillTask?.cancel()
            backfillTask = nil
            releaseGeometryOwnership()
        }

        /// RELEASE the phone's geometry lock (Fix A) when the terminal view closes,
        /// so a co-viewing desktop reclaims its own width. While the view is open we
        /// take ownership with `lock:true` (see `sendPTYSize`) so the shared PTY —
        /// and therefore the agent's TUI — lays out at the phone's width and fits
        /// crisply; on teardown we fire ONE best-effort `lock:false` at the last
        /// known size to hand ownership back. Fire-and-forget: errors are ignored
        /// (the view is going away regardless); it uses the last SENT size, or the
        /// desired size if nothing was confirmed yet.
        ///
        /// ORDERING (review HIGH): the release must land strictly AFTER any in-flight
        /// `lock:true` resize. We do NOT cancel the resize drain — a cancelled task's
        /// already-dispatched request can still apply server-side, and if it lands
        /// AFTER our `lock:false` the pane stays locked (desktop pinned narrow). So we
        /// hand the drain off and AWAIT it first, so its last `lock:true` round-trip
        /// completes before we send the releasing `lock:false`.
        private func releaseGeometryOwnership() {
            let cols = lastSentCols > 0 ? lastSentCols : desiredCols
            let rows = lastSentRows > 0 ? lastSentRows : desiredRows
            let inflight = resizeTask
            resizeTask = nil
            // Leave any existing registry entry in place on this early bail (a pane that never
            // laid out): an older release may still be in flight, and its entry is the only handle
            // a future re-lock has to await it.
            guard cols >= 4, rows >= 2 else { return }
            // Hand a generation's lock back EXACTLY ONCE (see releasedGeneration). A second
            // same-generation release — stop() after a hide, or stop()'s .exited+dismantle double
            // call — is a no-op: after a hide the drain is already nil'd and sendPTYSize is gated,
            // so there is nothing left to release, and skipping it prevents both a redundant
            // lock:false and the prune-clobber of a newer chained release's registry handle.
            guard releasedGeneration != myGeometryGeneration else { return }
            releasedGeneration = myGeometryGeneration
            let client = self.client
            let pane = self.paneID
            let myGen = self.myGeometryGeneration
            let viewerID = self.viewerID   // release THIS view's lease (#137), not the pane's
            // CHAIN releases: await the PREVIOUS entry first, so awaiting the newest release
            // transitively awaits every older one. Without this, overwriting the map here would
            // orphan an older ALREADY-committed lock:false (past its generation guard), and a later
            // re-lock — which awaits only the newest entry — could send lock:true before that older
            // lock:false lands, leaving the visible pane unlocked.
            let previous = Self.geometryReleaseTask[pane]
            Self.geometryReleaseTask[pane] = Task.detached {
                await previous?.value        // an older release's lock:false must land BEFORE ours
                _ = await inflight?.value    // let the in-flight lock:true finish its round-trip
                // If a newer coordinator OR a re-show claimed this pane while we awaited, it owns
                // the lock now — releasing would unlock a pane still on screen. Bail so its
                // lock:true stands. (And if this release DID commit before the re-show bumped the
                // generation, `setForeground(true)` AWAITS this task before it re-locks.)
                let current = await MainActor.run { Coordinator.geometryGeneration[pane] }
                guard current == myGen else { return }
                _ = try? await client.setPTYSize(pane: pane, cols: cols, rows: rows, lock: false, viewerID: viewerID)
                // Best-effort: drop our own registry entry once settled (no newer show/hide/attach
                // bumped the generation). This only runs when the release actually SENT; a release
                // that bailed on the generation guard above leaves the entry for the newer owner
                // (which is correct — clearing it there could clobber a live newer release). So the
                // map holds at most one entry per pane id, overwritten by the next release.
                await MainActor.run {
                    if Coordinator.geometryGeneration[pane] == myGen { Coordinator.geometryReleaseTask[pane] = nil }
                }
            }
        }

        /// Front↔background transition for a KEEP-MOUNTED pane. Only the front pane holds the
        /// PTY width-lock: hiding releases it (WITHOUT tearing the stream down), showing re-takes
        /// it. The VISIBLE pane is never left unlocked because the re-lock's `lock:true` is
        /// guaranteed to be the LAST geometry op: (1) bumping `geometryGeneration` makes a
        /// not-yet-sent background `lock:false` bail on its generation guard; (2) `relockPending`
        /// makes EVERY `sendPTYSize` caller (the re-lock itself AND any `sizeChanged` in the
        /// window) defer while we await the in-flight release, so no `lock:true` can race the
        /// `lock:false`; the deferred re-lock then drives toward the LIVE grid. Different panes own
        /// different PTYs + generation keys, so releases/retakes across panes never contend.
        func setForeground(_ f: Bool) {
            guard !stopped, f != foreground else { return }
            foreground = f
            if f {
                let gen = (Self.geometryGeneration[paneID] ?? 0) + 1
                Self.geometryGeneration[paneID] = gen
                myGeometryGeneration = gen
                lastSentCols = 0                // defeat sendPTYSize's dedup so the re-lock re-sends
                lastSentRows = 0
                relockPending = true            // hold off ALL sendPTYSize until the release lands
                let pending = Self.geometryReleaseTask[paneID]
                Task { @MainActor [weak self] in
                    // Re-fronting a keep-mounted pane whose geometry changed while hidden can leave
                    // stale/overlapping cells visible until the resize round-trip lands — repaint now
                    // (main-actor Task, so the @MainActor forceFullRepaint is called safely).
                    if let self, let view = self.view, self.foreground, !self.stopped {
                        self.forceFullRepaint(view)
                    }
                    await pending?.value        // let any committed lock:false land FIRST
                    guard let self, self.foreground, !self.stopped,
                          self.myGeometryGeneration == gen else { return }   // a newer hide/show superseded us
                    self.relockPending = false
                    self.sendPTYSize(cols: self.desiredCols, rows: self.desiredRows)   // re-take lock:true at the LIVE grid, now last
                }
            } else {
                relockPending = false           // a hide cancels any pending re-lock intent
                releaseGeometryOwnership()       // release lock:false, keep the stream + emulator warm
            }
        }

        // MARK: styling (the design's machine voice)

        private func style(_ view: ReadOnlyTerminalView) {
            view.font = paneFont
            // groundMachine #0B0D1C behind, ink #EEF0F7 text, working-blue caret —
            // the same tokens `DesignSystem.Palette` uses, so the terminal is the
            // one darker ground the design calls for.
            view.nativeBackgroundColor = Self.color(0x0B0D1C)
            view.nativeForegroundColor = Self.color(0xEEF0F7)
            view.backgroundColor = Self.color(0x0B0D1C)
            view.caretColor = Self.color(0x5B9BE8)
            view.isOpaque = true
            // A 16-colour ANSI palette close to the design (status hues in the
            // matching slots). installColors is a no-op unless given exactly 16.
            view.installColors(Self.ansiPalette)
        }

        // MARK: streaming

        /// Fetch recent rendered history (incl. scrollback) as ANSI, bounded by a timeout so it
        /// can never stall the live seed. Runs concurrently with the stream; the FIRST reset
        /// awaits this at the single point where the bytes must land above the seed.
        private func startBackfill() {
            guard Self.backfillLines > 0 else { backfillTask = nil; return }
            let client = self.client, pane = self.paneID
            backfillTask = Task { () -> [UInt8]? in
                // Race the read against the timeout and take whichever finishes FIRST, ABANDONING
                // the loser. The shipped HerdrTransports do NOT honour Task cancellation on the read
                // path, so we must never `await` a hung read — that would leave the first .reset (and
                // every frame queued behind it) suspended forever, a blank terminal. Instead a
                // one-shot gate resumes the continuation exactly once: whichever of the read / the
                // 1.2s sleep fires first wins; a hung read just leaks its background task and we paint
                // the seed with no history, exactly as before the feature.
                let gate = ResumeGate()
                return await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
                    let read = Task {
                        let r = try? await client.read(pane: pane, source: .recent,
                                                       format: .ansi, lines: Self.backfillLines)
                        let bytes = (r?.text).flatMap { $0.isEmpty ? nil : [UInt8]($0.utf8) }
                        if gate.claim() { cont.resume(returning: bytes) }
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: Self.backfillTimeoutNanos)
                        if gate.claim() { read.cancel(); cont.resume(returning: nil) }
                    }
                }
            }
        }

        private func start() {
            streamTask?.cancel()
            sawExited = false
            // Cleared with `sawExited`, and for the same reason: a refusal is permanent for
            // the pane it was about, not for this coordinator. `start()` is only ever reached
            // deliberately once `paneGone` is set — the reconnect task is gated on it — so
            // arriving here means a manual refresh or a different pane, and both deserve a
            // real attempt. Leaving it latched would turn one dead pane into a view that can
            // never show any pane again.
            paneGone = false
            lastStreamActivity = Date()
            streamRunID &+= 1
            let myRun = streamRunID
            startWatchdog()
            startHeartbeat()
            streamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    // Same viewerID as this view's set_pty_size: the daemon ties the
                    // width-lease taken by the resize to THIS stream, dropping it on close.
                    for try await event in self.client.streamTerminal(pane: self.paneID, viewerID: self.viewerID) {
                        if Task.isCancelled { return }
                        await self.handle(event)
                    }
                    await self.streamEnded(nil, run: myRun)
                } catch {
                    await self.streamEnded(error, run: myRun)
                }
            }
        }

        /// Heartbeat watchdog. The server pings every 20s, so if nothing has arrived for
        /// `streamStuckTimeout` the stream is stuck / half-open (a `client.isConnected` TCP that
        /// silently died and will never throw). Force a reconnect. Re-armed by each `start()`,
        /// cancelled by `stop()`.
        private func startWatchdog() {
            watchdogTask?.cancel()
            watchdogTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)   // poll every 5s
                    guard let self, !self.stopped, !self.sawExited, !self.paneGone else { return }
                    if Date().timeIntervalSince(self.lastStreamActivity) > Self.streamStuckTimeout {
                        self.scheduleReconnect("no response for \(Int(Self.streamStuckTimeout))s")
                        return   // scheduleReconnect → start() re-arms a fresh watchdog
                    }
                }
            }
        }

        /// PTY width-lease keep-alive (#137). A stable-size foreground view fires no fresh
        /// `sizeChanged`, so without this its lease would lapse at the daemon's 5-minute TTL
        /// and a co-viewing desktop would reclaim the width. Every `heartbeatIntervalNanos`
        /// we re-assert the current COMMITTED size (defeating `sendPTYSize`'s dedup so the
        /// same size actually re-sends), which the drain delivers as a fresh `lock:true`
        /// carrying our `viewerID` + TTL. Only a FOREGROUND, non-relocking, idle-drain view
        /// with a committed size refreshes: a hidden/relocking pane has already released its
        /// lease (or is mid-retake) and must not re-pin, and skipping while a drain is in
        /// flight preserves the "at most one set_pty_size in flight per pane" invariant.
        private func startHeartbeat() {
            heartbeatTask?.cancel()
            heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Self.heartbeatIntervalNanos)
                    guard let self, !self.stopped else { return }
                    guard self.foreground, !self.relockPending, self.resizeTask == nil,
                          self.lastSentCols >= 4, self.lastSentRows >= 2 else { continue }
                    let cols = self.lastSentCols, rows = self.lastSentRows
                    self.lastSentCols = 0        // defeat sendPTYSize's dedup so the same size re-sends
                    self.lastSentRows = 0
                    self.sendPTYSize(cols: cols, rows: rows)
                }
            }
        }

        /// Auto-restart a dropped or stuck stream with capped exponential backoff, instead of
        /// leaving a dead terminal that needs a manual refresh. No-op after a deliberate `stop()`
        /// or a real process `exited`; at most one restart in flight.
        @MainActor
        private func scheduleReconnect(_ reason: String) {
            guard !stopped, !sawExited, !paneGone, reconnectTask == nil else { return }
            reconnectAttempts += 1
            let capped = min(20.0, 0.5 * pow(2.0, Double(max(0, reconnectAttempts - 1))))  // 0.5,1,2,4,8,16,20
            let delay = capped * Double.random(in: 0.6...1.0)                               // full-ish jitter
            if let view {
                let notice = "\r\n\u{1b}[2m\(reason); reconnecting…\u{1b}[0m\r\n"
                view.feed(byteArray: [UInt8](notice.utf8)[...])
            }
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !self.stopped, !self.sawExited else { return }
                self.reconnectTask = nil
                self.start()   // re-open the stream (cancels any lingering task, re-arms the watchdog)
            }
        }

        @MainActor
        private func handle(_ event: TerminalStreamEvent) async {
            guard let view else { return }
            lastStreamActivity = Date()   // any event (data, ping, resize) means the stream is alive
            switch event {
            case .started(let started):
                // Align the emulator to the pane's real geometry the ack carries.
                resizeEmulator(cols: started.cols, rows: started.rows, in: view)
            case .frame(let frame):
                switch frame {
                case .reset(_, _, let cols, let rows, let data, _):
                    reconnectAttempts = 0   // a full keyframe = the stream genuinely (re)established
                    graphicsFilter.reset()  // fresh screen: abandon any graphics string split before this keyframe
                    let firstReset = !didSeedOnce
                    if firstReset {
                        didSeedOnce = true
                        // Raise SwiftTerm's scrollback ring ONCE (its ~500 default) so it can hold the
                        // full backfill plus the live tail — BEFORE the resize below so a resize can't
                        // reclamp the ring while history is being fed. Whether the raise then survives
                        // the LAYOUT-driven terminal.resize() (SwiftTerm's Buffer.resize must not
                        // recompute maxLength down from options.scrollback) is an SPM-dependency
                        // internal not visible here; the swipe-up XCUITest, which resizes to the real
                        // sim grid, is the actual proof that history survives.
                        view.getTerminal().changeHistorySize(Self.scrollbackCap)
                    }
                    // Size the grid to the reset's geometry FIRST (was previously between clear+seed),
                    // so nothing later in THIS reset can truncate freshly-fed history.
                    resizeEmulator(cols: cols, rows: rows, in: view)
                    if firstReset {
                        // History ABOVE the seed: feed it now so its lines scroll into SwiftTerm's
                        // scrollback; the ESC[2J below then erases only the overlapping VISIBLE rows
                        // (recent's bottom ≈ the current screen) in place — scrollback untouched — and
                        // the seed repaints them, so nothing is duplicated. Bounded (raced) await;
                        // re-check teardown before feeding a possibly-dismantled view. The trailing
                        // ESC[0m resets any SGR the history left active, so ESC[2J's background-colour
                        // erase can't tint the rows the seed does not repaint.
                        let history = await backfillTask?.value ?? nil
                        if let history, !history.isEmpty, !stopped {
                            let cleanHistory = graphicsFilter.filter(history[...])   // backfill can carry graphics too
                            if !cleanHistory.isEmpty { view.feed(byteArray: cleanHistory[...]) }
                            view.feed(byteArray: [UInt8]("\u{1b}[0m".utf8)[...])
                        }
                    }
                    // Clear the VISIBLE screen + home (NOT scrollback — see clearSequence, Fix B),
                    // then paint the full-screen seed. `lagged` resets seed identically (the server
                    // already collapsed the backlog into this keyframe).
                    view.feed(byteArray: Self.clearSequence[...])
                    if !data.isEmpty { feedFiltered(data, into: view) }
                case .data(_, _, let data):
                    if !data.isEmpty { feedFiltered(data, into: view) }
                case .resize(_, _, let cols, let rows):
                    resizeEmulator(cols: cols, rows: rows, in: view)
                case .ping:
                    break   // heartbeat only
                case .exited:
                    sawExited = true
                    view.feed(byteArray: Self.exitedNotice[...])
                    stop()
                }
            }
        }

        /// The user-facing notice for an error the server will keep giving, or nil when the
        /// failure is transient and the reconnect loop should run.
        ///
        /// Delegates the decision to `HerdrKit.permanentStreamRefusal` so the rule is unit
        /// tested away from the view. Kept as a thin seam here because `streamEnded` is
        /// `@MainActor` and view-bound.
        static func permanentRefusalNotice(_ error: Error?) -> String? {
            guard let apiError = error as? APIError else { return nil }
            return permanentStreamRefusal(code: apiError.code)
        }

        @MainActor
        private func streamEnded(_ error: Error?, run: Int) {
            // Only the CURRENT stream's end may reconnect. A superseded task (cancelled by a
            // watchdog/refresh restart, or replaced by a newer start()) ending here must be ignored,
            // or it double-reconnects and double-counts the backoff.
            guard run == streamRunID else { return }
            // An `exited` frame already painted the terminal's final state (the process ended, so
            // reconnecting would only re-show that). A deliberate stop() (back out / teardown) or a
            // torn-down view must not reconnect either.
            if sawExited { return }
            guard !stopped, view != nil else { return }
            // A PERMANENT server refusal is not a dropped connection. Reconnecting cannot
            // change the answer, so retrying only spins "reconnecting…" forever over a pane
            // that will never be served. Say so once and stop.
            if let notice = Self.permanentRefusalNotice(error) {
                paneGone = true
                if let view {
                    let line = "\r\n\u{1b}[2m\(notice)\u{1b}[0m\r\n"
                    view.feed(byteArray: [UInt8](line.utf8)[...])
                }
                return
            }
            // Otherwise the feed died while the process may still be live — auto-restart with backoff
            // rather than stranding a dead terminal behind a manual refresh.
            scheduleReconnect(error == nil ? "connection closed" : "connection lost")
        }

        // MARK: geometry

        /// Aligns the emulator grid to the server's authoritative PTY size so the
        /// byte stream lays out correctly. Does NOT call set_pty_size — driving the
        /// server is the VIEW's job (see `sizeChanged`), and echoing the server's
        /// own size back would be a needless round-trip.
        @MainActor
        private func resizeEmulator(cols: Int, rows: Int, in view: ReadOnlyTerminalView) {
            view.getTerminal().resize(cols: max(4, cols), rows: max(2, rows))
            // A server-driven resize reflows the emulator grid but — unlike a `.data` feed —
            // never triggers the view to repaint, so the next feed can paint new cells OVER stale
            // ones (the "overdraw" bug that previously only a manual refresh cleared). Force a
            // display-only full repaint at the new geometry. Purely display-side (see helper).
            forceFullRepaint(view)
        }

        /// Repaint the entire visible grid from the current buffer, without changing content or
        /// clearing. `updateFullScreen()` marks every row dirty (no content change); `setNeedsDisplay()`
        /// drives the iOS view's `draw(_:)` over the full bounds, which renders cells from the buffer
        /// via CoreText. Both are public SwiftTerm / UIKit APIs. DISPLAY-ONLY — never calls
        /// `set_pty_size` and never touches `desiredCols`/`lastSentCols`/`relockPending`, so the PTY
        /// width-lock is untouched.
        @MainActor
        private func forceFullRepaint(_ view: ReadOnlyTerminalView) {
            view.getTerminal().updateFullScreen()
            view.setNeedsDisplay()
        }

        /// The view laid out (first appearance, rotation, keyboard) and computed a
        /// new grid from its pixels + the mono cell metrics. Tell the server so the
        /// PTY — and therefore the stream — lays out at the phone's width. NOTE this
        /// resizes the SHARED PTY (see `sendPTYSize`): one winsize per pane, so a
        /// co-viewing desktop reflows to the phone's grid until it re-asserts.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Counted for the UI-test probe only: SwiftTerm's `processSizeChange` clears any
            // active selection on a rows/cols change, so a resize landing AFTER a word select
            // silently destroys it. The count lets a test say "the selection was wiped" rather
            // than "no selection appeared", which are different bugs with different fixes.
            resizeCount += 1
            sendPTYSize(cols: newCols, rows: newRows)
        }

        /// Main-thread only (called from the UIKit layout callback above). Records the
        /// desired PTY grid and ensures the drain converges to it.
        ///
        /// The model is `desired` vs `lastSent`: `sendPTYSize` records the newest
        /// target; a single serialized drain drives the server toward it and stops
        /// only when `lastSent == desired`. Because at most ONE `set_pty_size` is ever
        /// in flight (the drain awaits each before the next), two resizes can never
        /// complete server-side out of order. Dedup is measured against `desired` (the
        /// target we're driving toward), NOT `lastSent` — so a request that matches
        /// the committed size while a different resize is in flight still supersedes
        /// it. A failed target is retried by the drain itself (0.5s backoff, capped)
        /// so convergence never depends on a future layout callback. `lock:true`
        /// (Fix A) PINS the shared PTY to the phone's fit so the agent's TUI stops
        /// overflowing the screen width; `releaseGeometryOwnership` hands ownership
        /// back with a `lock:false` on teardown so the desktop reclaims its width.
        private func sendPTYSize(cols: Int, rows: Int) {
            guard !stopped else { return }   // teardown began — no new lock:true (review HIGH)
            guard cols >= 4, rows >= 2 else { return }
            // Redundant ONLY if we are already driving toward (or sitting at) this
            // exact size: same as the current target with a drain in flight, or same
            // as the confirmed size with no drain. A size we gave up on (target set
            // but never reached, no drain) is NOT redundant — it restarts the drain.
            if cols == desiredCols, rows == desiredRows,
               resizeTask != nil || (cols == lastSentCols && rows == lastSentRows) {
                return
            }
            desiredCols = cols
            desiredRows = rows
            resizeRetries = 0        // a new target gets a fresh retry budget
            // A backgrounded pane (or one whose re-lock is still awaiting the in-flight release,
            // `relockPending`) TRACKS the latest grid above but does not start a drain: a hidden
            // pane would re-pin a co-viewing desktop, and a `lock:true` sent during the release
            // window could race the `lock:false` and strand the visible pane unlocked. The
            // deferred re-lock re-sends at the LIVE grid once the release lands.
            guard foreground, !relockPending else { return }
            guard resizeTask == nil else { return }   // a drain is running; it re-reads `desired`
            let cell = cellPixels()
            resizeTask = Task { @MainActor [weak self] in
                // `self.foreground` in the condition: if this pane is backgrounded mid-drain (a
                // keep-mounted hide), STOP driving `lock:true` — a hidden pane must never re-pin a
                // co-viewing desktop. releaseGeometryOwnership awaits this task, so it then
                // proceeds to `lock:false`.
                while let self, !Task.isCancelled, self.foreground,
                      self.desiredCols != self.lastSentCols || self.desiredRows != self.lastSentRows {
                    let c = self.desiredCols        // always drive toward the LATEST target
                    let r = self.desiredRows
                    do {
                        // lock:true carries THIS view's viewerID + a lease TTL (#137): the
                        // daemon width-lease is keyed on the viewerID and refreshed by every
                        // such send (the heartbeat re-sends this same size under the TTL).
                        let applied = try await self.client.setPTYSize(
                            pane: self.paneID, cols: c, rows: r,
                            cellWidthPx: cell.width, cellHeightPx: cell.height, lock: true,
                            viewerID: self.viewerID, ttl: Self.leaseTTLMillis)
                        self.lastSentCols = c        // confirmed: OUR request is committed
                        self.lastSentRows = r
                        // The arbiter's EFFECTIVE size (a wider co-viewer can exceed our
                        // request). Recorded for truth but NOT written back into lastSent —
                        // converging the drain on it would re-send forever, fighting the arbiter.
                        self.appliedCols = applied.cols
                        self.appliedRows = applied.rows
                        self.resizeRetries = 0
                    } catch {
                        if Task.isCancelled { break }
                        // If `desired` still equals what we just tried, it is the same
                        // target failing: back off, capped, then give up (a later
                        // sendPTYSize restarts a fresh drain). If `desired` changed
                        // during the await, the loop simply converges to the new one
                        // with the fresh budget sendPTYSize already reset.
                        if self.desiredCols == c, self.desiredRows == r {
                            if self.resizeRetries >= 3 { break }
                            self.resizeRetries += 1
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                }
                // Clear our own handle on natural completion only. On cancellation
                // stop() already cleared it (and may have started a new drain), so do
                // not stomp that newer task.
                if !Task.isCancelled { self?.resizeTask = nil }
            }
        }

        /// Cell size from the actual mono font — the DPI hint the server stores.
        private func cellPixels() -> (width: UInt32, height: UInt32) {
            let attrs: [NSAttributedString.Key: Any] = [.font: paneFont]
            let advance = ("W" as NSString).size(withAttributes: attrs).width
            let lineHeight = paneFont.lineHeight
            return (UInt32(max(1, advance.rounded())), UInt32(max(1, lineHeight.rounded())))
        }

        // MARK: TerminalViewDelegate — terminal input

        /// Forward SwiftTerm's key→bytes translation to the PTY whenever direct input
        /// is enabled and the terminal owns focus. This includes iPhone software-keyboard
        /// input and iPad hardware-keyboard input. Serialized through `enqueueInput` so
        /// a fast key burst becomes ordered batches rather than concurrent channels.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // `foreground` is part of the guard, not just first-responder status. Panes stay
            // MOUNTED when another is fronted, and a pane that held a selection keeps its
            // responder for a moment, so first-responder alone would let a keystroke reach
            // an agent nobody is looking at.
            guard !stopped, foreground, let v = view, v.keyDriveEnabled, v.isFirstResponder else { return }
            enqueueInput(String(decoding: data, as: UTF8.self))
        }

        /// Serialized key-input queue, mirroring the scroll queue (`pendingScroll`/`scrollSendTask`):
        /// bytes waiting to go to the PTY, drained one send at a time so a fast burst coalesces into
        /// batched writes. Nonisolated like `emitScroll` (called on the main thread from the
        /// delegate callback); the drain hops to the main actor for the async `sendText`.
        private var pendingInput = ""
        private var inputSendTask: Task<Void, Never>?
        /// Persistent input channel (issue #62): opened lazily on first key-drive
        /// input, after which keystrokes ride one held SSH channel instead of a
        /// fresh `send_text` exec per batch. nil = not yet tried, or the daemon
        /// lacks the method / the channel died = `send_text` fallback.
        private var inputChannel: PaneInputChannel?
        private var inputChannelTried = false
        private func enqueueInput(_ s: String) {
            guard !s.isEmpty else { return }
            pendingInput += s
            guard inputSendTask == nil else { return }   // a drain is running; it will pick this up
            inputSendTask = Task { @MainActor [weak self] in
                while let self, !self.stopped, !self.pendingInput.isEmpty {
                    let batch = self.pendingInput
                    self.pendingInput = ""
                    await self.deliverInput(batch)
                }
                self?.inputSendTask = nil
            }
        }

        /// Delivers one input batch, preferring the persistent `pane.input.stream`
        /// channel and falling back to per-call `sendText`. Order is preserved: the
        /// single `inputSendTask` drain calls this serially, and the channel writes
        /// frames through one ordered writer.
        @MainActor
        private func deliverInput(_ batch: String) async {
            // A federated (remote) pane can't host the persistent pane.input.stream duplex
            // channel — the home daemon can't proxy it (channelSetupRejected) — so skip the
            // channel entirely and route every batch through the federation-routable
            // pane.send_text (#84). Order is still preserved: the single inputSendTask drain
            // calls deliverInput serially. (#139)
            if isFederated {
                _ = try? await self.client.sendText(pane: self.paneID, text: batch)
                return
            }
            // Open the channel lazily on first use. An older daemon without
            // pane.input.stream makes start() throw, and we stay on send_text.
            if !inputChannelTried {
                inputChannelTried = true
                if let channel = await client.openPaneInput(pane: paneID) {
                    do {
                        try await channel.start()
                        inputChannel = channel
                    } catch {
                        await channel.close()
                        inputChannel = nil
                    }
                }
            }
            if let channel = inputChannel, await channel.send(batch) {
                return
            }
            // Channel unavailable or died mid-session: drop it and fall back. A
            // dropped channel is NOT re-opened here (no replay) — a fresh
            // Coordinator on reconnect retries the open.
            if let channel = inputChannel {
                await channel.close()
                inputChannel = nil
            }
            _ = try? await self.client.sendText(pane: self.paneID, text: batch)
        }
        /// SwiftTerm reports a 0...1 scroll position (`TerminalViewDelegate.scrolled`).
        /// A pane whose content fits the viewport can never be scrolled away from the
        /// tail, so treat it as parked; otherwise it is at the tail only at the bottom.
        func scrolled(source: TerminalView, position: Double) {
            guard let view else { return }
            let canScroll = view.contentSize.height > view.bounds.height + 1
            reportTailState(atTail: !canScroll || position >= 0.999)
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        /// Required on the pinned SwiftTerm (v1.11.2 has no default impl for it; a
        /// later version added one). No-op: the read-only terminal never copies.
        func clipboardCopy(source: TerminalView, content: Data) {}

        // MARK: alt-screen scroll — drag to scroll the AGENT's own view

        /// Accumulated vertical drag since the last emitted scroll tick.
        private var scrollAccum: CGFloat = 0
        /// The alt-screen scroll pan recognizer, disabled on teardown so a drag can't
        /// send bytes to a pane that has exited/been replaced.
        private var scrollPan: UIPanGestureRecognizer?
        /// UI-TEST ONLY diagnostic element (see `publishSelectionProbe`). Nil in every build
        /// that does not launch with `HERDR_SCREENSHOT_MOCK`, so a shipped app neither
        /// allocates it nor exposes it to the accessibility layer.
        private var selectionProbe: UIView?
        /// How many times SwiftTerm has reported a grid change. Published by the probe because
        /// `processSizeChange` clears the selection on any rows/cols change, so a resize
        /// arriving late is one of the candidate explanations for a selection that vanishes —
        /// and a count is how a test tells that apart from a selection never made.
        private var resizeCount = 0
        /// Serialized scroll-send queue: bytes waiting to go to the agent, drained one
        /// send at a time by `scrollSendTask` — so a fast drag coalesces into batched
        /// writes instead of a flood of concurrent, possibly-reordered SSH channels.
        private var pendingScroll = ""
        private var scrollSendTask: Task<Void, Never>?

        /// A drag on the terminal while a full-screen or MOUSE-REPORTING agent owns the
        /// view. Two cases we handle by sending scroll INPUT to the agent (SGR
        /// mouse-wheel when it reports mouse — Claude Code enables DECSET 1000/1006 —
        /// else Up/Down arrows):
        ///  • ALTERNATE screen (vim/htop-style TUIs): no SwiftTerm scrollback to scroll.
        ///  • MOUSE MODE on a normal buffer (Claude Code "fullscreen" captures the wheel
        ///    to scroll its OWN viewport): a native scrollback scroll would move the
        ///    wrong thing / nothing.
        /// A PLAIN shell (omp: normal buffer, mouse OFF) is left to SwiftTerm's native
        /// scrollback pan (fixed in 1.15.0) — we return early. This is the ONLY byte
        /// path this read-only view opens and it emits ONLY wheel/arrow sequences —
        /// never a keystroke — so the keyboard stays fully blocked.
        @objc private func handleScrollPan(_ gr: UIPanGestureRecognizer) {
            // Restore native scroll on gesture-end FIRST — before ANY early return,
            // including the teardown guard below. Two ways the state can change under an
            // active drag: (1) the agent flips buffer/mouse mode, and (2) the agent EXITS
            // — stop() runs from handle(.exited) while the pane STAYS on screen. Either
            // must not strand isScrollEnabled=false on a live, still-visible pane
            // (reviewer). `view?` keeps this safe during teardown; only undoes a flag a
            // .began below set (idempotent otherwise).
            if gr.state == .ended || gr.state == .cancelled || gr.state == .failed {
                view?.isScrollEnabled = true
            }
            // `foreground` is defence in depth for the same reason as the two-finger tap:
            // this path SENDS BYTES, and it should not rely on the keep-alive container
            // continuing to make backgrounded panes non-hit-testable. Placed AFTER the
            // isScrollEnabled restore above, so a pane backgrounded mid-drag still gets its
            // native scroll back rather than being stranded disabled.
            guard !stopped, foreground, let view else { return }   // teardown or hidden: send nothing
            let term = view.getTerminal()
            // omp (normal buffer + mouse off) scrolls natively; everything else we drive.
            guard term.isCurrentBufferAlternate || term.mouseMode != .off else { return }
            switch gr.state {
            case .began:
                scrollAccum = 0
                // A mouse-mode program on a NORMAL buffer still has retained scrollback;
                // suppress the native scrollback pan for this drag so it can't
                // double-scroll against the wheel we send. Moot on the alt screen (no
                // scrollback); never reached for omp (returned above).
                if term.mouseMode != .off && !term.isCurrentBufferAlternate {
                    view.isScrollEnabled = false
                }
            case .changed:
                scrollAccum += gr.translation(in: view).y
                gr.setTranslation(.zero, in: view)
                let line = max(1, paneFont.lineHeight)
                let ticks = Int(scrollAccum / line)
                guard ticks != 0 else { return }
                // Pace the wheel: a MOUSE-MODE agent (Claude Code) accelerates its own
                // scroll from the GAP between wheel events, so several events slammed into
                // one send arrive ~simultaneously and trip its fast cap (~36 lines/tick) —
                // the jumpy leaps. Emit ONE tick per frame there so the gaps land in its
                // gentle ~3-line regime → smooth, finger-proportional (its own accel still
                // supplies fling speed). The ARROW-key fallback (rare non-mouse alt-screen)
                // doesn't accelerate, so keep up to 4/frame. CONSUME ONLY the ticks we
                // emit and CARRY the rest in scrollAccum, so a fast drag isn't truncated.
                let cap = term.mouseMode != .off ? 1 : 4
                let count = min(abs(ticks), cap)
                scrollAccum -= CGFloat((ticks > 0 ? 1 : -1) * count) * line
                // Bound the carry to ONE frame's worth: keeps the decelerating-drag
                // benefit but stops scrollAccum growing unbounded when demand outruns the
                // cap — otherwise a direction REVERSAL within one touch keeps firing the
                // old direction for many frames (scrolls backwards), and in mouse mode the
                // backlog × Claude Code's own acceleration would over-scroll (reviewer).
                let maxCarry = CGFloat(cap) * line
                scrollAccum = min(max(scrollAccum, -maxCarry), maxCarry)
                emitScroll(up: ticks > 0, count: count,
                           at: gr.location(in: view), term: term)
            default:
                break
            }
        }

        /// Emit `count` scroll ticks toward the agent. Drag DOWN (`up == true`)
        /// reveals OLDER content → wheel-up (button 64); drag UP → wheel-down (65).
        /// SGR mouse-wheel is pure ASCII, safe through the String `send_text` path;
        /// with no mouse reporting, fall back to arrow keys (best-effort).
        private func emitScroll(up: Bool, count: Int, at point: CGPoint, term: SwiftTerm.Terminal) {
            guard count > 0 else { return }
            let seq: String
            if term.mouseMode != .off {
                // NOTE: SwiftTerm 1.11.2 keeps the mouse ENCODING (mouseProtocol)
                // private, so we can't read whether the app negotiated SGR (DECSET
                // 1006) vs legacy X10. We emit SGR — what Claude Code and effectively
                // every modern mouse-reporting TUI uses (X10's 223-cell limit is why
                // apps opt into 1006). An X10-only-mouse app (rare, legacy) would not
                // understand these; a documented limit of the private protocol, not a
                // runtime bug.
                let code = up ? 64 : 65
                let cw = ("W" as NSString).size(withAttributes: [.font: paneFont]).width
                let ch = paneFont.lineHeight
                let col = max(1, min(Int(point.x / max(1, cw)) + 1, max(1, term.cols)))
                let row = max(1, min(Int(point.y / max(1, ch)) + 1, max(1, term.rows)))
                seq = String(repeating: "\u{1b}[<\(code);\(col);\(row)M", count: count)
            } else {
                seq = String(repeating: up ? "\u{1b}[A" : "\u{1b}[B", count: count)
            }
            // Serialize: queue the bytes and drain ONE send at a time (coalescing all
            // pending into each batch), so a fast drag can't spawn a flood of
            // concurrent SSH channels that deliver direction changes out of order.
            // Bound the queue: if the sole send stalls under a long drag, don't
            // accumulate an unbounded burst — it could exceed CitadelTransport's
            // ~120KB argument limit (dropped) or replay a huge stale scroll when the
            // link resumes. ~4KB is far more scroll than any real drag needs; past
            // that we drop further ticks (a stalled link can't scroll smoothly anyway).
            guard pendingScroll.utf8.count + seq.utf8.count <= 4096 else { return }
            pendingScroll += seq
            guard scrollSendTask == nil else { return }   // a drain is running; it will pick this up
            scrollSendTask = Task { @MainActor [weak self] in
                while let self, !self.stopped, !self.pendingScroll.isEmpty {
                    let batch = self.pendingScroll
                    self.pendingScroll = ""
                    _ = try? await self.client.sendText(pane: self.paneID, text: batch)
                }
                self?.scrollSendTask = nil
            }
        }

        /// Coexist with the TerminalView's own scroll-view pan: on the alt screen the
        /// native pan has no range, so recognizing both simultaneously is harmless and
        /// lets our handler drive the agent scroll.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// The agent-scroll pan must not BEGIN when it has nothing to do, or when it
        /// would fight a selection. On a plain shell pane `handleScrollPan` returns early
        /// anyway; while a selection is active the drag belongs to SwiftTerm's lazily
        /// installed drag-to-extend pan, which has no delegate of its own and so cannot
        /// defend itself. Only this recognizer is gated, so the taps always begin.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === scrollPan else { return true }
            guard let view, !view.hasActiveSelection else { return false }
            let term = view.getTerminal()
            return term.isCurrentBufferAlternate || term.mouseMode != .off
        }

        // MARK: palette helpers

        /// Clear the VISIBLE screen + cursor home, fed before a reset seed. NOTE we
        /// deliberately do NOT feed `ESC[3J` (clear SCROLLBACK) here (Fix B): wiping
        /// scrollback on every reset is what left the normal-buffer (shell) history
        /// un-scrollable — "it looks stuck". Dropping it lets that history accumulate
        /// in SwiftTerm so a drag-up actually reveals earlier output. (Alt-screen TUIs
        /// keep no scrollback of their own regardless; scrolling THOSE is handled by
        /// `handleScrollPan`, which sends wheel/arrow scroll INTO the agent.)
        private static let clearSequence = [UInt8]("\u{1b}[2J\u{1b}[H".utf8)
        /// The dim terminated marker shown when the process exits.
        private static let exitedNotice = [UInt8]("\r\n\u{1b}[2mprocess exited\u{1b}[0m\r\n".utf8)

        private static func color(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        }

        /// A SwiftTerm palette entry from 8-bit hex (SwiftTerm uses 16-bit channels;
        /// 0xFF -> 0xFFFF via *257).
        private static func ansi(_ hex: UInt32) -> SwiftTerm.Color {
            SwiftTerm.Color(
                red: UInt16((hex >> 16) & 0xFF) * 257,
                green: UInt16((hex >> 8) & 0xFF) * 257,
                blue: UInt16(hex & 0xFF) * 257)
        }

        /// 16 ANSI colours (normal 0–7, bright 8–15). Status hues match the design:
        /// red = died, green = done, yellow = waiting, blue = working.
        static let ansiPalette: [SwiftTerm.Color] = [
            ansi(0x1A1D2E), ansi(0xE2584E), ansi(0x5FB37F), ansi(0xE9A63C),
            ansi(0x5B9BE8), ansi(0xB58BF0), ansi(0x4FB8C8), ansi(0xC7CBD9),
            ansi(0x3A3F5C), ansi(0xF07A70), ansi(0x7FC89A), ansi(0xF2BE63),
            ansi(0x82B6F0), ansi(0xC9A9F5), ansi(0x74CEDC), ansi(0xEEF0F7),
        ]
    }
}
#endif
