import SwiftUI
import HerdrKit

/// One open terminal in the keep-alive container. This is the OPEN CONTEXT captured when a
/// pane is opened — NOT a cached object: the live stream, SwiftTerm emulator, and per-pane
/// `@State` all live inside the mounted `TerminalPaneContent`, which is never torn down while
/// its slot exists. Identity is the pane id, so `ForEach` never remounts a slot when the LRU
/// list is reordered or another pane is fronted.
struct PaneSlot: Identifiable {
    let paneID: String
    let title: String
    let agent: AgentInfo?
    /// A spawn pre-fill (the new-agent task) for the pane it opened; "" for list/Terminal-tab
    /// opens. Siblings carry "" too, so a pre-fill never leaks to a neighbour.
    let initialReply: String
    /// The ordered agents this pane can swipe-page through (snapshot at open time).
    let siblings: [AgentInfo]
    var id: String { paneID }
}

/// Hosts the recently-opened terminal panes MOUNTED but hidden, so reopening — and swiping
/// between them — is instant: nothing is torn down or re-streamed. Exactly one slot is the
/// FRONT (visible, interactive, holding the PTY width-lock); the rest sit at opacity 0 with
/// hit-testing disabled, their stream still warm and their lock released. Opening/paging just
/// changes which slot is front.
///
/// It lives INSIDE `TerminalHomeView`, which is the point: a reconnect bumps the view's
/// `.id(session)` and dismantles every mounted pane (each `Coordinator.stop()` closing its
/// stream) for free — no manual "drop panes on reconnect" bookkeeping.
struct PaneKeepAliveContainer: View {
    let client: HerdrClient
    let slots: [PaneSlot]
    let frontID: String?
    /// Back out of the fronted pane to the list (header chevron / left-edge swipe).
    let onClose: () -> Void
    /// Swipe to the prev/next agent: (the slot the swipe came from, ±1).
    let onNavigate: (PaneSlot, Int) -> Void

    var body: some View {
        ZStack {
            ForEach(slots) { slot in
                let isFront = slot.paneID == frontID
                TerminalPaneContent(
                    client: client,
                    paneID: slot.paneID,
                    title: slot.title,
                    agent: slot.agent,
                    initialReply: slot.initialReply,
                    isForeground: isFront,
                    onNavigate: { onNavigate(slot, $0) },
                    onClose: onClose)
                    // STABLE identity — the pane id, NEVER a swipe-varying `currentID`. So a
                    // swipe or an LRU reorder flips visibility without giving the subtree a new
                    // identity (which would dismantle it and re-stream from a cold handshake).
                    .id(slot.paneID)
                    .opacity(isFront ? 1 : 0)
                    .allowsHitTesting(isFront)
                    .zIndex(isFront ? 1 : 0)
                    // A hidden warm pane is invisible AND inert — keep it out of the
                    // accessibility tree too (VoiceOver shouldn't read an offscreen pane; it
                    // also makes the paging XCUITest's assertions unambiguous).
                    .accessibilityHidden(!isFront)
            }
        }
    }
}
