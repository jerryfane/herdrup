import HerdrKit
import SwiftUI
import UIKit

/// The Chat column's width as laid out (#523 items 2 and 12). On regular width (iPad, Mac)
/// it is the reader's chosen width (`ChatColumnWidth`), up to the width the chat has; on
/// compact width (iPhone) it keeps the fixed readable cap, which a phone never reaches.
enum ChatColumnLayout {
    static func width(stored: Double, available: CGFloat, regular: Bool) -> CGFloat {
        guard regular else { return ChatStyle.columnWidth }
        // Before the first measurement the chosen width stands, so the column never lays out
        // at zero for a frame.
        guard available > 0 else { return CGFloat(ChatColumnWidth.sanitized(stored)) }
        return CGFloat(ChatColumnWidth.displayed(stored: stored, available: Double(available)))
    }
}

extension View {
    /// Gives the composer the Chat column's width, centred, while `active` (Chat mode) on
    /// regular width. Terminal mode and compact width keep the full width.
    func chatColumnComposerWidth(_ active: Bool) -> some View {
        modifier(ChatColumnComposerWidth(active: active))
    }
}

private struct ChatColumnComposerWidth: ViewModifier {
    let active: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(ChatColumnWidth.storageKey) private var stored = ChatColumnWidth.defaultWidth
    /// The band's full width: the same as the chat's, which spans the pane above it.
    @State private var available: CGFloat = 0

    func body(content: Content) -> some View {
        let regular = sizeClass == .regular
        content
            .frame(maxWidth: active && regular
                   ? ChatColumnLayout.width(stored: stored, available: available, regular: true)
                   : .infinity)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }
}

/// The two edge handles that resize the Chat column on regular width, and the readout shown
/// while one is dragged. Laid over the whole chat; only the handles hit-test, so scrolling
/// and text selection elsewhere are untouched.
///
/// Dragging either edge resizes around the centre (each point of drag is two of width) between
/// 560 pt and the chat's whole width, snapping to Readable, Wide and Full. A double tap (double
/// click on the Mac) resets to Wide. On the Mac nothing is drawn at rest; a hover shows the
/// edge's hairline and grip, as it does on an iPad with a pointer. On touch the grip shows
/// faintly at rest so it can be found.
struct ChatColumnResizer: View {
    /// The chat's whole width.
    let available: CGFloat
    @Binding var stored: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: ChatColumnWidth.Edge?
    @State private var dragging: ChatColumnWidth.Edge?
    @State private var dragStartWidth: Double?
    @State private var readoutShown = false
    @State private var hideReadout: Task<Void, Never>?
    /// The last short, still touch on a handle: a second one soon after on the same edge resets.
    @State private var lastTap: (edge: ChatColumnWidth.Edge, at: Date)?

    /// The Mac: a pointer, so a narrower hit band and nothing drawn at rest.
    private static let onMac = ProcessInfo.processInfo.isiOSAppOnMac
    private static let hitWidth: CGFloat = onMac ? 20 : 44
    private static let doubleTapInterval: TimeInterval = 0.45
    /// A touch that moves less than this is a tap, not a drag.
    private static let tapSlop: CGFloat = 6
    private static let readoutHold: Duration = {
        #if DEBUG
        // UI tests read the readout after XCUITest releases the drag.
        if let seconds = ProcessInfo.processInfo.environment["HERDR_CHAT_WIDTH_READOUT_HOLD"].flatMap(Double.init) {
            return .milliseconds(Int(seconds * 1000))
        }
        #endif
        return .milliseconds(600)
    }()

    private var availableWidth: Double { Double(available) }
    private var width: Double { ChatColumnWidth.displayed(stored: stored, available: availableWidth) }

    var body: some View {
        // On the column's edges, but never past the chat's own: at Full the bands sit just
        // inside, so they never cover the sidebar or the window edge.
        let reach = max(0, min(CGFloat(width), available - Self.hitWidth) / 2)
        ZStack {
            handle(.leading).offset(x: -reach)
            handle(.trailing).offset(x: reach)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            ZStack {
                if readoutShown { readout.transition(.opacity) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: readoutShown)
        }
    }

    private var readout: some View {
        Text(ChatColumnWidth.readout(width, available: availableWidth))
            .font(Typography.machine(12))
            .tracking(0.3)
            .foregroundStyle(Palette.text)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(hex: 0x40466E).opacity(0.96), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.7), radius: 10, y: 6)
            .padding(.top, 14)
            .allowsHitTesting(false)
            .accessibilityIdentifier("chat-width-readout")
    }

    private func handle(_ edge: ChatColumnWidth.Edge) -> some View {
        let active = dragging == edge
        // Hover only happens with a pointer (the Mac, or an iPad with a trackpad or mouse).
        let shown = dragging != nil || hovered == edge
        return ZStack {
            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1)
                .opacity(shown ? 1 : 0)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(active ? Color(hex: 0xCCD2E6).opacity(0.9) : Palette.textDim.opacity(0.6))
                .frame(width: 4, height: 40)
                .opacity(shown ? 1 : (Self.onMac ? 0 : 0.25))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: shown)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
        .frame(width: Self.hitWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background { if !Self.onMac { ColumnResizePointer() } }
        .onHover { inside in
            if inside { hovered = edge } else if hovered == edge { hovered = nil }
        }
        .gesture(drag(edge))
        .accessibilityElement()
        .accessibilityIdentifier(edge == .leading ? "chat-width-handle-left" : "chat-width-handle-right")
        .accessibilityLabel("Chat width")
        .accessibilityValue(ChatColumnWidth.accessibilityValue(width, available: availableWidth))
        .accessibilityHint("Drag to resize the chat. Double-tap to reset to Wide.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: choose(ChatColumnWidth.incremented(width, available: availableWidth))
            case .decrement: choose(ChatColumnWidth.decremented(width, available: availableWidth))
            @unknown default: break
            }
        }
        .accessibilityAction { reset() }
    }

    /// One gesture for drag and double tap: a drag that starts on touch-down, so the column
    /// follows the finger at once, and that counts as a tap when it ends where it began.
    /// Global space, because the handle moves with the column while it is dragged.
    private func drag(_ edge: ChatColumnWidth.Edge) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartWidth ?? width
                if dragStartWidth == nil { dragStartWidth = start }
                guard abs(value.translation.width) >= 1 || dragging != nil else { return }
                if dragging == nil {
                    dragging = edge
                    showReadout()
                }
                let next = ChatColumnWidth.dragged(from: start, translation: Double(value.translation.width),
                                                   edge: edge, available: availableWidth)
                stored = ChatColumnWidth.stored(for: next, available: availableWidth)
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                dragStartWidth = nil
                if dragging != nil {
                    dragging = nil
                    scheduleReadoutHide()
                }
                guard moved < Self.tapSlop else {
                    lastTap = nil
                    return
                }
                let now = Date()
                if let last = lastTap, last.edge == edge, now.timeIntervalSince(last.at) < Self.doubleTapInterval {
                    lastTap = nil
                    reset()
                } else {
                    lastTap = (edge, now)
                }
            }
    }

    private func choose(_ next: Double) {
        stored = ChatColumnWidth.stored(for: next, available: availableWidth)
    }

    private func reset() {
        stored = ChatColumnWidth.resetWidth
        showReadout()
        scheduleReadoutHide()
    }

    private func showReadout() {
        hideReadout?.cancel()
        hideReadout = nil
        readoutShown = true
    }

    private func scheduleReadoutHide() {
        hideReadout?.cancel()
        hideReadout = Task { @MainActor in
            do { try await Task.sleep(for: Self.readoutHold) } catch { return }
            readoutShown = false
        }
    }
}

/// The iPad's resize pointer over a handle (with a trackpad or mouse): a vertical beam with
/// left and right arrows. Takes hover events only, so touches still reach the handle's SwiftUI
/// gesture. Not on the Mac: a Designed-for-iPad app cannot name AppKit's column-resize cursor
/// (SwiftUI's `pointerStyle` is macOS/visionOS only), and a beam there would read as a text
/// cursor; the hover hairline and grip mark the edge instead.
private struct ColumnResizePointer: UIViewRepresentable {
    func makeUIView(context: Context) -> HoverOnlyView {
        let view = HoverOnlyView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.addInteraction(UIPointerInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ view: HoverOnlyView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class HoverOnlyView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard event?.type == .hover else { return nil }
            return super.hitTest(point, with: event)
        }
    }

    final class Coordinator: NSObject, UIPointerInteractionDelegate {
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            let style = UIPointerStyle(shape: .verticalBeam(length: 24), constrainedAxes: [])
            style.accessories = [UIPointerAccessory.arrow(.left), UIPointerAccessory.arrow(.right)]
            return style
        }
    }
}
