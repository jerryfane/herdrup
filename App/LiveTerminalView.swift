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

/// A read-only, LIVE SwiftTerm terminal for a herdr pane (#40). It consumes
/// `client.streamTerminal(pane:)` — herdr's raw PTY byte firehose — and feeds the
/// bytes to a real VT emulator, so the phone renders a grid-faithful terminal
/// instead of a reflowed snapshot.
///
/// READ-ONLY for keyboard/typed input on iPhone/touch: the view never becomes first
/// responder (no keyboard) and its delegate `send` early-returns, so SwiftTerm keystrokes
/// are never routed to the PTY. Command/message input stays on the reply/Send + keycap
/// affordances in `TerminalPaneContent` (`sendText`/`sendKeys`/`prompt`). Two input
/// exceptions: (1) SCROLL — a pan on the alternate screen sends constrained wheel/arrow
/// sequences to the agent so its full-screen view can scroll (see `handleScrollPan`) —
/// never a keystroke; and (2) iPad KEY DRIVE — on iPad with a hardware keyboard the view
/// becomes first responder and `send` forwards SwiftTerm's key→bytes to the PTY, so a Magic
/// Keyboard types straight into the terminal (see `ReadOnlyTerminalView.keyDriveEnabled`).
/// iPhone and touch behaviour are unchanged.
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
    /// Only ever true on iPad with a hardware keyboard AND when the reply field is not focused;
    /// on iPhone the terminal cannot become first responder, so this is inert (see
    /// `ReadOnlyTerminalView.keyDriveEnabled`). Refreshed on every update.
    var wantsTerminalKeyFocus: Bool = false
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
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: ReadOnlyTerminalView, context: Context) {
        context.coordinator.onNavigate = onNavigate
        context.coordinator.isFederated = isFederated
        context.coordinator.setForeground(isForeground)
        // Drive terminal KEY focus from SwiftUI intent (iPad key-drive only). The resign is
        // gated on keyDriveEnabled so it manages ONLY key-drive focus: on iPhone/touch the view
        // may hold first-responder status transiently for a TEXT SELECTION, and we must not yank
        // it out from under an active selection on the next SwiftUI update.
        if wantsTerminalKeyFocus {
            if !uiView.isFirstResponder { _ = uiView.becomeFirstResponder() }
        } else if uiView.keyDriveEnabled, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        context.coordinator.applyFont(size: fontSize)
    }

    static func dismantleUIView(_ uiView: ReadOnlyTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// A `TerminalView` that is read-only for keyboard input on iPhone/touch — display +
    /// scroll only. Blocking first-responder status is what keeps it observe-only: no keyboard
    /// appears and no keystroke can reach the PTY input path. The ONE exception is iPad with a
    /// hardware keyboard (`keyDriveEnabled`): there the view DOES become first responder and its
    /// `send` delegate forwards SwiftTerm's key→bytes translation to the PTY, so a Magic Keyboard
    /// drives the terminal like a real one. iPhone and touch behaviour are unchanged.
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
        /// KEY DRIVE (hardware keys → PTY) is allowed only on iPad with a PHYSICAL keyboard:
        /// the `.pad` idiom (NOT horizontalSizeClass — an iPhone Max in landscape is regular
        /// width and must stay read-only) AND a coalesced hardware keyboard. This gates the
        /// `send` delegate, so keystrokes reach the PTY ONLY under key drive — independently of
        /// first-responder status below.
        var keyDriveEnabled: Bool {
            UIDevice.current.userInterfaceIdiom == .pad && GCKeyboard.coalesced != nil
        }
        /// First responder is allowed on EVERY platform, because SwiftTerm's text selection
        /// (long-press word-select, drag-to-extend, the Copy callout) requires it. This does NOT
        /// make the pane writable: keystroke routing stays gated on `keyDriveEnabled` in the
        /// `send` delegate, and the zero-frame `emptyInputView` below means no soft keyboard ever
        /// appears. Net effect on iPhone: the terminal can be selected and copied, never typed into.
        override var canBecomeFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { super.becomeFirstResponder() }
        /// Zero-frame input view so becoming first responder shows NO soft keyboard — hardware
        /// keys still arrive via UIKeyInput/pressesBegan. SwiftTerm declares `inputView` and
        /// `inputAccessoryView` as `public override` (NOT `open`), so this module cannot re-override
        /// them; we SET them in init instead (they expose public setters).
        private let emptyInputView = UIView(frame: .zero)

        override init(frame: CGRect, font: UIFont?) {
            super.init(frame: frame, font: font)
            // Inset-free, matching SwiftTerm's own iOS example host: keeps the grid
            // flush and the library's scroll-offset math (`maxContentOffsetY`) free of a
            // shifting safe-area / keyboard inset.
            contentInsetAdjustmentBehavior = .never
            // Suppress the soft keyboard + SwiftTerm's TerminalAccessory bar while keeping HARDWARE
            // keys flowing. `setupAccessoryView()` (which installs the accessory) runs once during
            // super.init's setup, so overwriting these here sticks.
            inputView = emptyInputView
            inputAccessoryView = nil
        }
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
            // Double-tap → jump to the live tail. A UIKit recognizer (NOT a SwiftUI
            // .onTapGesture, which starves the scroll pan — HerdrApp.swift note).
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            view.addGestureRecognizer(doubleTap)
            // SUPERSEDE SwiftTerm's own double-tap (word-select): make it wait for ours to
            // FAIL, so a double-tap jumps to the tail without starting a word selection and
            // its lingering selection pan (which would otherwise fight the next scroll on an
            // idle shell pane — SwiftTerm's doubleTap has no read-only guard).
            for gr in view.gestureRecognizers ?? [] where gr !== doubleTap {
                if let t = gr as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 {
                    t.require(toFail: doubleTap)
                }
            }
            // (Removed: the horizontal swipe-between-agents recognizers. A finger/mouse drag to
            // SELECT text was triggering them and paging to an unwanted agent; agent switching
            // stays fully reachable via the list/sidebar, and their removal frees horizontal drag
            // for SwiftTerm's drag-to-extend selection. `onNavigate` is left wired but unused.)
            style(view)
            startBackfill()   // fetch history CONCURRENTLY with the stream; the first reset awaits it
            start()
        }

        /// Double-tap the terminal → jump to the live tail. A mouse-mode/alt agent
        /// (Claude Code) captures the wheel and keeps its own viewport, so send it
        /// Ctrl+End (`ESC[1;5F` → scroll-to-bottom + re-enable auto-follow) — read-only,
        /// exactly like the scroll bytes, never a keystroke. A plain shell has native
        /// SwiftTerm scrollback, so jump its UIScrollView to the maximum offset.
        @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard !stopped, let view else { return }
            if view.getTerminal().isCurrentBufferAlternate || view.getTerminal().mouseMode != .off {
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    _ = try? await self.client.sendText(pane: self.paneID, text: "\u{1b}[1;5F")
                }
            } else {
                // animated:false — an animated jump is cancelled mid-flight on a streaming
                // pane (SwiftTerm's updateScroller writes the offset back and leaves
                // userScrolling stuck true). A direct set runs contentOffset's didSet →
                // syncYDispFromContentOffset synchronously and re-engages auto-follow.
                let maxY = max(0, view.contentSize.height - view.bounds.height)
                view.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
            }
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
                    guard let self, !self.stopped, !self.sawExited else { return }
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
            guard !stopped, !sawExited, reconnectTask == nil else { return }
            reconnectAttempts += 1
            let capped = min(20.0, 0.5 * pow(2.0, Double(max(0, reconnectAttempts - 1))))  // 0.5,1,2,4,8,16,20
            let delay = capped * Double.random(in: 0.6...1.0)                               // full-ish jitter
            if let view {
                let notice = "\r\n\u{1b}[2m— \(reason); reconnecting…\u{1b}[0m\r\n"
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
                            view.feed(byteArray: history[...])
                            view.feed(byteArray: [UInt8]("\u{1b}[0m".utf8)[...])
                        }
                    }
                    // Clear the VISIBLE screen + home (NOT scrollback — see clearSequence, Fix B),
                    // then paint the full-screen seed. `lagged` resets seed identically (the server
                    // already collapsed the backlog into this keyframe).
                    view.feed(byteArray: Self.clearSequence[...])
                    if !data.isEmpty { view.feed(byteArray: [UInt8](data)[...]) }
                case .data(_, _, let data):
                    if !data.isEmpty { view.feed(byteArray: [UInt8](data)[...]) }
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

        // MARK: TerminalViewDelegate — read-only, so most are inert

        /// KEY DRIVE (iPad + hardware keyboard only): forward SwiftTerm's own key→bytes
        /// translation to the PTY. DOUBLE-GATED — the view must be `keyDriveEnabled` AND the
        /// current first responder — so on iPhone/touch (where the view never becomes first
        /// responder) this stays a no-op and no keystroke or SwiftTerm-generated mouse byte is
        /// ever routed to the PTY, exactly as before. Serialized through `enqueueInput` for the
        /// same reason `emitScroll` serializes: batch a fast key burst into one send instead of a
        /// flood of concurrent, possibly-reordered SSH channels. (The alt-screen SCROLL path in
        /// `handleScrollPan` still writes wheel/arrow sequences directly via `sendText`.)
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard !stopped, let v = view, v.keyDriveEnabled, v.isFirstResponder else { return }
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
        func scrolled(source: TerminalView, position: Double) {}
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
            guard !stopped, let view else { return }   // teardown began — send nothing further
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
        private static let exitedNotice = [UInt8]("\r\n\u{1b}[2m— process exited —\u{1b}[0m\r\n".utf8)

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
