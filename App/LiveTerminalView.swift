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

private struct TerminalGeometryTarget: Equatable {
    let cols: Int
    let rows: Int
    let cellWidthPx: UInt32
    let cellHeightPx: UInt32
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
/// while the app views the pane.
///
/// The lock is handed back on TEARDOWN ONLY — one `lock:false` from `stop()` (see
/// `releaseGeometryOwnership`), i.e. on close or LRU eviction. Merely HIDING a
/// keep-mounted pane keeps the lease and simply stops refreshing it, so it lapses on the
/// daemon's 5-minute TTL and the desktop reclaims the width once nobody has looked at the
/// pane for that long. Releasing on every hide was the original design and it made every
/// switch between two loaded panes cost two winsize changes — one when the TUI reclaimed
/// its layout width, one when re-fronting re-pinned ours — and therefore two full agent
/// repaints, which read as the terminal rescrolling on every agent switch.
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
    /// Bumped by the reply bar's chevron to request a DELIBERATE collapse, as opposed to the many
    /// incidental body passes that also see `wantsTerminalKeyFocus == false`. Only a deliberate
    /// collapse may resign the responder while a selection is held: see the resign branch in
    /// `updateUIView`, both for what went wrong when the two were indistinguishable and for why
    /// this is a monotonic token rather than a bool the host resets.
    var collapseToken: Int = 0
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
    /// Shared with the host so it can ask whether this pane's stream is alive before
    /// deciding to remount on foreground. Written by the Coordinator, read by the host.
    var liveness: StreamLiveness? = nil
    /// The host's one-shot Ctrl toggle, shared so a Ctrl tap applies to whichever
    /// input path is active: the reply field (`handleReplyChange`) or, now, direct
    /// typing into the terminal, where SwiftTerm's own `controlModifier` does the
    /// encoding and reports back when it was consumed.
    @Binding var controlArmed: Bool
    /// The host's own copy of the stuck-stream threshold, so it judges staleness by the
    /// same rule the watchdog reconnects on rather than a second, drifting number.
    static var streamStuckTimeout: TimeInterval { Coordinator.streamStuckTimeout }

    func makeCoordinator() -> Coordinator { Coordinator(client: client, paneID: paneID) }

    func makeUIView(context: Context) -> TerminalSurfaceView {
        context.coordinator.paneFontSize =
            min(max(fontSize, Coordinator.minFontSize), Coordinator.maxFontSize)
        let view = ReadOnlyTerminalView(frame: .zero, font: context.coordinator.paneFont)
        let surface = TerminalSurfaceView(terminal: view)
        context.coordinator.onNavigate = onNavigate
        context.coordinator.isFederated = isFederated
        context.coordinator.onTerminalFocusRequest = onTerminalFocusRequest
        // BEFORE attach, which starts the stream: the first frame must be recorded, or a
        // pane that connects while the app is backgrounding looks stale on return.
        context.coordinator.liveness = liveness
        // SEED both baselines from the host before the first `updateUIView`. A remount
        // (the header refresh bumps `streamGen`) builds a fresh Coordinator while the
        // host's `@State` survives, so defaulting them replays the last jump as a second
        // Ctrl+End and mis-dedupes the tail callback.
        context.coordinator.seedBaselines(jumpToTailToken: jumpToTailToken, atTail: isAtTail)
        context.coordinator.attach(surface)
        return surface
    }

    func updateUIView(_ uiView: TerminalSurfaceView, context: Context) {
        let terminalView = uiView.terminal
        context.coordinator.onNavigate = onNavigate
        context.coordinator.isFederated = isFederated
        context.coordinator.onTerminalFocusRequest = onTerminalFocusRequest
        // Live accessors, refreshed every pass: a captured Bool would be a snapshot of
        // the state as it was when this body ran, which is exactly the race that makes
        // an immediate keypress after a Ctrl tap miss the modifier.
        context.coordinator.controlArmedGetter = { controlArmed }
        context.coordinator.controlArmedSetter = { controlArmed = $0 }
        // A remount builds a fresh Coordinator while the host's box survives, so re-point
        // it every pass rather than only at mount.
        context.coordinator.liveness = liveness
        context.coordinator.onTailStateChange = onTailStateChange
        // setForeground BEFORE performJumpToTail, deliberately. The jump sends bytes and is
        // now foreground-guarded, and a guard that reads a flag this pass has not yet
        // written is not a guard at all.
        context.coordinator.setForeground(isForeground)
        context.coordinator.directFocusIntended = wantsTerminalKeyFocus
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
            if !terminalView.isFirstResponder { _ = terminalView.becomeFirstResponder() }
        } else {
            if !isForeground { terminalView.clearSelection() }
            // THE SELECTION GUARD MUST NOT OUTRANK AN EXPLICIT COLLAPSE, and it did.
            //
            // `!uiView.hasActiveSelection` exists so an incidental SwiftUI body pass cannot yank
            // the responder mid-selection and take the Copy menu with it. But the collapse chevron
            // reaches this same else-branch by clearing both focus flags, and while a word was
            // selected the guard refused the resign — so the keyboard stayed up, and because
            // clearing the flags also hides the chevron, its only dismiss affordance vanished with
            // it. The reader was left with a keyboard over 40% of the pane and no way down.
            // Measured and reported by review; the chevron was the feature added to fix exactly
            // this class of problem, so it failing in the PR's own headline flow is the worst place
            // for it.
            //
            // `collapseToken` distinguishes the two cases: an incidental pass still respects the
            // selection, while a deliberate collapse resigns regardless and keeps the selection
            // intact in the model. Resigning hides the system Copy menu, which is the honest
            // consequence of asking for the keyboard to go away — and the selection is still
            // there, so a double tap re-presents it without re-selecting. Review endorsed that
            // behaviour choice; what it rejected was my first MECHANISM for it.
            //
            // A MONOTONIC TOKEN, NOT A BOOL SET-AND-ASYNC-RESET, and this is the second defect
            // review found in this one gate. My first fix set a `collapseRequested` flag and
            // cleared it in `DispatchQueue.main.async`, intending "true for exactly the next body
            // pass". That does not hold: the GCD main-queue drain runs BEFORE SwiftUI's deferred
            // update flush, so this method would have observed the flag already false, refused the
            // resign, and reproduced the very defect it was written to fix — an INERT fix that
            // would have tested green as an unchanged bug.
            //
            // A token cannot be coalesced away. It carries no lifetime and no assumption about
            // which pass reads it: whichever pass observes a value the Coordinator has not
            // consumed is the collapse, and every later pass sees a consumed one. This is the
            // pattern `performJumpToTail(ifTokenChanged:)` already uses two dozen lines up, so
            // it is also the pattern this file had already settled on for exactly this problem.
            //
            // Consumed HERE rather than beside `performJumpToTail`, so a pass that re-requests
            // focus cannot silently eat a collapse it was never going to act on.
            let deliberateCollapse = context.coordinator.consumeCollapse(ifTokenChanged: collapseToken)
            if terminalView.isFirstResponder, !isForeground || deliberateCollapse || !terminalView.hasActiveSelection {
                terminalView.resignFirstResponder()
                // Losing the keyboard is an explicit dismissal: an armed one-shot must not
                // survive to modify whatever is typed next, in this pane or another.
                context.coordinator.cancelArmedControl()
                // A DEBUG-only probe so a UI test can observe WHICH branch resigned. Without
                // this call `fr` would only ever be sampled at gesture time and the collapse would
                // stay unobservable — which is precisely how the inert first mechanism escaped.
                // Compiled out in Release and inert without the mock env var.
                context.coordinator.publishSelectionProbe(deliberateCollapse ? "collapseResign" : "passResign")
            }
        }
        context.coordinator.applyFont(size: fontSize)
        // After the focus decision above, so the native modifier matches the input path
        // that is actually live.
        context.coordinator.applyControlModifier()
    }

    static func dismantleUIView(_ uiView: TerminalSurfaceView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Holds the terminal and, during a resize, the retained frame that covers it.
    ///
    /// The terminal object, its first responder, its gestures, its delegate and its
    /// stream are the SAME objects across every resize: only this container's bounds
    /// change. The cover is a sibling view, so it can never be mistaken for terminal
    /// content, and the capture happens HERE - before the terminal's frame is
    /// assigned - because after that assignment the old rendering is already gone.
    final class TerminalSurfaceView: UIView {
        let terminal: ReadOnlyTerminalView
        /// Where the retained frame is pinned while the geometry changes. A tail
        /// follower reads the newest line at the bottom; a history reader reads from
        /// the top. Nothing is ever scaled: text does not stretch.
        enum CoverAnchor { case topLeft, bottomLeft }

        /// Called immediately before the terminal's frame changes, so the owner can
        /// retain the current frame. Returns nothing: covering is the owner's choice.
        var onGeometryWillChange: (() -> Void)?

        private var cover: UIView?
        private var coverContent: UIView?
        private var coverAnchor: CoverAnchor = .bottomLeft

        var isCovered: Bool { cover != nil }

        init(terminal: ReadOnlyTerminalView) {
            self.terminal = terminal
            super.init(frame: .zero)
            clipsToBounds = true
            backgroundColor = terminal.nativeBackgroundColor
            addSubview(terminal)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if terminal.frame != bounds {
                onGeometryWillChange?()
                terminal.frame = bounds
            }
            layoutCover()
        }

        /// Snapshot of the terminal exactly as it is on screen right now, or nil when
        /// UIKit has nothing to hand back (no first paint yet).
        func captureTerminalFrame() -> UIView? {
            guard terminal.bounds.width > 0, terminal.bounds.height > 0 else { return nil }
            return terminal.snapshotView(afterScreenUpdates: false)
        }

        func installCover(_ content: UIView, anchor: CoverAnchor) {
            removeCover()
            let container = UIView(frame: bounds)
            container.clipsToBounds = true
            container.backgroundColor = terminal.nativeBackgroundColor
            container.isUserInteractionEnabled = false
            container.isAccessibilityElement = false
            container.accessibilityElementsHidden = true
            content.isUserInteractionEnabled = false
            container.addSubview(content)
            addSubview(container)
            cover = container
            coverContent = content
            coverAnchor = anchor
            layoutCover()
        }

        func removeCover() {
            cover?.removeFromSuperview()
            cover = nil
            coverContent = nil
        }

        private func layoutCover() {
            guard let cover, let content = coverContent else { return }
            cover.frame = bounds
            let size = content.bounds.size
            switch coverAnchor {
            case .topLeft:
                content.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            case .bottomLeft:
                content.frame = CGRect(x: 0, y: bounds.height - size.height,
                                       width: size.width, height: size.height)
            }
        }
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

        // MARK: - one-shot Ctrl for direct typing

        /// Called immediately before UIKit-inserted text reaches SwiftTerm's encoder,
        /// with the text and whether the insertion is an IME composition commit. The
        /// Coordinator decides whether the armed modifier applies to it.
        var onWillInsertText: ((String, Bool) -> Void)?
        /// Called when the user does something that is definitely not a Ctrl chord.
        var onCancelControl: (() -> Void)?
        var onUserInteraction: (() -> Void)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if event?.type == .touches { onUserInteraction?() }
            return super.hitTest(point, with: event)
        }

        /// Refreshing the native modifier HERE, not on a SwiftUI pass, is what makes
        /// "tap Ctrl, immediately type p" work: SwiftUI may not have delivered the
        /// binding change yet when the key arrives. Encoding itself stays SwiftTerm's
        /// job (legacy control bytes or negotiated Kitty CSI-u), so the pane receives
        /// exactly one properly encoded chord.
        override func insertText(_ text: String) {
            onWillInsertText?(text, markedTextRange != nil)
            super.insertText(text)
        }

        /// A paste is not a chord: it must arrive verbatim, and it must not leave the
        /// modifier armed for the next keystroke.
        override func paste(_ sender: Any?) {
            onCancelControl?()
            super.paste(sender)
        }

        override func deleteBackward() {
            onCancelControl?()
            super.deleteBackward()
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
        /// The container that owns the terminal and the resize cover. Same object for
        /// this coordinator's whole life; the terminal is never rebuilt for a resize.
        private weak var surface: TerminalSurfaceView?
        private var streamTask: Task<Void, Never>?
        /// The single serialized resize drain, if running. Only ever ONE at a time —
        /// it awaits each set_pty_size before the next (so remote resizes can't
        /// complete out of order) and loops until `desired == lastSent`. Cancelled on
        /// teardown.
        private var resizeTask: Task<Void, Never>?
        /// The grid this view WANTS the PTY at, together with the cell metrics that
        /// produced it, so a font change at an unchanged grid is still a new target.
        /// The drain drives `confirmedTarget` toward this. Dedup is measured against
        /// THIS, never the committed size, so a request matching the committed size
        /// while a DIFFERENT resize is in flight is not wrongly dropped.
        private var desiredTarget: TerminalGeometryTarget?
        /// When `desiredTarget` last CHANGED. The drain waits for a real quiet window
        /// measured from here (monotonic), instead of comparing two endpoint samples -
        /// a sweep that returns to an earlier width is movement, not stillness.
        private var desiredTargetChangedAt: ContinuousClock.Instant?
        /// Bumped on every new target, so a response can be told apart from the one
        /// belonging to a target the user has already superseded.
        private var targetGeneration = 0
        /// The target of the `set_pty_size` call currently in flight, if any.
        private var inflightTarget: TerminalGeometryTarget?
        /// Last target the server CONFIRMED (committed only after a successful
        /// set_pty_size). The drain stops once this equals `desiredTarget`.
        private var confirmedTarget: TerminalGeometryTarget?
        /// The EFFECTIVE winsize the daemon actually applied, from the `set_pty_size`
        /// response (#137), plus the target generation it answered. Under the
        /// width-lease arbiter this can EXCEED what this view requested — a wider
        /// co-viewer's lease wins — so it is recorded for truth but deliberately NOT
        /// fed back into `confirmedTarget`: driving the drain toward the arbiter's
        /// width would re-send forever, fighting the arbiter. The view still RENDERS
        /// the applied (wider) grid because the authoritative cols/rows arrive on
        /// `pane.stream` itself; this is the coordinator's copy of that truth.
        private var responseGeometry: (cols: Int, rows: Int)?
        private var responseGeneration = -1
        /// The grid the STREAM has actually applied to the emulator, in stream order.
        /// This - not a response, and never a local target - is what is on screen.
        private var streamAppliedGeometry: (cols: Int, rows: Int)?
        /// Bumped whenever the stream commits geometry, so a completed paint can be
        /// matched to the grid it was painted at.
        private var streamGeometryRevision = 0
        /// A lease keepalive in flight. It is NOT a target change: the drain waits for
        /// it so the two never overlap on the wire.
        private var keepaliveTask: Task<Void, Never>?
        /// Consecutive failures for the CURRENT target, so the drain's self-retry
        /// backs off and is capped; reset whenever a new target is requested.
        private var resizeRetries = 0
        /// How long a resize target must stand still before it is sent to the daemon.
        ///
        /// Long enough to swallow an animated or dragged width sweep (one proposal
        /// per frame), short enough that a deliberate single resize still feels
        /// immediate — and short enough not to hold up teardown, which awaits this task.
        static let resizeSettleDuration: Duration = .milliseconds(140)
        /// How long the presentation waits for new output to stop before it treats the
        /// current frame as the finished one (used only when the agent does not mark
        /// its frames with DEC 2026).
        static let presentationQuietDuration: Duration = .milliseconds(250)
        /// Hard ceiling on holding a retained frame: after this the reader sees the
        /// real, authoritative grid whatever the agent did or did not redraw.
        static let presentationDeadlineDuration: Duration = .seconds(1)

        // MARK: - resize presentation
        //
        // A resize is not one event: the local fit is proposed, the daemon commits a
        // grid, the stream carries that grid in order with the output it applies to,
        // and only then does the agent redraw. Showing every intermediate state means
        // showing text reflowing through sizes nobody asked for, so the last complete
        // frame is retained over the terminal until the new one is genuinely ready.

        /// Why the geometry is changing, which decides what "settled" means.
        private enum PresentationReason { case local, server }

        /// A completed paint, tagged with everything that must still hold for it to
        /// count as the finished frame for the current burst.
        private struct DrawToken: Equatable {
            var presentationGeneration: Int
            var targetGeneration: Int
            var streamGeometryRevision: Int
            var cellSize: CGSize
            var alternate: Bool
        }

        private var presentationGeneration = 0
        private var presentationActive = false
        /// Set when this burst is finished with: no late acknowledgment, marker or
        /// gesture may cover the same geometry again.
        private var presentationClosed = false
        private var presentationReason: PresentationReason = .local
        private var presentationStartedOnNormalBuffer = true
        private var presentationSyncEnded = false
        private var presentationGeometrySettled = false
        private var presentationDeadlineTask: Task<Void, Never>?
        private var presentationRevealTask: Task<Void, Never>?
        private var pendingSafeRepaint = false
        private var lastCompleteDraw: DrawToken?
        private var backingDrawComplete = false
        private var lastStreamDataAt: ContinuousClock.Instant?
        private var geometryEligibleAt: ContinuousClock.Instant?
        private var presentationDeadlineReached = false
        private var synchronizedBatchBegan = false
        /// While a burst is on screen the host keeps the tail state it had, so a
        /// transient UIKit clamp or a borrowed alternate screen is not published as if
        /// the reader had decided something.
        private var tailPublishHeld = false

        // MARK: - one-shot Ctrl

        /// Live accessors for the host's `ctrlArmed` state, refreshed every SwiftUI
        /// pass so an immediate keystroke cannot read a stale snapshot.
        var controlArmedGetter: (() -> Bool)?
        var controlArmedSetter: ((Bool) -> Void)?
        /// True while THIS code is writing `controlModifier`, so SwiftTerm's reset
        /// notification for our own write is not mistaken for the user's chord being
        /// consumed (which would clear a modifier the reply field still needs).
        private var applyingControlModifier = false
        private var controlResetObserver: NSObjectProtocol?
        var directFocusIntended = false
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
        /// defeat the release. Once stopped, `requestGeometry` is inert.
        private var stopped = false

        /// KVO token for the terminal's `contentOffset`, which is the only signal a FINGER scroll
        /// produces that this layer can see. Retained because an `NSKeyValueObservation` stops
        /// observing the moment it is released; invalidated in `stop()`.
        private var offsetObservation: NSKeyValueObservation?

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
        /// The host's liveness box, mirrored on every stream frame. Optional because the
        /// header-refresh path and the tests construct a Coordinator with no host box.
        var liveness: StreamLiveness?
        /// No stream event (data, ping, resize) for this long → treat the stream as stuck and
        /// reconnect. 2.5× the server's 20s ping, so a single dropped ping is tolerated.
        fileprivate static let streamStuckTimeout: TimeInterval = 50

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
        /// `lock:true`, and target dedup then never re-locks it. Accessed only on the
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
        /// lock. During this window EVERY geometry request must NOT
        /// start a drain, or a `lock:true` could race the still-in-flight `lock:false` on a
        /// separate SSH channel and leave the VISIBLE pane unlocked. The deferred re-lock clears
        /// it and then drives toward the LIVE grid.
        private var relockPending = false
        /// The generation whose lock has already been handed back (a `lock:false` release). A
        /// generation is released AT MOST ONCE. `releaseGeometryOwnership` now runs from `stop()`
        /// ONLY — a hide keeps the lease — but `stop()` itself can run twice (`.exited` then
        /// dismantle) without bumping the generation, so the idempotence is still required.
        /// Without it a second same-generation release would fire a redundant `lock:false`
        /// (re-resizing the shared PTY) AND let the first release's generation-keyed self-prune
        /// clobber the newer release's registry handle.
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
        /// `applyFont` flows through SwiftTerm's resetFont → sizeChangeRequestHandler
        /// → requestGeometry, which re-locks the PTY at the new grid and cell metrics.
        var paneFontSize: CGFloat = 12.5
        var paneFont: UIFont {
            UIFont(name: "IBMPlexMono", size: paneFontSize)
                ?? UIFont.monospacedSystemFont(ofSize: paneFontSize, weight: .regular)
        }

        /// Apply a new terminal font size (clamped to [minFontSize, maxFontSize]).
        /// A no-op if unchanged; otherwise setting `view.font` recomputes the cell
        /// metrics and PROPOSES a grid (`sizeChangeRequestHandler`), which this
        /// coordinator turns into a `set_pty_size`. The emulator is not resized here:
        /// the authoritative grid still arrives in band, so the reader sees the old
        /// frame until the new one is ready rather than text reflowing under them.
        func applyFont(size: CGFloat) {
            let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
            guard clamped != paneFontSize else { return }
            paneFontSize = clamped
            beginResizePresentation(reason: .local)
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

        func attach(_ surface: TerminalSurfaceView) {
            let view = surface.terminal
            self.view = view
            self.surface = surface
            view.terminalDelegate = self
            #if DEBUG
            MainActor.assumeIsolated {
                TerminalInteractionHarness.register(paneID: paneID, view: view,
                    requestFit: { [weak self] cols, rows in self?.requestGeometry(cols: cols, rows: rows) },
                    isCovered: { [weak surface] in surface?.isCovered ?? false },
                    isForeground: { [weak self] in self?.foreground ?? false })
            }
            #endif
            // THIS coordinator owns the grid: SwiftTerm must propose, never commit.
            // Installed BEFORE the stream starts, so the very first layout pass cannot
            // reflow the emulator to a locally guessed size ahead of the daemon's.
            view.sizeChangeRequestHandler = { [weak self] cols, rows in
                self?.requestGeometry(cols: cols, rows: rows)
            }
            view.synchronizedOutputChangeHandler = { [weak self] active in
                self?.noteSynchronizedOutput(active: active)
            }
            view.displayCompletedHandler = { [weak self] complete in
                self?.noteDisplayCompleted(complete: complete)
                #if DEBUG
                if let self, let view = self.view {
                    MainActor.assumeIsolated {
                        TerminalInteractionHarness.painted(paneID: self.paneID, view: view,
                                                           cellSize: view.cellSize, complete: complete)
                    }
                }
                #endif
            }
            // The container tells us a frame change is imminent, while the current
            // rendering is still on screen and can be retained.
            surface.onGeometryWillChange = { [weak self] in
                self?.beginResizePresentation(reason: .local)
            }
            view.onWillInsertText = { [weak self] text, composing in
                self?.prepareForInsertedText(text, composing: composing)
            }
            view.onCancelControl = { [weak self] in
                self?.cancelArmedControl()
                self?.userTookControl()
            }
            view.onUserInteraction = { [weak self] in self?.userTookControl() }
            // SwiftTerm posts this when it CONSUMES the one-shot control modifier while
            // encoding a key. `object: view` and no queue: the clear must land on this
            // main-thread turn, before the next key is encoded.
            controlResetObserver = NotificationCenter.default.addObserver(
                forName: .terminalViewControlModifierReset, object: view, queue: nil) { [weak self] _ in
                    guard let self, !self.stopped, !self.applyingControlModifier else { return }
                    self.controlArmedSetter?(false)
                }
            // Turn the VIEW's touch→mouse-byte conversion OFF unconditionally. Two reasons:
            // (1) under key drive a tap SwiftTerm turned into a mouse report could leak bytes to
            // the PTY (`send` FORWARDS output there); (2) in the read-only case it lets a tap or
            // long-press start a LOCAL text selection instead of being swallowed as a mouse event
            // over a mouse-mode TUI. This touches ONLY the view's tap-to-mouse conversion — NOT
            // the emulator's `term.mouseMode` (what emitScroll/handleScrollPan read), so alt-screen
            // / Claude-Code wheel scroll is unaffected.
            view.allowMouseReporting = false
            // Track hardware-keyboard connect/disconnect so key-drive focus follows the keyboard.
            // On connect the front pane becomes first responder (gated by keyDriveEnabled);
            // on disconnect it resigns. Tokens removed in stop().
            keyboardObservers.append(
                NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self, weak view] _ in
                    // NOT iPAD-ONLY ANY MORE. This comment used to say the keyDriveEnabled gate
                    // "keeps this iPad-only (a BT keyboard on iPhone is a no-op, preserving the
                    // read-only path)". That described the world before this PR: keyDriveEnabled
                    // now includes .phone, so a Bluetooth keyboard connecting to an iPHONE also
                    // makes the terminal first responder and drives the PTY. That follows from
                    // iPhone typing being the feature, so it is intended — but it is UNVERIFIED,
                    // since nothing here has been exercised with a BT keyboard on a phone, and a
                    // comment claiming the old behaviour would have hidden that. Caught by review.
                    //
                    // A keyboard attached MID-session also needs mouse reporting off, or a tap
                    // could leak a mouse report through the now-live send.
                    guard let self, let view, self.foreground, view.keyDriveEnabled else { return }
                    view.allowMouseReporting = false
                    _ = view.becomeFirstResponder()
                })
            keyboardObservers.append(
                NotificationCenter.default.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self, weak view] _ in
                    self?.cancelArmedControl()
                    view?.resignFirstResponder()
                })
            keyboardObservers.append(
                NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
                    self?.cancelArmedControl()
                    self?.finishPresentation()
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
                if let target = self.desiredTarget, target.cols >= 4, target.rows >= 2 {
                    self.startGeometryDrain()
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
                    clearTapRequirementCount += 1
                }
            }
            view.addGestureRecognizer(clearTap)
            // (Removed: the horizontal swipe-between-agents recognizers. A finger/mouse drag to
            // SELECT text was triggering them and paging to an unwanted agent; agent switching
            // stays fully reachable via the list/sidebar, and their removal frees horizontal drag
            // for SwiftTerm's drag-to-extend selection. `onNavigate` is left wired but unused.)
            style(view)
            // The finger-scroll half of the Latest pill's tail state. Wired here, after the
            // gestures, so it is live for the reader's very first drag — the pill's primary case.
            observeContentOffset(view)
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
            // The reader asked for the newest output: whatever a resize was about to
            // reveal must not put them back where they were.
            userTookControl()
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
                // SwiftTerm's own explicit scroll: it clears the manual-scrolling state
                // (so auto-follow re-engages), reconciles the offset even when the row is
                // unchanged, and drops the logical resize anchor. Writing contentOffset
                // directly used to be necessary; it no longer is, and it left the library
                // guessing whether the offset came from a gesture.
                view.scrollTo(row: Int.max)
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

        /// The last collapse token this Coordinator has acted on. Starts at 0, matching the
        /// host's initial `collapseToken`, so a freshly created pane does not read its own
        /// initial state as a pending collapse request.
        private var lastCollapseToken = 0

        /// True for exactly ONE `updateUIView` pass per chevron tap — the pass that observes a
        /// token the Coordinator has not consumed yet.
        ///
        /// Same shape as `performJumpToTail(ifTokenChanged:)` above and for the same reason: a
        /// SwiftUI input cannot express "for the next pass only" as a bool the host resets,
        /// because the host does not control when passes happen and any async reset races the
        /// pass it was meant for. A monotonic counter needs no such timing assumption.
        func consumeCollapse(ifTokenChanged token: Int) -> Bool {
            guard token != lastCollapseToken else { return false }
            lastCollapseToken = token
            return true
        }

        /// Publishes tail state to the host, and ONLY on a change, so scrolling cannot
        /// re-render SwiftUI on every frame.
        ///
        /// The publish is deferred one main-queue turn on purpose. `performJumpToTail`
        /// runs INSIDE `updateUIView`, and the jump reports `atTail: true`, so a
        /// synchronous call would mutate SwiftUI `@State` during a view update, which
        /// SwiftUI warns about and can re-enter. The dedupe above stays synchronous, so
        /// deferring cannot publish a stale duplicate.
        /// THE SINGLE PUBLISHER of tail state, and the single place the alternate screen is
        /// judged — deliberately here rather than in each caller.
        ///
        /// Review found the alt-screen early return I had added to `scrolled(source:position:)`
        /// was missing from `observeContentOffset`'s KVO hop, so a finger drag on an oversized
        /// alt-screen grid could still publish `atTail: false` and fight the delegate path into
        /// pill flicker. The narrow fix was to copy the guard into the KVO hop. That is a SITE
        /// fix for what is plainly a CLASS defect: two publishers, one of them guarded, and
        /// nothing stopping a third from being added unguarded.
        ///
        /// So the guard lives in the funnel every publisher already goes through, and each
        /// caller now reports what it actually observed. A future publisher inherits the
        /// alt-screen rule by construction instead of by whoever adds it remembering.
        ///
        /// WHY THE ALT SCREEN IS FORCED TO at-tail rather than left alone: a TUI pane keeps its
        /// own viewport and is served by jumpToTail's Ctrl+End path, not by this pill, so the
        /// honest report is "nothing to return to". `isCurrentBufferAlternate` is a synchronous
        /// buffer-IDENTITY check, not a heuristic, so it cannot transiently lie on a normal
        /// buffer — verified in the pinned SwiftTerm 1.15.0 by review.
        private func reportTailState(atTail: Bool) {
            // While a retained frame is on screen the reader has decided nothing: the
            // clamps UIKit performs mid-resize, and a temporarily borrowed alternate
            // screen, are not user intent. The actual state is published on reveal.
            guard !tailPublishHeld else { return }
            var atTail = atTail
            if view?.getTerminal().isCurrentBufferAlternate == true { atTail = true }
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
            // A TAP THAT STOPS A SCROLL IS NOT A REQUEST FOR THE KEYBOARD, and treating it as one
            // is a defect the owner hit on a real iPhone: scrolling back through output would
            // "randomly" raise the keyboard, which relayouts the terminal band, resizes the PTY and
            // forces a re-render — losing the reader's place in the output they were reading.
            //
            // WHY IT FIRES AT ALL. `focusTap` is a 1-tap recognizer with NO `require(toFail:)` —
            // deliberately, because the responder must exist by tap 1 for SwiftTerm's double-tap
            // Copy menu to work — and it is attached to `TerminalView`, which IS a `UIScrollView`,
            // with `cancelsTouchesInView = false`. The universal iOS idiom for arresting momentum
            // scrolling is a single tap, so that tap lands on the terminal and the recognizer
            // cannot tell it apart from a deliberate tap on the text.
            //
            // THE FIRST VERSION OF THIS GUARD WAS INERT, and the way that was caught is worth
            // keeping. It tested `view.isDragging || view.isDecelerating` HERE, at `.ended` —
            // i.e. touch-UP. But a scroll-arresting touch cancels deceleration at touch-DOWN, so
            // both flags are already false by the time this runs and the guard never fired. The
            // evidence was in front of me and I misread it: the regression test reached the guard
            // 0 times in 6 attempts with ~1s deceleration windows, which I wrote off as unlucky
            // timing. Review read the same 0/6 as what it was — a measurement of inertness. An
            // empty result is a claim about the instrument, not about the world.
            //
            // SO THE SIGNAL IS "DID THE CONTENT JUST MOVE UNDER A FINGER", sampled from the KVO
            // observer on `contentOffset` that already drives the Latest pill. That observer
            // records a timestamp only for offset writes made while the scroll view reports
            // `isDragging || isDecelerating` — see the note there.
            //
            // THAT QUALIFIER IS THE SECOND CORRECTION, and it came from review as well. Recording
            // every offset change was worse than the bug: SwiftTerm's auto-follow writes
            // `contentOffset` on every output frame, so on a BUSY pane the timestamp was
            // permanently fresh and this guard suppressed every tap — the reader could not focus
            // the terminal at all while an agent was producing output. The flags were never the
            // wrong signal; reading them at tap `.ended` was the wrong PLACE. Inside the observer
            // they are true for exactly the writes a finger caused.
            //
            // Nothing here depends on recognizer ordering or on when UIScrollView clears its
            // state, which is what made the first version unprovable without a device.
            //
            // A tap that stops momentum arrives while the offset was changing microseconds ago, so
            // it is suppressed. A tap on a settled pane — or on a pane that is merely following
            // output — sees motion far in the past, so it focuses normally. The window is
            // deliberately short: long enough to cover the gap between the last offset change and
            // touch-up, short enough that a deliberate tap a moment after reading never waits.
            let sinceMotion = CACurrentMediaTime() - lastContentMotion
            if sinceMotion < Self.scrollSettleWindow {
                publishSelectionProbe("scrollTapIgnored")
                return
            }
            onTerminalFocusRequest?()
            // Publishes because this recognizer has NO failure requirement, so it fires on tap 1
            // of ANY tap that actually lands on the terminal. That makes it the discriminator for
            // a tap that appears to do nothing: if the probe's publisher changes to focusTap, the
            // touch reached the view and the fault is downstream in clearTap's require-to-fail
            // chain; if it does not change at all, the tap missed the terminal entirely.
            //
            // The scroll-ignored path publishes its OWN publisher name so a test can tell "the tap
            // was suppressed because the pane was scrolling" from "the tap never arrived", which
            // are otherwise identical: both leave focus untaken and the label unchanged.
            //
            // NAMED `scrollTapIgnored` AND NOT `focusTapScrollIgnored` deliberately: probe
            // assertions are substring matches, and TerminalSelectionTests already asserts
            // `contains("pub=focusTap")`. Any name with `focusTap` as a PREFIX would satisfy that
            // assertion from the suppressed path and silently weaken it — the same prefix trap that
            // made `pub=clearTap` match `pub=clearTapEntry` and greened a vacuous receipt.
            publishSelectionProbe("focusTap")
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
            // PUBLISHES AT ENTRY, before any guard, because the previous round could not tell
            // "this handler never ran" from "it ran and bailed". CI reported pub=focusTap with the
            // selection still active, which proved the touch reached the terminal and that clearTap
            // produced nothing — but not which of those two it was. An entry publish separates
            // them: pub=clearTapEntry means the recognizer fired and something below refused,
            // pub=focusTap still means the recognizer itself never recognized.
            publishSelectionProbe("clearTapEntry(state=\(gr.state.rawValue) requires=\(clearTapRequirementCount))")
            guard !stopped, foreground, gr.state == .ended, let view else { return }
            guard view.hasActiveSelection else { return }
            view.clearSelection()
            // So a test can distinguish "the clear reached the view" from "the highlight
            // happened to stop being drawn". No-op outside UI-test builds.
            publishSelectionProbe("clearTap")
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
                self.publishSelectionProbe("menuTap")   // records state even when the guards below refuse
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
        /// DEBUG BUILDS ONLY, AND THE PREVIOUS VERSION OF THIS PARAGRAPH WAS FALSE. It claimed the
        /// label "carries the SELECTED LENGTH, never the selected text" while the code fourteen
        /// lines below published the text, and the paragraph fourteen lines below said so — the
        /// same comment contradicted itself, and the wrong half was the safety claim. A review
        /// caught it.
        ///
        /// The runtime env check was also the ONLY gate. `MockTransport` and `ScreenshotMock` live
        /// inside `#if DEBUG`, but this file had no `#if DEBUG` anywhere, so the probe compiled
        /// into Release and a Release build launched with `HERDR_SCREENSHOT_MOCK` set would route
        /// to a REAL pane while the probe attached to the view tree and published that pane's
        /// selected text to the accessibility layer. Now compiled out entirely, so the env var is
        /// defence in depth rather than the whole defence.
        ///
        /// What it publishes: sel, len, the selected TEXT, rows, cols, ydisp and a resize count.
        /// The text is deliberate and is what made the row-space defect findable; it is safe only
        /// because this cannot exist outside a DEBUG build fed by the canned mock transport.
        fileprivate func publishSelectionProbe(_ publisher: String) {
            #if DEBUG
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
            // :2535) — an earlier version called `.getSelectedText()` on it, which is the
            // SelectionService method and does not exist here.
            //
            // THE TEXT ITSELF IS PUBLISHED, and it is the measurement that matters. Every
            // hypothesis for "SwiftTerm holds a selection and nothing is painted" has now been
            // eliminated by READING: the rows resolve to the same buffer-absolute space
            // (contentOffset.y == yDisp * cellHeight), the paint loop does consume
            // `.selectionBackgroundColor`, and `selectionChanged` does call `setNeedsDisplay`
            // on both the Metal and CoreGraphics paths. So one of those readings is wrong, and
            // the one runtime fact no public API exposes is WHICH LINE the selection landed on.
            //
            // The fixture answers it: the mock seeds uniquely numbered lines
            // ("SCROLLTEST line 007  the quick brown fox…") and `selectWordOrExpression`
            // treats digits as a selectable word, so a tap aimed at the number yields the line
            // number as the selected text. If the test taps a line the view is showing and the
            // probe reports a number from far outside the visible window, the tap's row space
            // is wrong; if it reports a visible number, the row space is fine and the defect is
            // in the drawing after all. Either answer kills a hypothesis rather than adding one.
            //
            // Safe to publish: this text is synthetic fixture content in a UI-test-only build,
            // never a real pane's output.
            let active = view.hasActiveSelection
            let selected = view.getSelection() ?? ""
            let term = view.getTerminal()
            // yDisp IS THE LAST DISCRIMINATOR, and it is public (`Terminal.buffer` is
            // `public private(set)`, `Buffer.yDisp` is `public`), so no internals are needed.
            //
            // The run at 001a092a reported a real three-character selection of "187" with ZERO
            // painted pixels, deterministically in both passes. The fixture numbers its lines, so
            // that text identifies the selection's line: "187" is 1-indexed, hence buffer row 186.
            // Publishing yDisp lets the test decide, arithmetically rather than by inference,
            // between the only two remaining explanations:
            //   186 inside [yDisp, yDisp + rows - 1]  => the selection sits on a row being drawn,
            //                                            so the PAINT is broken;
            //   186 outside that window               => the selection sits on a row nobody draws,
            //                                            so the tap's ROW SPACE is wrong after all.
            // Both were reached by reading and neither survived; this settles it by measurement.
            // `yBase` is deliberately NOT published: it is internal to SwiftTerm (Buffer.swift:43
            // declares it without `public`, unlike yDisp at 58), so reading it would not compile.
            // Checked before pushing rather than after CI said so.
            // `pub` names WHICH handler published this reading and counts publishes, so a test can
            // tell "the handler ran and did nothing" from "the handler never ran". Without it, a
            // stale reading from an earlier gesture is indistinguishable from a fresh one, and CI
            // spent a round on exactly that ambiguity: after a single tap the label still read
            // sel=1 text=<lazy>, which could have meant clearTap failed OR that the tap never
            // reached the terminal at all.
            //
            // `fr` IS THE RESPONDER STATE, added so the collapse chevron's contract is measurable
            // at all. Review rejected this PR's first collapse mechanism as inert — a bool cleared
            // in `DispatchQueue.main.async`, which drains before SwiftUI's update flush, so the
            // resign would never have run. Nothing in the suite could have caught that, because
            // "did the terminal give up the responder while keeping its selection" had no
            // observable at all: an inert fix and a working one produced identical output. That is
            // the worst shape a defect can have, so the observable comes with the fix.
            probePublishCount += 1
            probe.accessibilityLabel =
                "sel=\(active ? 1 : 0) len=\(selected.count) text=<\(selected)> "
                + "rows=\(term.rows) cols=\(term.cols) ydisp=\(term.buffer.yDisp) "
                + "fr=\(view.isFirstResponder ? 1 : 0) "
                // MOTION AGE IN MILLISECONDS, published so a test can measure the guard's PREMISE
                // rather than infer it. The previous version of the scroll guard was inert and the
                // only symptom was a test that never reached it, which is indistinguishable from a
                // test whose timing never lined up. With this, a run can say "the tap arrived 40ms
                // after the last offset change" and the premise is a measurement, not a hope.
                + "motionms=\(Int((CACurrentMediaTime() - lastContentMotion) * 1000)) "
                + "resizes=\(resizeCount) pub=\(publisher)#\(probePublishCount)"
            #endif
        }

        func stop() {
            stopped = true                  // no new resize/scroll may start after this
            #if DEBUG
            if let view {
                MainActor.assumeIsolated {
                    TerminalInteractionHarness.unregister(paneID: paneID, view: view)
                }
            }
            #endif
            offsetObservation?.invalidate() // no tail-state publish from a torn-down pane
            offsetObservation = nil
            // Presentation first: a torn-down pane must never be left under a retained
            // frame, and no late reveal or deadline may touch a replaced view.
            finishPresentation()
            if let observer = controlResetObserver {
                // Removed BEFORE the native reset below, so our own write cannot be read
                // as the user's chord being consumed.
                NotificationCenter.default.removeObserver(observer)
                controlResetObserver = nil
            }
            cancelArmedControl()
            view?.sizeChangeRequestHandler = nil
            view?.synchronizedOutputChangeHandler = nil
            view?.displayCompletedHandler = nil
            view?.onWillInsertText = nil
            view?.onCancelControl = nil
            view?.onUserInteraction = nil
            surface?.onGeometryWillChange = nil
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
        /// take ownership with `lock:true` through the geometry drain so the shared PTY —
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
            let target = confirmedTarget ?? desiredTarget
            let inflight = resizeTask
            resizeTask = nil
            let keepalive = keepaliveTask
            keepaliveTask = nil
            // Leave any existing registry entry in place on this early bail (a pane that never
            // laid out): an older release may still be in flight, and its entry is the only handle
            // a future re-lock has to await it.
            guard let target, target.cols >= 4, target.rows >= 2 else { return }
            let cols = target.cols
            let rows = target.rows
            // Hand a generation's lock back EXACTLY ONCE (see releasedGeneration). A second
            // same-generation release — stop() after a hide, or stop()'s .exited+dismantle double
            // call — is a no-op: after stop the drain is handed off and new requests are gated,
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
                await keepalive?.value
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

        /// Front↔background transition for a KEEP-MOUNTED pane. A HIDE KEEPS THE PTY WIDTH-LOCK
        /// and stops refreshing it, letting it lapse on the daemon's TTL; a show RE-ASSERTS it,
        /// which is a no-op at the PTY whenever the lease never lapsed. Hiding used to release
        /// immediately, and that made every agent switch reflow the shared PTY twice and repaint
        /// the agent twice — see the type comment.
        ///
        /// The VISIBLE pane is never left unlocked, because the re-assert's `lock:true` is
        /// guaranteed to be the LAST geometry op even when a TEARDOWN-INITIATED `lock:false` is
        /// still in flight for this pane: (1) bumping `geometryGeneration` makes a not-yet-sent
        /// `lock:false` bail on its generation guard; (2) `relockPending` makes EVERY
        /// geometry request (the re-assert itself AND any fitting proposal in the window) defer
        /// while we await that release, so no `lock:true` can race it; the deferred re-assert then
        /// drives toward the LIVE grid. Different panes own different PTYs + generation keys, so
        /// releases/retakes across panes never contend.
        func setForeground(_ f: Bool) {
            guard !stopped, f != foreground else { return }
            foreground = f
            if f {
                let gen = (Self.geometryGeneration[paneID] ?? 0) + 1
                Self.geometryGeneration[paneID] = gen
                myGeometryGeneration = gen
                // DEFEAT the drain's dedup so the re-assert genuinely re-sends. This is required
                // for correctness now that a hide no longer releases: if the lease LAPSED on the
                // daemon TTL while this pane was hidden, the confirmed target is stale-but-EQUAL
                // to the desired one, so without clearing it here the dedup would skip the
                // re-lock and leave the pane at whatever width the TUI reclaimed. Re-asserting
                // when the lease did NOT lapse is free: it resolves to the same size and the
                // daemon returns early on an unchanged winsize, so it cannot cause the redraw
                // this whole path exists to avoid.
                confirmedTarget = nil
                relockPending = true            // defer requests until any teardown release lands
                // Populated only by `stop()` now, so on a normal re-front this is nil and the await
                // below is a no-op; it still orders a re-front that races a teardown release.
                let pending = Self.geometryReleaseTask[paneID]
                Task { @MainActor [weak self] in
                    // Re-fronting a keep-mounted pane whose geometry changed while hidden can
                    // leave the scroller and the cursor reconciled against the wrong metrics.
                    // Committing the CURRENT stream-applied grid (a same-size commit: no core
                    // reflow) reconciles them and queues one safe repaint - unlike the old
                    // unconditional full repaint, it cannot paint a grid the stream has not
                    // applied yet.
                    if let self, let view = self.view, self.foreground, !self.stopped {
                        let terminal = view.getTerminal()
                        let grid = self.streamAppliedGeometry ?? (cols: terminal.cols, rows: terminal.rows)
                        view.applyTerminalSize(cols: grid.cols, rows: grid.rows)
                    }
                    await pending?.value        // let any committed lock:false land FIRST
                    guard let self, self.foreground, !self.stopped,
                          self.myGeometryGeneration == gen else { return }   // a newer hide/show superseded us
                    self.relockPending = false
                    // Re-take lock:true at THIS pane's own local fit, now last. A hidden pane
                    // kept proposing its fit into `desiredTarget` without sending it.
                    self.startGeometryDrain()
                }
            } else {
                finishPresentation()
                cancelArmedControl()
                relockPending = false           // a hide cancels any pending re-lock intent
                // DELIBERATELY NO RELEASE HERE. A `lock:false` would drop the last width lease,
                // and the daemon then stops forcing a size on purpose (`effective_pty_size` -> None,
                // so `reconcile_pty_lease_size` leaves the winsize to the local TUI, which reclaims
                // its own layout width). That is a REAL winsize change, so the agent takes a SIGWINCH
                // and reflows its whole transcript — and re-fronting re-locked at our grid and made it
                // reflow BACK. Two resizes and two full redraws for every switch between two panes
                // that never even unmounted, which is the "terminal rescrolls when I change agent"
                // report. Holding the lease makes both no-ops, because an unchanged size returns early
                // in the daemon (`current_size == size`).
                //
                // The lease is not refreshed either: `startHeartbeat` is foreground-gated, so a pane
                // nobody is viewing lets its lease expire on the daemon's DEFAULT_PTY_LEASE_TTL (5
                // minutes) and the desktop reclaims the width then. Teardown still releases at once —
                // see `stop()`, which is what hands the width back on close or LRU eviction.
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
            discardPresentationReadiness()
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
        /// `set_pty_size` proposal, so without this its lease would lapse at the daemon's
        /// 5-minute TTL and a co-viewing desktop would reclaim the width. Every
        /// `heartbeatIntervalNanos` we RE-ASSERT the committed tuple as a keepalive: it is
        /// explicitly NOT a geometry change, so it does not clear committed state, bump the
        /// target generation, start a resize presentation or make the reader wait behind a
        /// retained frame. Only a FOREGROUND, non-relocking, idle-drain view
        /// with a committed size refreshes, and the foreground half of that is now
        /// LOAD-BEARING POLICY rather than bookkeeping: a hidden pane KEEPS its lease (a hide no
        /// longer releases — see `setForeground`) and deliberately stops refreshing it, so the
        /// lease expires on the daemon TTL and a co-viewing desktop reclaims the width only once
        /// nobody has looked at the pane for that long. Do not relax this guard to cover hidden
        /// panes: that would pin the width for as long as the app is open. Skipping while a
        /// relock is pending or a drain is in flight preserves the "at most one set_pty_size in
        /// flight per pane" invariant.
        private func startHeartbeat() {
            heartbeatTask?.cancel()
            heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Self.heartbeatIntervalNanos)
                    guard let self, !self.stopped else { return }
                    // Nothing unsettled: no drain, no request in flight, no target waiting
                    // to be sent, and no resize on screen. A keepalive must never overtake
                    // or duplicate a real geometry change.
                    guard self.foreground, !self.relockPending, self.resizeTask == nil,
                          self.inflightTarget == nil, !self.presentationActive,
                          let target = self.confirmedTarget, self.desiredTarget == target,
                          target.cols >= 4, target.rows >= 2 else { continue }
                    let task = Task { @MainActor [weak self] in
                        guard let self, !self.stopped, self.foreground else { return }
                        _ = try? await self.client.setPTYSize(
                            pane: self.paneID, cols: target.cols, rows: target.rows,
                            cellWidthPx: target.cellWidthPx, cellHeightPx: target.cellHeightPx,
                            lock: true, viewerID: self.viewerID, ttl: Self.leaseTTLMillis)
                    }
                    self.keepaliveTask = task
                    await task.value
                    self.keepaliveTask = nil
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
            let now = Date()
            lastStreamActivity = now   // any event (data, ping, resize) means the stream is alive
            // Mirror to the host, which uses it to decide whether returning to the front has
            // a real gap to repair. Only REAL frames count: `start()` optimistically stamps
            // lastStreamActivity before anything arrives, and treating that as evidence would
            // make a stream that connected and then received nothing look healthy.
            liveness?.noteFrame(at: now)
            switch event {
            case .started(let started):
                // Align the emulator to the pane's real geometry the ack carries.
                applyStreamGeometry(cols: started.cols, rows: started.rows, in: view)
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
                    applyStreamGeometry(cols: cols, rows: rows, in: view)
                    // A keyframe replaces the screen: whatever a pending resize was waiting
                    // to reveal describes a screen that no longer exists.
                    discardPresentationReadiness()
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
                    noteStreamData()
                case .data(_, _, let data):
                    noteStreamData()
                    if !data.isEmpty { feedFiltered(data, into: view) }
                case .resize(_, _, let cols, let rows):
                    applyStreamGeometry(cols: cols, rows: rows, in: view)
                case .ping:
                    break   // heartbeat only
                case .exited:
                    sawExited = true
                    // The pane is gone: the error notice must be reachable, never behind
                    // a retained frame.
                    finishPresentation()
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
            finishPresentation()
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

        /// Commits the server's authoritative grid to the emulator, in stream order,
        /// so the bytes that follow lay out at the size they were produced for.
        ///
        /// This is the ONLY place the emulator is resized. A local fit is never
        /// applied here (it is only proposed to the daemon), and the `set_pty_size`
        /// response is not applied either: it arrives on a different operation and is
        /// not an ordering barrier for the stream bytes before it.
        @MainActor
        private func applyStreamGeometry(cols: Int, rows: Int, in view: ReadOnlyTerminalView) {
            let newCols = max(4, cols)
            let newRows = max(2, rows)
            let terminal = view.getTerminal()
            let changed = newCols != terminal.cols || newRows != terminal.rows
            if changed, foreground, !presentationActive, !isOurGeometry(cols: newCols, rows: newRows) {
                // Somebody else (a co-viewer's lease, the agent's own request) changed
                // the grid. Same cover/reveal treatment, but no reciprocal request.
                beginResizePresentation(reason: .server)
            }
            // A same-size commit is deliberate and cheap: it reconciles the scroller and
            // the cursor with the current font metrics and queues one synchronization-aware
            // repaint, without a second core reflow.
            synchronizedBatchBegan = false
            presentationSyncEnded = false
            lastCompleteDraw = nil
            if changed { resizeCount += 1 }
            view.applyTerminalSize(cols: newCols, rows: newRows)
            streamAppliedGeometry = (cols: newCols, rows: newRows)
            streamGeometryRevision += 1
            if presentationActive, presentationReason == .server, changed {
                armPresentationDeadline(after: Self.presentationDeadlineDuration)
            }
            evaluateGeometrySettled()
        }

        /// Whether this grid is one we asked for (so a cover is already up for it).
        private func isOurGeometry(cols: Int, rows: Int) -> Bool {
            if resizeTask != nil || inflightTarget != nil { return true }
            // Once the expected marker has arrived, the same dimensions in a later
            // unsolicited change are not permanently classified as our old request.
            if responseGeneration == targetGeneration, let response = responseGeometry,
               let applied = streamAppliedGeometry, response != applied {
                return response.cols == cols && response.rows == rows
            }
            return false
        }

        /// Unmanaged/public view commits may still notify the delegate. Managed fits
        /// arrive through `sizeChangeRequestHandler`; authoritative stream commits
        /// are counted at their application site and never originate a new request.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Counted for the UI-test probe only: a grid change clears any active
            // selection, so a resize landing AFTER a word select silently destroys it.
            // The count lets a test say "the selection was wiped" rather than "no
            // selection appeared", which are different bugs with different fixes.
            resizeCount += 1
        }

        /// Main-thread only (called from SwiftTerm's layout/font proposal). Records the
        /// grid this view wants and ensures the drain converges to it.
        ///
        /// The model is `desiredTarget` vs `confirmedTarget`: this records the newest
        /// target; a single serialized drain drives the server toward it and stops only
        /// when they are equal. Because at most ONE `set_pty_size` is ever in flight
        /// (the drain awaits each before the next), two resizes can never complete
        /// server-side out of order. Dedup is measured against the TARGET, not the
        /// confirmed size, so a request that matches the committed size while a
        /// different resize is in flight still supersedes it. `lock:true` PINS the
        /// shared PTY to the phone's fit; `releaseGeometryOwnership` hands ownership
        /// back with a `lock:false` on teardown.
        private func requestGeometry(cols: Int, rows: Int) {
            guard !stopped else { return }   // teardown began — no new lock:true (review HIGH)
            #if DEBUG
            let (cols, rows) = MainActor.assumeIsolated {
                TerminalInteractionHarness.fit(paneID: paneID, cols: cols, rows: rows)
            }
            #endif
            guard cols >= 4, rows >= 2 else { return }
            let cell = cellPixels()
            let priorChange = desiredTargetChangedAt
            let target = TerminalGeometryTarget(cols: cols, rows: rows,
                                                cellWidthPx: cell.width, cellHeightPx: cell.height)
            // A repeat of the target we are already driving toward (or sitting at with a
            // drain running) is noise from another layout pass.
            if target == desiredTarget, resizeTask != nil || target == confirmedTarget {
                return
            }
            desiredTarget = target
            desiredTargetChangedAt = ContinuousClock.now
            targetGeneration += 1
            resizeRetries = 0        // a new target gets a fresh retry budget
            presentationGeometrySettled = false
            geometryEligibleAt = nil
            presentationSyncEnded = false
            synchronizedBatchBegan = false
            lastCompleteDraw = nil
            if presentationClosed, resizeTask == nil,
               priorChange.map({ ContinuousClock.now - $0 >= Self.resizeSettleDuration }) ?? true {
                presentationClosed = false
            }
            // The retained frame belongs to the burst, not to one proposal: an animated
            // sweep proposes many grids and covers once.
            beginResizePresentation(reason: .local)
            armPresentationDeadline(after: Self.resizeSettleDuration + Self.presentationDeadlineDuration)
            // A backgrounded pane (or one whose re-lock is still awaiting the in-flight release,
            // `relockPending`) TRACKS the latest grid above but does not start a drain: a hidden
            // pane would re-pin a co-viewing desktop, and a `lock:true` sent during the release
            // window could race the `lock:false` and strand the visible pane unlocked.
            guard foreground, !relockPending else { return }
            startGeometryDrain()
        }

        /// The single serialized drain. At most one `set_pty_size` in flight, and a
        /// target must stand still for `resizeSettleDuration` before it is sent.
        private func startGeometryDrain() {
            guard !stopped, foreground, !relockPending, resizeTask == nil else { return }
            guard let first = desiredTarget, first != confirmedTarget else { return }
            resizeTask = Task { @MainActor [weak self] in
                // A lease keepalive already on the wire finishes first, so the two never
                // overlap: the keepalive is not a geometry change and must not be treated
                // as one, but it still owns the single in-flight slot while it runs.
                await self?.keepaliveTask?.value
                while let self, !Task.isCancelled, !self.stopped, self.foreground,
                      let target = self.desiredTarget, target != self.confirmedTarget {
                    // A TRUE quiet window, measured monotonically from the last change.
                    // Comparing two endpoint samples called a sweep that returned to an
                    // earlier width "still", and sent mid-gesture.
                    if let changedAt = self.desiredTargetChangedAt {
                        let quiet = ContinuousClock.now - changedAt
                        if quiet < Self.resizeSettleDuration {
                            try? await Task.sleep(for: Self.resizeSettleDuration - quiet)
                            continue   // re-read: a newer target may have arrived meanwhile
                        }
                    }
                    guard !Task.isCancelled, !self.stopped, self.foreground,
                          self.desiredTarget == target else { continue }
                    self.inflightTarget = target
                    let generation = self.targetGeneration
                    do {
                        let applied = try await self.client.setPTYSize(
                            pane: self.paneID, cols: target.cols, rows: target.rows,
                            cellWidthPx: target.cellWidthPx, cellHeightPx: target.cellHeightPx,
                            lock: true, viewerID: self.viewerID, ttl: Self.leaseTTLMillis)
                        self.inflightTarget = nil
                        self.confirmedTarget = target       // confirmed: OUR request is committed
                        self.responseGeometry = (cols: applied.cols, rows: applied.rows)
                        self.responseGeneration = generation
                        self.resizeRetries = 0
                        self.noteGeometryResponse()
                    } catch {
                        self.inflightTarget = nil
                        if Task.isCancelled { break }
                        // Retry only while this is still the target; a newer one restarts
                        // the loop with its own budget.
                        if self.desiredTarget == target {
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

        /// The daemon answered a request of ours. This records the effective geometry
        /// and lease result; it is NOT an instruction to reflow — the same grid arrives
        /// in band, in order with the output it applies to.
        private func noteGeometryResponse() {
            if let response = responseGeometry, let applied = streamAppliedGeometry,
               applied == response, let view {
                // Already at this grid (a font-only change, or a size the stream had
                // reported before the answer): reconcile metrics, no marker needed.
                view.applyTerminalSize(cols: applied.cols, rows: applied.rows)
            }
            evaluateGeometrySettled()
        }

        // MARK: retained-frame presentation

        private func currentDrawToken() -> DrawToken? {
            guard let view else { return nil }
            return DrawToken(presentationGeneration: presentationGeneration,
                             targetGeneration: targetGeneration,
                             streamGeometryRevision: streamGeometryRevision,
                             cellSize: view.cellSize,
                             alternate: view.getTerminal().isCurrentBufferAlternate)
        }

        private func beginResizePresentation(reason: PresentationReason) {
            guard !stopped, foreground else { return }
            if presentationActive {
                if reason == .local { presentationReason = .local }
                return
            }
            // A gesture closes the entire in-flight burst, including its late markers.
            // Only a later, stationary-to-moving transition can retain another frame.
            if presentationClosed {
                guard resizeTask == nil, inflightTarget == nil,
                      desiredTargetChangedAt.map({ ContinuousClock.now - $0 >= Self.resizeSettleDuration }) ?? true
                else { return }
            }
            presentationGeneration += 1
            presentationActive = true
            presentationClosed = false
            presentationReason = reason
            presentationStartedOnNormalBuffer = !(view?.getTerminal().isCurrentBufferAlternate ?? false)
            presentationGeometrySettled = false
            geometryEligibleAt = nil
            presentationSyncEnded = false
            synchronizedBatchBegan = false
            presentationDeadlineReached = false
            lastCompleteDraw = nil
            pendingSafeRepaint = false
            tailPublishHeld = true
            if backingDrawComplete, let surface, let image = surface.captureTerminalFrame() {
                surface.installCover(image, anchor: lastReportedAtTail ? .bottomLeft : .topLeft)
            }
            armPresentationDeadline(after: Self.presentationDeadlineDuration)
        }

        private func armPresentationDeadline(after delay: Duration) {
            guard presentationActive else { return }
            presentationDeadlineTask?.cancel()
            presentationDeadlineReached = false
            let generation = presentationGeneration
            let target = targetGeneration
            presentationDeadlineTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.presentationActive,
                      self.presentationGeneration == generation, self.targetGeneration == target else { return }
                self.presentationDeadlineReached = true
                self.evaluatePresentationReveal()
            }
        }

        private func evaluateGeometrySettled() {
            guard presentationActive else { return }
            let settled: Bool
            if presentationReason == .server {
                settled = streamAppliedGeometry != nil
            } else if let response = responseGeometry, let applied = streamAppliedGeometry {
                settled = responseGeneration == targetGeneration && confirmedTarget == desiredTarget && response == applied
            } else {
                settled = false
            }
            if settled && !presentationGeometrySettled {
                geometryEligibleAt = ContinuousClock.now
            }
            presentationGeometrySettled = settled
            evaluatePresentationReveal()
        }

        private func noteStreamData() {
            lastStreamDataAt = ContinuousClock.now
            // A completed backing image is not proof of the bytes now being parsed.
            lastCompleteDraw = nil
            pendingSafeRepaint = false
            if presentationActive { scheduleQuietReveal() }
        }

        private func noteSynchronizedOutput(active: Bool) {
            guard presentationActive else { return }
            if active {
                synchronizedBatchBegan = true
                presentationSyncEnded = false
                lastCompleteDraw = nil
            } else if synchronizedBatchBegan {
                presentationSyncEnded = true
            }
            evaluatePresentationReveal()
        }

        private func noteDisplayCompleted(complete: Bool) {
            backingDrawComplete = complete
            pendingSafeRepaint = false
            lastCompleteDraw = complete ? currentDrawToken() : nil
            evaluatePresentationReveal()
        }

        private func scheduleQuietReveal() {
            guard presentationActive else { return }
            presentationRevealTask?.cancel()
            let generation = presentationGeneration
            presentationRevealTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: Self.presentationQuietDuration) } catch { return }
                guard let self, self.presentationGeneration == generation else { return }
                self.presentationRevealTask = nil
                self.evaluatePresentationReveal()
            }
        }

        private func evaluatePresentationReveal() {
            guard presentationActive, !stopped, let view else { return }
            guard presentationGeometrySettled || presentationDeadlineReached else { return }
            let terminal = view.getTerminal()
            guard !terminal.synchronizedOutputActive else { return }
            if !presentationDeadlineReached, presentationStartedOnNormalBuffer,
               terminal.isCurrentBufferAlternate { return }
            let eligibleAt = geometryEligibleAt ?? ContinuousClock.now
            let quietStart = max(lastStreamDataAt ?? eligibleAt, eligibleAt)
            let ready = presentationDeadlineReached || presentationSyncEnded
                || ContinuousClock.now - quietStart >= Self.presentationQuietDuration
            guard ready else { scheduleQuietReveal(); return }
            if let draw = lastCompleteDraw, draw == currentDrawToken() {
                finishPresentation()
            } else if !pendingSafeRepaint {
                // Reconcile and schedule through the library's synchronization gate,
                // including the no-output/deadline case. Never force DEC 2026 to end.
                pendingSafeRepaint = true
                view.applyTerminalSize(cols: terminal.cols, rows: terminal.rows)
            }
        }

        private func finishPresentation() {
            presentationDeadlineTask?.cancel()
            presentationDeadlineTask = nil
            presentationRevealTask?.cancel()
            presentationRevealTask = nil
            let wasActive = presentationActive
            presentationActive = false
            presentationClosed = true
            tailPublishHeld = false
            surface?.removeCover()
            if wasActive, !stopped, let view {
                let maxOffset = max(0, view.contentSize.height - view.bounds.height)
                reportTailState(atTail: view.contentOffset.y >= maxOffset - 1)
            }
        }

        private func discardPresentationReadiness() {
            finishPresentation()
            presentationGeneration += 1
            backingDrawComplete = false
            lastCompleteDraw = nil
            lastStreamDataAt = nil
        }

        private func userTookControl() {
            if presentationActive { finishPresentation() }
        }

        // MARK: native one-shot Ctrl

        func applyControlModifier() {
            guard let view else { return }
            applyingControlModifier = true
            defer { applyingControlModifier = false }
            view.controlModifier = !stopped && foreground && directFocusIntended
                && view.isFirstResponder && view.keyDriveEnabled && (controlArmedGetter?() ?? false)
        }

        func cancelArmedControl() {
            if controlArmedGetter?() == true { controlArmedSetter?(false) }
            applyingControlModifier = true
            view?.controlModifier = false
            applyingControlModifier = false
        }

        private func prepareForInsertedText(_ text: String, composing: Bool) {
            userTookControl()
            guard !composing, text.unicodeScalars.count == 1, let character = text.first,
                  InputRouter.controlByte(for: character) != nil else {
                cancelArmedControl()
                return
            }
            applyControlModifier()
        }

        /// Cell size from the actual mono font — the DPI hint the server stores.
        private func cellPixels() -> (width: UInt32, height: UInt32) {
            if let view {
                let cell = view.cellSize
                return (UInt32(max(1, cell.width.rounded())), UInt32(max(1, cell.height.rounded())))
            }
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
            userTookControl()
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
        ///
        /// THIS CALLBACK IS NOT ENOUGH ON ITS OWN, and relying on it shipped a broken Latest pill.
        /// On iOS the only route to `terminalDelegate?.scrolled` is
        /// `TerminalView.scrolled(source:yDisp:)` (iOSTerminalView.swift:1481), invoked solely from
        /// `Terminal.scroll()` — i.e. when OUTPUT scrolls the buffer. A FINGER scroll takes a
        /// different path entirely: `contentOffset.didSet` calls `syncYDispFromContentOffset()`,
        /// which calls `Terminal.setViewYDisp(row)`, which assigns `buffer.yDisp` and notifies
        /// NOBODY (Terminal.swift:5616-5619). So dragging back through scrollback on a quiet pane
        /// never reached this method, `reportTailState(atTail: false)` never ran, and the pill that
        /// exists to get the reader back to the live tail never appeared — in exactly the case a
        /// reader needs it. Found by review, not by the receipt, because no test asserted the pill.
        ///
        /// `observeContentOffset()` covers the finger path. Both funnel through `reportTailState`,
        /// which stays the single publisher, judges the alternate screen for both, and dedupes —
        /// so the two sources cannot double-publish and neither can disagree with the other about
        /// the alt buffer. The alt-screen guard that used to sit in this method has moved there;
        /// see the note on `reportTailState` for why the caller is the wrong place for it.
        ///
        /// WHY THE ALT SCREEN NEEDED JUDGING AT ALL: AppleTerminalView.scrollPosition
        /// short-circuits to 0 whenever the display buffer is the alternate one
        /// (st_apple.swift:2012), while Terminal.scroll() notifies the delegate unconditionally
        /// including on that buffer (Terminal.swift:5434). So on a Claude Code pane this callback
        /// saw position 0 on EVERY output frame, and whenever the emulator grid exceeded the
        /// laid-out view — the window before PTY-size negotiation settles, or a co-viewer
        /// reclaiming the size — canScroll was true and atTail latched FALSE. The pill pinned
        /// itself visible on a TUI pane where it cannot mean anything, and tapping it was undone
        /// by the next frame.
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

        // MARK: finger-scroll tail state — the Latest pill's other half

        /// KVO on the terminal's own `contentOffset`, which is the ONLY signal a finger scroll
        /// produces that this layer can see (see `scrolled(source:position:)` for why the delegate
        /// callback never fires on that path).
        ///
        /// KVO AND NOT THE SCROLL DELEGATE, deliberately. `TerminalView` is a `UIScrollView` that
        /// declares `UIScrollViewDelegate` conformance and relies on being its own delegate;
        /// assigning `view.delegate = self` to get `scrollViewDidScroll` would take that over, and
        /// this repo has already paid for that once — the project notes record scrolling broken for
        /// roughly seven builds after claiming SwiftTerm's scroll delegate. Observation is additive
        /// and cannot displace anything.
        ///
        /// The tail test is the same arithmetic the delegate path uses, expressed in offsets
        /// instead of a 0...1 position, so the two agree at the boundary: a pane whose content fits
        /// cannot be scrolled away from the tail and is therefore always parked; otherwise it is at
        /// the tail within one cell of the bottom. One cell rather than one point because
        /// `contentOffset` lands on fractional values mid-deceleration, and a stricter bound made
        /// the pill flicker on and off during a flick.
        private func observeContentOffset(_ view: TerminalView) {
            offsetObservation = view.observe(\.contentOffset, options: [.new]) { scroll, _ in
                // Read the geometry SYNCHRONOUSLY, on whatever thread KVO fired on, then hop —
                // matching this file's existing convention (`Task { @MainActor [weak self] }`) so
                // Coordinator state is only ever touched on the main actor. Deliberately NOT
                // `MainActor.assumeIsolated`: Coordinator is a plain NSObject rather than an
                // actor-isolated type, and assumeIsolated TRAPS if the assumption is wrong, which
                // would turn a diagnostic nicety into a crash on whatever thread UIKit chose.
                let offsetY = scroll.contentOffset.y
                let maxOffset = scroll.contentSize.height - scroll.bounds.height
                // USER-DRIVEN MOTION ONLY, and read HERE, synchronously, while the scroll is
                // actually happening. This is the whole correction to the previous version.
                //
                // Review found that recording EVERY offset change breaks tap-to-focus on the common
                // case: SwiftTerm's auto-follow writes `contentOffset` on every output frame, so on
                // a busy pane the timestamp is permanently fresh and the guard suppressed every tap.
                // That is a worse defect than the one it was fixing — the reader could not focus the
                // terminal at all while an agent was producing output.
                //
                // `isDragging`/`isDecelerating` are exactly the discriminator, and the reason the
                // FIRST attempt failed was WHERE it read them, not WHAT it read: at tap `.ended`
                // they are already cleared, but inside this observer they are true for precisely the
                // offset writes a finger caused. Auto-follow writes arrive with both false and are
                // therefore not motion for this purpose.
                //
                // Reading them on the KVO thread alongside the geometry also keeps this immune to
                // the ordering question the touch-down approach would have raised: nothing here
                // depends on whether a gesture delegate runs before UIScrollView updates its state.
                let userDriven = scroll.isDragging || scroll.isDecelerating
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    // WHEN THE CONTENT LAST MOVED UNDER A FINGER, which is the signal the focus-tap
                    // guard uses. See `handleFocusTap` for why a timestamp rather than a live flag.
                    if userDriven { self.lastContentMotion = CACurrentMediaTime() }
                    // HALF a cell, matching SwiftTerm's own auto-follow threshold rather than a
                    // number I picked. syncYDispFromContentOffset re-engages auto-follow only within
                    // max(contentOffsetTolerance, cellDimension.height / 2) (iOSTerminalView.swift
                    // :1612-1613). A full cell of slack left a HALF-CELL BAND where this reported
                    // at-tail and hid the pill while userScrolling was still true — new output would
                    // not scroll into view and the one affordance for getting back was gone. On a
                    // busy pane the delegate path corrects it on the next line; on a quiet pane it
                    // persists, which is precisely the case the pill exists for. Reported by review,
                    // along with the fact that my comment claiming this used "the same arithmetic" as
                    // the delegate path was wrong: the delegate compares a 0...1 position, this
                    // compares offsets, and they agreed only approximately.
                    let slack = CGFloat(max(self.cellPixels().height, 2)) / 2
                    let canScroll = maxOffset > 1
                    self.reportTailState(atTail: !canScroll || offsetY >= maxOffset - slack)
                }
            }
        }

        // MARK: alt-screen scroll — drag to scroll the AGENT's own view

        /// Accumulated vertical drag since the last emitted scroll tick.
        private var scrollAccum: CGFloat = 0
        /// The alt-screen scroll pan recognizer, disabled on teardown so a drag can't
        /// send bytes to a pane that has exited/been replaced.
        private var scrollPan: UIPanGestureRecognizer?
        /// DEBUG-ONLY diagnostic element (see `publishSelectionProbe`, which is compiled out
        /// entirely in Release). Also nil in a DEBUG build that does not launch with
        /// `HERDR_SCREENSHOT_MOCK`, so it neither allocates nor reaches the accessibility layer
        /// outside a UI-test run. The property itself is left ungated because nothing assigns it
        /// outside that block; an unused optional costs a word and one `#if` less to get wrong.
        private var selectionProbe: UIView?
        /// Monotonic publish counter for the probe, so a reading can be told apart from a stale one.
        /// How recently the terminal's content must have moved for a tap to be read as
        /// "stop scrolling" rather than "give me the keyboard". Covers the gap between the last
        /// `contentOffset` change and touch-up on a scroll-arresting tap, and nothing longer: a
        /// deliberate tap a beat after reading must not wait on this.
        static let scrollSettleWindow: CFTimeInterval = 0.35
        /// `CACurrentMediaTime()` of the last observed `contentOffset` change, written by the KVO
        /// observer in `observeContentOffset`. Starts at 0, which is unreachably far in the past
        /// against a monotonic uptime clock, so a freshly attached pane never suppresses its first
        /// tap — the failure a naive "recent by default" sentinel would cause.
        private var lastContentMotion: CFTimeInterval = 0
        private var probePublishCount = 0
        /// How many 2-tap recognizers `clearTap` was made to require the failure of, captured at
        /// attach. Published by the probe so a test can see whether that chain was wired as
        /// intended rather than inferring it from behaviour.
        private var clearTapRequirementCount = 0
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
