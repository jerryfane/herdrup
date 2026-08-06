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
/// READ-ONLY on purpose: #40 is render + resize only; raw-bytes-to-PTY INPUT is a
/// separate follow-up. The view never becomes first responder (no keyboard) and
/// its delegate `send` is a no-op, so SwiftTerm keystrokes are never routed to the
/// PTY. Input stays exclusively on the reply/Send + keycap affordances in
/// `TerminalPaneView`, which use the existing `sendText`/`sendKeys`/`prompt` paths.
///
/// Geometry: the view reports its own laid-out grid to the server via `setPTYSize`
/// so the stream is generated at the phone's width. This resizes the SHARED PTY
/// (one winsize per pane), so a co-viewing desktop reflows to the phone's grid until
/// it re-asserts — we pass `lock:false` so we never PIN that shrink, but we do cause
/// it transiently. Rendering the agent's real TUI at the phone's width is the point.
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
    final class ReadOnlyTerminalView: TerminalView {
        override var canBecomeFirstResponder: Bool { false }
        override func becomeFirstResponder() -> Bool { false }
    }

    /// Owns the stream task and marshals frames onto the main actor. Retained by
    /// SwiftUI (via `makeCoordinator`); the `TerminalView` holds only a weak ref
    /// back through `terminalDelegate`.
    final class Coordinator: NSObject, TerminalViewDelegate {
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
            style(view)
            start()
        }

        func stop() {
            streamTask?.cancel()
            streamTask = nil
            resizeTask?.cancel()
            resizeTask = nil
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
                    // Clear screen + scrollback + home, then paint the full-screen
                    // seed. `lagged` resets seed identically (the server already
                    // collapsed the backlog into this keyframe).
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
        /// so convergence never depends on a future layout callback. `lock:false`
        /// still resizes the shared PTY (herdr resizes then releases ownership); we
        /// accept the transient co-viewer reflow but never pin it.
        private func sendPTYSize(cols: Int, rows: Int) {
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
                            cellWidthPx: cell.width, cellHeightPx: cell.height, lock: false)
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

        /// READ-ONLY: swallow any bytes SwiftTerm would send upstream. #40 does not
        /// wire input; the PTY is never written from here.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        /// Required on the pinned SwiftTerm (v1.11.2 has no default impl for it; a
        /// later version added one). No-op: the read-only terminal never copies.
        func clipboardCopy(source: TerminalView, content: Data) {}

        // MARK: palette helpers

        /// Clear screen + clear scrollback + cursor home, fed before a reset seed.
        private static let clearSequence = [UInt8]("\u{1b}[2J\u{1b}[3J\u{1b}[H".utf8)
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
