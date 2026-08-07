#if canImport(UIKit)
import SwiftUI
import UIKit
import SwiftTerm
import HerdrKit

/// A read-only, LIVE SwiftTerm terminal for a herdr pane (#40). It consumes
/// `client.streamTerminal(pane:)` — herdr's raw PTY byte firehose — and feeds the
/// bytes to a real VT emulator, so the phone renders a grid-faithful terminal
/// instead of a reflowed snapshot.
///
/// READ-ONLY for keyboard/typed input: the view never becomes first responder (no
/// keyboard) and its delegate `send` is a no-op, so SwiftTerm keystrokes are never
/// routed to the PTY. Command/message input stays exclusively on the reply/Send +
/// keycap affordances in `TerminalPaneView` (`sendText`/`sendKeys`/`prompt`). The
/// ONE narrow input exception is SCROLL: a pan on the alternate screen sends
/// constrained wheel/arrow sequences to the agent so its full-screen view can scroll
/// (see `handleScrollPan`) — never a keystroke, never arbitrary typed text.
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

    func makeCoordinator() -> Coordinator { Coordinator(client: client, paneID: paneID) }

    func makeUIView(context: Context) -> ReadOnlyTerminalView {
        let view = ReadOnlyTerminalView(frame: .zero, font: Coordinator.paneFont)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: ReadOnlyTerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: ReadOnlyTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// A `TerminalView` that never accepts keyboard input — display + scroll only.
    /// Blocking first-responder status is what keeps this observe-only: no keyboard
    /// appears and no keystroke can reach the (unwired) PTY input path.
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
        override var canBecomeFirstResponder: Bool { false }
        override func becomeFirstResponder() -> Bool { false }

        override init(frame: CGRect, font: UIFont?) {
            super.init(frame: frame, font: font)
            // Inset-free, matching SwiftTerm's own iOS example host: keeps the grid
            // flush and the library's scroll-offset math (`maxContentOffsetY`) free of a
            // shifting safe-area / keyboard inset.
            contentInsetAdjustmentBehavior = .never
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    /// Owns the stream task and marshals frames onto the main actor. Retained by
    /// SwiftUI (via `makeCoordinator`); the `TerminalView` holds only a weak ref
    /// back through `terminalDelegate`.
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        private let client: HerdrClient
        private let paneID: String
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

        /// IBM Plex Mono (the design's MACHINE voice) at the pane size, falling back
        /// to the system monospace if the bundled face is unavailable. The
        /// PostScript name matches `DesignSystem.Typography`'s mono regular cut.
        static let paneFontSize: CGFloat = 12.5
        static let paneFont: UIFont =
            UIFont(name: "IBMPlexMono", size: paneFontSize)
            ?? UIFont.monospacedSystemFont(ofSize: paneFontSize, weight: .regular)

        init(client: HerdrClient, paneID: String) {
            self.client = client
            self.paneID = paneID
        }

        func attach(_ view: ReadOnlyTerminalView) {
            self.view = view
            view.terminalDelegate = self
            // We are READ-ONLY and drive scroll ourselves (handleScrollPan → SGR wheel).
            // Turn OFF SwiftTerm's own gesture→mouse-event generation: when an agent
            // enables mouse reporting (Claude Code does), SwiftTerm otherwise adds a
            // panMouseHandler that turns a drag into button press/drag/release events
            // and COMPETES with / starves our scroll-wheel pan — so the finger-drag
            // does nothing. Disabling it makes SwiftTerm emit FEWER upstream events
            // (never more — read-only intact); `term.mouseMode` (what emitScroll reads)
            // is the terminal's own state and is UNAFFECTED, so we still send wheel.
            view.allowMouseReporting = false
            // A dedicated pan that scrolls the AGENT (see handleScrollPan) — for the
            // alt screen OR any mouse-reporting program. Simultaneous with the view's
            // own scroll-view pan (which handles a plain shell's native scrollback).
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
            scrollPan = pan
            style(view)
            start()
        }

        func stop() {
            stopped = true                  // no new resize/scroll may start after this
            view?.terminalDelegate = nil    // stop further SwiftTerm callbacks (sizeChanged)
            scrollPan?.isEnabled = false    // no drag can send bytes to an exited/replaced pane
            scrollSendTask?.cancel()
            scrollSendTask = nil
            streamTask?.cancel()
            streamTask = nil
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
            guard cols >= 4, rows >= 2 else { return }
            let client = self.client
            let pane = self.paneID
            Task.detached {
                _ = await inflight?.value    // let the in-flight lock:true finish its round-trip
                _ = try? await client.setPTYSize(pane: pane, cols: cols, rows: rows, lock: false)
            }
        }

        // MARK: styling (the design's machine voice)

        private func style(_ view: ReadOnlyTerminalView) {
            view.font = Self.paneFont
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

        private func start() {
            streamTask?.cancel()
            sawExited = false
            streamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await event in self.client.streamTerminal(pane: self.paneID) {
                        if Task.isCancelled { return }
                        await self.handle(event)
                    }
                    await self.streamEnded(nil)
                } catch {
                    await self.streamEnded(error)
                }
            }
        }

        @MainActor
        private func handle(_ event: TerminalStreamEvent) {
            guard let view else { return }
            switch event {
            case .started(let started):
                // Align the emulator to the pane's real geometry the ack carries.
                resizeEmulator(cols: started.cols, rows: started.rows, in: view)
            case .frame(let frame):
                switch frame {
                case .reset(_, _, let cols, let rows, let data, _):
                    // Clear the VISIBLE screen + home (NOT scrollback — see
                    // clearSequence, Fix B), then paint the full-screen seed.
                    // `lagged` resets seed identically (the server already collapsed
                    // the backlog into this keyframe).
                    view.feed(byteArray: Self.clearSequence[...])
                    resizeEmulator(cols: cols, rows: rows, in: view)
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
        private func streamEnded(_ error: Error?) {
            guard let view else { return }
            // An `exited` frame already painted the terminal's final state — nothing
            // to add. ANY other end (a thrown error, OR a clean EOF with no `exited`)
            // means the feed died while the process may still be live: surface it so a
            // frozen last frame is not mistaken for a live terminal.
            if sawExited { return }
            let reason = error.map { "unavailable: \($0)" } ?? "connection closed"
            let notice = "\r\n\u{1b}[2m— live terminal \(reason); reopen to reconnect —\u{1b}[0m\r\n"
            view.feed(byteArray: [UInt8](notice.utf8)[...])
        }

        // MARK: geometry

        /// Aligns the emulator grid to the server's authoritative PTY size so the
        /// byte stream lays out correctly. Does NOT call set_pty_size — driving the
        /// server is the VIEW's job (see `sizeChanged`), and echoing the server's
        /// own size back would be a needless round-trip.
        @MainActor
        private func resizeEmulator(cols: Int, rows: Int, in view: ReadOnlyTerminalView) {
            view.getTerminal().resize(cols: max(4, cols), rows: max(2, rows))
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
            guard resizeTask == nil else { return }   // a drain is running; it re-reads `desired`
            let cell = Self.cellPixels()
            resizeTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled,
                      self.desiredCols != self.lastSentCols || self.desiredRows != self.lastSentRows {
                    let c = self.desiredCols        // always drive toward the LATEST target
                    let r = self.desiredRows
                    do {
                        _ = try await self.client.setPTYSize(
                            pane: self.paneID, cols: c, rows: r,
                            cellWidthPx: cell.width, cellHeightPx: cell.height, lock: true)
                        self.lastSentCols = c        // confirmed
                        self.lastSentRows = r
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
        private static func cellPixels() -> (width: UInt32, height: UInt32) {
            let attrs: [NSAttributedString.Key: Any] = [.font: paneFont]
            let advance = ("W" as NSString).size(withAttributes: attrs).width
            let lineHeight = paneFont.lineHeight
            return (UInt32(max(1, advance.rounded())), UInt32(max(1, lineHeight.rounded())))
        }

        // MARK: TerminalViewDelegate — read-only, so most are inert

        /// READ-ONLY: swallow any bytes SwiftTerm would send upstream (keystrokes,
        /// mouse events it generates). Keyboard/typed input is never routed to the
        /// PTY through this delegate. (The one deliberate write from this view is the
        /// alt-screen SCROLL path in `handleScrollPan`, which sends only wheel/arrow
        /// sequences directly via `sendText` — not through this no-op.)
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
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
            guard !stopped, let view else { return }   // teardown began — send nothing
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
                let line = max(1, Self.paneFont.lineHeight)
                let ticks = Int(scrollAccum / line)
                guard ticks != 0 else { return }
                scrollAccum -= CGFloat(ticks) * line
                emitScroll(up: ticks > 0, count: min(abs(ticks), 4),
                           at: gr.location(in: view), term: term)
            case .ended, .cancelled, .failed:
                view.isScrollEnabled = true   // restore native scroll (no-op unless we disabled it)
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
                let cw = ("W" as NSString).size(withAttributes: [.font: Self.paneFont]).width
                let ch = Self.paneFont.lineHeight
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
