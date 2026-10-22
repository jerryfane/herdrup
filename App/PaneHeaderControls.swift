import HerdrKit
import SwiftUI
import UIKit

// The agent page's header controls (#358), shared by the owner's terminal pane
// (`TerminalPaneContent`) and a guest's shared-agent page (`GuestPaneView`): the round back
// button, the top-right capsule and its buttons, the ⋯ menu's label and the sections both
// pages offer, and the "Latest" pill over the terminal.

/// The 44 pt round back button at the header's leading edge.
struct PaneHeaderBackButton: View {
    var identifier: String?
    let action: () -> Void

    @ViewBuilder var body: some View {
        let button = Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Palette.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        if let identifier { button.accessibilityIdentifier(identifier) } else { button }
    }
}

/// The header's top-right capsule: its buttons side by side (40 × 44 each) on one
/// `surfaceRaised` capsule.
struct PaneHeaderCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 2)
            .background(Capsule().fill(Palette.surfaceRaised))
    }
}

/// Reconnect and refresh: the page re-creates the terminal's stream and re-reads the agent.
struct PaneHeaderRefreshButton: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("Reconnect and refresh")
    }
}

/// The ⋯ menu's label. While this agent's notifications are off it shows a struck bell in
/// amber, so the state reads at a glance without opening the menu.
struct PaneActionsMenuLabel: View {
    let notificationsOff: Bool

    var body: some View {
        Image(systemName: notificationsOff ? "bell.slash" : "ellipsis")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(notificationsOff ? Palette.waiting : Palette.text)
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
    }
}

/// ⋯ → Copy screen / Copy recent output: the pane's text as `agent.read` returns it, onto
/// the pasteboard.
struct TerminalCopyMenuSection: View {
    let client: HerdrClient
    let paneID: String

    var body: some View {
        Section {
            Button {
                Task {
                    if let out = try? await client.read(pane: paneID, source: .visible, format: .text) {
                        UIPasteboard.general.string = out.text
                    }
                }
            } label: { Label("Copy screen", systemImage: "doc.on.doc") }
            Button {
                Task {
                    if let out = try? await client.read(pane: paneID, source: .recentUnwrapped, format: .text) {
                        UIPasteboard.general.string = out.text
                    }
                }
            } label: { Label("Copy recent output", systemImage: "doc.on.clipboard") }
        }
    }
}

/// ⋯ → Text size: Increase, Decrease and Reset of the page's own terminal text size.
struct TerminalTextSizeMenuSection: View {
    let increaseID: String
    let decreaseID: String
    let onIncrease: () -> Void
    let onDecrease: () -> Void
    let onReset: () -> Void

    var body: some View {
        Section("Text size") {
            Button(action: onIncrease) { Label("Increase", systemImage: "textformat.size.larger") }
                .accessibilityIdentifier(increaseID)
            Button(action: onDecrease) { Label("Decrease", systemImage: "textformat.size.smaller") }
                .accessibilityIdentifier(decreaseID)
            Button(action: onReset) { Label("Reset", systemImage: "arrow.counterclockwise") }
        }
    }
}

/// Shown only while the terminal is scrolled away from its newest output, so it is out of
/// the way the rest of the time. Uses the app's primary ink-fill treatment, the same one the
/// send arrow and the banner's Switch button use. An overlay, not a gesture: only the pill
/// hit-tests, taps elsewhere reach the terminal.
struct TerminalJumpToLatestPill: View {
    var identifier: String?
    let action: () -> Void

    @ViewBuilder var body: some View {
        let pill = Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .semibold))
                Text("Latest").font(Typography.app(12, .semibold))
            }
            .foregroundStyle(Palette.ground)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Palette.text).clipShape(Capsule())
        }
        .padding(.trailing, 16).padding(.bottom, 12)
        .accessibilityLabel(Text("Jump to latest output"))
        if let identifier { pill.accessibilityIdentifier(identifier) } else { pill }
    }
}

/// Shown at the top of the terminal while an older page of its history loads, in the words
/// and ink of Gram's "Loading older messages…" sentinel, on a surface capsule so it reads
/// over terminal output. Not a control: the page lands by itself, and touches pass through
/// to the terminal, which keeps scrolling underneath.
struct TerminalHistoryLoadingCapsule: View {
    var identifier = "terminal-history-loading"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Palette.textFaint)
            Text("Loading earlier output…")
        }
        .font(Typography.app(12))
        .foregroundStyle(Palette.textFaint)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Palette.surface).clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .padding(.top, 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
