import Combine
import HerdrKit
import SwiftUI
import UIKit

/// Geometry shared by the Terminal and Gram composers, from the approved HTML.
enum ComposerStyle {
    static let fontSize: CGFloat = 16
    static var lineHeight: CGFloat { 24 * Typography.scale }
    /// How far the typed text and its placeholder start in from the composer's own
    /// content padding. The round surface reads tighter than a rectangular one at the
    /// same padding, so the text needs a little more room on the left than the HTML's
    /// box gives it.
    ///
    /// LEADING PADDING ON THE FIELD, not the text container's inset. As a
    /// `textContainerInset` the glyphs moved inside an unchanged element frame, so a
    /// coordinate tap resolved to a different character: the existing iPad receipt for
    /// typing after a multiline paste failed deterministically (run 35340997265).
    /// Padding moves the element and its text together, so taps still land where they
    /// look like they land.
    static let textLeadingInset: CGFloat = 5
    static let actionHover = Color(red: 38 * 1.15 / 255, green: 42 * 1.15 / 255, blue: 69 * 1.15 / 255)
    static let primaryKeyHover = Color(red: 238 * 0.9 / 255, green: 240 * 0.9 / 255, blue: 247 * 0.9 / 255)
    static let cornerRadius: CGFloat = 28
    /// Lines the field shows before its text scrolls. The pull-to-expand editor is the
    /// way to see more at once.
    static let visibleLines = 5
    /// The drag handle appears once the text reaches this many lines.
    static let handleLines = 3
}

/// The attributes the composer text view renders with, shared with the layout so the
/// line count that decides one row versus toolbar is measured exactly as it is drawn.
enum ComposerTextMetrics {
    static func attributes() -> [NSAttributedString.Key: Any] {
        let size = ComposerStyle.fontSize * Typography.scale
        let lineHeight = ComposerStyle.lineHeight
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let face = UIFont(name: "Geist-Regular", size: size) ?? .systemFont(ofSize: size)
        // A fixed line taller than the font puts the spare height ABOVE the glyphs, so a
        // single line sat low against the buttons it now shares a row with. The baseline
        // lands at lineHeight + descender; lift it so the cap height is centred.
        let lift = max(0, lineHeight / 2 + face.descender - face.capHeight / 2)
        return [.font: face, .foregroundColor: UIColor(Palette.text), .paragraphStyle: paragraph,
                .baselineOffset: lift]
    }

    /// The height `text` needs at `width`, measured from the string rather than from a
    /// laid-out text view, snapped to whole lines.
    static func height(of text: String, width: CGFloat,
                       attributes: [NSAttributedString.Key: Any], lineHeight: CGFloat) -> CGFloat {
        // boundingRect drops a trailing newline, which would hide the empty line a
        // pasted "a\n" ends on; the space gives that line something to measure.
        var measured = text
        if measured.isEmpty || measured.hasSuffix("\n") { measured += " " }
        let box = (measured as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil)
        return max(1, ceil(box.height / lineHeight)) * lineHeight
    }

    static func lines(of text: String, width: CGFloat) -> Int {
        let lineHeight = ComposerStyle.lineHeight
        return Int((height(of: text, width: width, attributes: attributes(), lineHeight: lineHeight)
                    / lineHeight).rounded())
    }
}

/// What each child of `AdaptiveComposerLayout` is, so optional children (the attachment
/// strip, the recording strip, the keyboard button) can come and go without the others
/// being misplaced.
enum ComposerRole { case field, recording, accessory, leading, actions }

private struct ComposerRoleKey: LayoutValueKey {
    static let defaultValue = ComposerRole.field
}

extension View {
    fileprivate func composerRole(_ role: ComposerRole) -> some View {
        layoutValue(key: ComposerRoleKey.self, value: role)
    }
}

/// One row at rest — text, then the leading tool and the actions on the right — and,
/// once `expanded`, the text at full width with the attachment strip and a toolbar
/// (leading tool left, actions right) underneath.
///
/// A single Layout rather than two view trees: switching trees would rebuild the text
/// view and drop its keyboard in the middle of typing. Here the same subviews only move,
/// and the move animates with whatever transaction changed `expanded`.
struct AdaptiveComposerLayout: Layout {
    var expanded: Bool
    /// Recording with nothing typed yet: the waveform takes the text row's place.
    var recordingReplacesField: Bool

    static let rowGap: CGFloat = 4
    static let recordingGap: CGFloat = 8
    static let toolbarGap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        for (index, frame) in arrange(width: bounds.width, subviews: subviews).frames {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (height: CGFloat, frames: [(Int, CGRect)]) {
        func index(_ role: ComposerRole) -> Int? {
            subviews.indices.first { subviews[$0][ComposerRoleKey.self] == role }
        }
        func size(_ index: Int?, width: CGFloat? = nil) -> CGSize {
            guard let index else { return .zero }
            return subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        let field = index(.field), recording = index(.recording), accessory = index(.accessory)
        let leading = index(.leading), actions = index(.actions)
        let actionsSize = size(actions)
        let leadingSize = size(leading)
        var frames: [(Int, CGRect)] = []

        func columnHeight(_ columnWidth: CGFloat) -> CGFloat {
            let fieldHeight = size(field, width: columnWidth).height
            guard recording != nil else { return fieldHeight }
            let recordingHeight = size(recording, width: columnWidth).height
            return recordingReplacesField ? max(fieldHeight, recordingHeight)
                : fieldHeight + Self.recordingGap + recordingHeight
        }

        /// The text and the recording strip stacked in a column `columnWidth` wide.
        func column(originY: CGFloat, width columnWidth: CGFloat) -> CGFloat {
            let fieldSize = size(field, width: columnWidth)
            let recordingSize = size(recording, width: columnWidth)
            if let field {
                frames.append((field, CGRect(x: 0, y: originY, width: columnWidth, height: fieldSize.height)))
            }
            guard let recording else { return fieldSize.height }
            if recordingReplacesField {
                let height = max(fieldSize.height, recordingSize.height)
                frames.append((recording, CGRect(x: 0, y: originY + (height - recordingSize.height) / 2,
                                                 width: columnWidth, height: recordingSize.height)))
                return height
            }
            let y = originY + fieldSize.height + Self.recordingGap
            frames.append((recording, CGRect(x: 0, y: y, width: columnWidth, height: recordingSize.height)))
            return fieldSize.height + Self.recordingGap + recordingSize.height
        }

        if !expanded {
            let trailing = actionsSize.width + (leading == nil ? 0 : leadingSize.width + Self.rowGap)
            let columnWidth = max(0, width - trailing - Self.rowGap)
            // A single line sits centred against the buttons.
            let stackHeight = columnHeight(columnWidth)
            let rowHeight = max(stackHeight, actionsSize.height, leadingSize.height)
            _ = column(originY: (rowHeight - stackHeight) / 2, width: columnWidth)
            if let actions {
                frames.append((actions, CGRect(x: width - actionsSize.width, y: rowHeight - actionsSize.height,
                                               width: actionsSize.width, height: actionsSize.height)))
            }
            if let leading {
                frames.append((leading, CGRect(x: width - actionsSize.width - Self.rowGap - leadingSize.width,
                                               y: rowHeight - leadingSize.height,
                                               width: leadingSize.width, height: leadingSize.height)))
            }
            // Staged attachments always expand the composer; this only keeps a stray
            // accessory visible if a caller ever shows one in the single row.
            if let accessory {
                let accessorySize = size(accessory, width: width)
                frames = frames.map { ($0.0, $0.1.offsetBy(dx: 0, dy: accessorySize.height + Self.toolbarGap)) }
                frames.append((accessory, CGRect(origin: .zero, size: CGSize(width: width, height: accessorySize.height))))
                return (rowHeight + accessorySize.height + Self.toolbarGap, frames)
            }
            return (rowHeight, frames)
        }

        var y = column(originY: 0, width: width) + Self.toolbarGap
        if let accessory {
            let accessorySize = size(accessory, width: width)
            frames.append((accessory, CGRect(x: 0, y: y, width: width, height: accessorySize.height)))
            y += accessorySize.height + Self.toolbarGap
        }
        let rowHeight = max(actionsSize.height, leadingSize.height)
        if let leading {
            frames.append((leading, CGRect(x: 0, y: y + (rowHeight - leadingSize.height) / 2,
                                           width: leadingSize.width, height: leadingSize.height)))
        }
        if let actions {
            frames.append((actions, CGRect(x: width - actionsSize.width, y: y + (rowHeight - actionsSize.height) / 2,
                                           width: actionsSize.width, height: actionsSize.height)))
        }
        return (y + rowHeight, frames)
    }
}

private struct ComposerEditorRoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The height of the composer host's flexible content (the terminal, or Gram's
    /// message list). The pull-to-expand editor takes most of it; zero hides the handle.
    var composerEditorRoom: CGFloat {
        get { self[ComposerEditorRoomKey.self] }
        set { self[ComposerEditorRoomKey.self] = newValue }
    }
}

/// The Terminal and Gram composer: one row at rest, a toolbar under the text once it
/// wraps, a drag handle that opens a tall editor for long prompts, and the recording
/// waveform and glowing border while dictating.
///
/// `field` receives the height the editor wants (nil when closed) and must pass it to
/// `ComposerTextField(fixedHeight:)`. `actions` hosts the mic and send buttons;
/// `leading` the keyboard button. Both are measured, not assumed.
struct AdaptiveComposer<Field: View, Accessory: View, Leading: View, Actions: View>: View {
    let text: String
    let isFocused: Bool
    var hasAccessory = false
    /// Whether `leading` is shown. Explicit rather than an empty builder, because a
    /// hidden view cannot report that its width went back to zero.
    var showsLeading = false
    var isRecording = false
    @ViewBuilder var field: (CGFloat?) -> Field
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var meter = VoiceLevelMeter()
    @State private var contentWidth: CGFloat = 0
    @State private var actionsWidth: CGFloat = 0
    @State private var leadingWidth: CGFloat = 0
    @State private var wrapped = false
    /// Counts open/close changes of the editor, for the haptic.
    @State private var editorToggles = 0
    /// The editor's text height while it is open or being dragged; nil when closed.
    @State private var editorHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?
    @State private var dragBeganOpen = false
    /// The host's flexible space (terminal or message list) with the editor closed. The
    /// editor's size comes from this, frozen while it is open, because the editor itself
    /// takes that space.
    @Environment(\.composerEditorRoom) private var liveRoom
    @State private var room: CGFloat = 0

    /// The text starts where it always has: 6 points of surface padding plus this.
    private static var fieldLeading: CGFloat { ComposerStyle.textLeadingInset + 7 }
    private var lineHeight: CGFloat { ComposerStyle.lineHeight }
    private var editorOpen: Bool { editorHeight != nil }
    private static var fieldInsets: CGFloat { fieldLeading + 2 }
    private var trimmedEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var inlineTextWidth: CGFloat {
        contentWidth - actionsWidth - (showsLeading ? leadingWidth + AdaptiveComposerLayout.rowGap : 0)
            - AdaptiveComposerLayout.rowGap - Self.fieldInsets
    }

    /// Whether the text needs more than the single row. Once wrapped it stays wrapped
    /// until the text fits with room to spare, so typing at the edge cannot flicker
    /// between the two arrangements.
    private var wrapsNow: Bool {
        guard contentWidth > 0 else { return false }
        let width = wrapped ? inlineTextWidth - 16 : inlineTextWidth
        return ComposerTextMetrics.lines(of: text, width: width) > 1
    }

    private var fullLines: Int {
        guard contentWidth > 0 else { return 1 }
        return ComposerTextMetrics.lines(of: text, width: contentWidth - Self.fieldInsets)
    }

    private var expanded: Bool { hasAccessory || editorOpen || wrapsNow }
    /// Extra height the editor may take beyond the inline field: most of the host's
    /// flexible space, keeping at least 96 points of it, in whole lines.
    private var editorExtra: CGFloat {
        floor(max(0, room - 96) * 0.75 / lineHeight) * lineHeight
    }
    /// The handle only appears when opening the editor would show at least one more line.
    private var showsHandle: Bool {
        !isRecording && (editorOpen || (fullLines >= ComposerStyle.handleLines && editorExtra >= lineHeight))
    }
    private var naturalFieldHeight: CGFloat { CGFloat(min(fullLines, ComposerStyle.visibleLines)) * lineHeight }
    /// The editor takes real layout height from the host's flexible space, as the
    /// keyboard does.
    private var maxEditorHeight: CGFloat { naturalFieldHeight + editorExtra }

    private var growth: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86) }
    private var rearrange: Animation? { reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.8) }

    var body: some View {
        let expanded = expanded
        AdaptiveComposerLayout(expanded: expanded, recordingReplacesField: isRecording && trimmedEmpty) {
            field(editorHeight)
                .padding(.leading, Self.fieldLeading)
                .padding(.trailing, 2)
                .opacity(isRecording && trimmedEmpty ? 0 : 1)
                .composerRole(.field)
            if isRecording {
                VoiceWaveformStrip()
                    .padding(.leading, Self.fieldLeading)
                    .transition(.opacity)
                    .composerRole(.recording)
            }
            accessory().composerRole(.accessory)
            if showsLeading {
                leading()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .composerRole(.leading)
            }
            actions()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actionsWidth = $0 }
                .composerRole(.actions)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .padding(.top, expanded ? (showsHandle ? 20 : 11) : 6)
        .padding(.bottom, 6)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .animation(growth, value: fullLines)
        .animation(rearrange, value: expanded)
        .animation(rearrange, value: isRecording)
        .animation(rearrange, value: showsLeading)
        .animation(rearrange, value: showsHandle)
        .onChange(of: wrapsNow) { _, now in wrapped = now }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: ComposerStyle.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-card")
        .overlay {
            if isRecording {
                VoiceGlowBorder(cornerRadius: ComposerStyle.cornerRadius)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: ComposerStyle.cornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? Palette.textFaint : Palette.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if showsHandle {
                handle
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .top)))
            }
        }
        // The overlays sit outside the animated content above, so their transitions need
        // their own animation.
        .animation(rearrange, value: showsHandle)
        .animation(rearrange, value: isRecording)
        .environment(meter)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: liveRoom, initial: true) { _, value in
            if !editorOpen && dragStartHeight == nil { room = value }
        }
        .onChange(of: editorOpen) { _, open in if !open { room = liveRoom } }
        // Sending or clearing the text, or starting to dictate, closes the editor.
        .onChange(of: trimmedEmpty) { _, empty in if empty { setEditor(nil) } }
        .onChange(of: isRecording) { _, recording in if recording { setEditor(nil) } }
        .sensoryFeedback(.impact(weight: .light), trigger: editorToggles)
    }

    private var handle: some View {
        Capsule()
            .fill(Palette.textFaint)
            .frame(width: 36, height: 4)
            .frame(width: 72, height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = editorHeight ?? naturalFieldHeight
                            dragBeganOpen = editorOpen
                        }
                        guard let start = dragStartHeight, abs(value.translation.height) > 3 else { return }
                        var direct = Transaction()
                        direct.disablesAnimations = true
                        withTransaction(direct) {
                            editorHeight = Self.rubberBand(start - value.translation.height,
                                                           lower: naturalFieldHeight, upper: maxEditorHeight)
                        }
                    }
                    .onEnded { value in
                        let start = dragStartHeight ?? naturalFieldHeight
                        dragStartHeight = nil
                        let target: CGFloat?
                        if abs(value.translation.height) <= 3 {
                            target = dragBeganOpen ? nil : maxEditorHeight
                        } else {
                            let predicted = start - value.predictedEndTranslation.height
                            target = predicted > (naturalFieldHeight + maxEditorHeight) / 2 ? maxEditorHeight : nil
                        }
                        if (target != nil) != dragBeganOpen { editorToggles += 1 }
                        animateEditor(to: target)
                    })
            .accessibilityElement()
            .accessibilityLabel(editorOpen ? "Collapse editor" : "Expand editor")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setEditor(editorOpen ? nil : maxEditorHeight) }
            .accessibilityIdentifier("composer-expand-handle")
    }

    private func setEditor(_ height: CGFloat?) {
        guard editorHeight != height else { return }
        if (height != nil) != editorOpen { editorToggles += 1 }
        animateEditor(to: height)
    }

    private func animateEditor(to height: CGFloat?) {
        let animation: Animation? = reduceMotion
            ? .easeInOut(duration: 0.15)
            : .interactiveSpring(response: 0.45, dampingFraction: 0.8)
        withAnimation(animation) { editorHeight = height }
    }

    /// Follows the finger inside [lower, upper] and resists beyond it.
    private static func rubberBand(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        if value > upper { return upper + (value - upper) * 0.25 }
        if value < lower { return lower - (lower - value) * 0.25 }
        return value
    }
}

struct ComposerActionIcon: View {
    let image: Image
    var tint: Color?
    var primary = false
    var busy = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle().fill(hovering && isEnabled
                          ? (primary ? .white : ComposerStyle.actionHover)
                          : (primary ? Palette.text : Palette.surfaceRaised))
                .frame(width: 40, height: 40)
            if busy {
                ComposerSendingIcon()
            } else {
                image.resizable().renderingMode(.template).scaledToFit()
                    .frame(width: 18, height: 18)
            }
        }
        .foregroundStyle(tint ?? (primary ? Palette.ground : Palette.textDim))
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

struct ComposerQuickKeyLabel: View {
    let text: String
    var imageName: String?
    var primary = false
    var armed = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var fill: Color {
        if armed { return Palette.working }
        if primary { return hovering && isEnabled ? ComposerStyle.primaryKeyHover : Palette.text }
        return hovering && isEnabled ? Palette.surfaceRaised : Palette.surface
    }

    var body: some View {
        Group {
            if let imageName {
                Image(imageName).resizable().renderingMode(.template).frame(width: 14, height: 14)
            } else {
                Text(text).font(.system(size: 12 * Typography.scale, design: .monospaced))
            }
        }
        .foregroundStyle(primary || armed ? Palette.ground : Palette.textDim)
        .padding(.horizontal, 10)
        .frame(minWidth: 44, minHeight: 34)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .circular))
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

private struct ComposerSendingIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Image("ComposerSending").resizable().renderingMode(.template)
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1.2).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { spinning = true }
    }
}

enum ComposerAttachmentState {
    case ready
    case waiting
    case uploading(sent: Int, total: Int)
    case sending
    case sent
    case failed

    var progress: Double? {
        guard case let .uploading(sent, total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(sent) / Double(total)))
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isSent: Bool {
        if case .sent = self { return true }
        return false
    }

    var isIndeterminate: Bool {
        switch self {
        case .sending: return true
        case .uploading(_, let total): return total <= 0
        default: return false
        }
    }

    func label(size: Int) -> String {
        let sizeLabel = GramFile.displaySize(of: UInt64(max(0, size)))
        switch self {
        case .ready: return "\(sizeLabel) · Ready"
        case .waiting: return "\(sizeLabel) · Waiting"
        case .uploading:
            guard let progress else { return "Uploading…" }
            return "\(Int((progress * 100).rounded()))% · \(sizeLabel)"
        case .sending: return "Sending…"
        case .sent: return "Sent · \(sizeLabel)"
        case .failed: return "Failed · tap send to retry"
        }
    }
}

struct ComposerAttachmentChip: View {
    let name: String
    let size: Int
    let isImage: Bool
    let state: ComposerAttachmentState
    let canRemove: Bool
    let onRemove: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveringRemove = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if let progress = state.progress {
                    Circle().stroke(Palette.hairline, lineWidth: 2)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Palette.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
                } else if state.isIndeterminate {
                    ComposerProgressRing()
                }
                Image(state.isSent ? "ComposerCheck" : state.isFailed ? "ComposerAlert" : isImage ? "ComposerPhoto" : "ComposerFile")
                    .resizable().renderingMode(.template).frame(width: 19, height: 19)
                    .foregroundStyle(state.isFailed ? Palette.died : state.isSent ? Palette.text : Palette.textDim)
            }
            .padding(2)
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Typography.app(12))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(height: 18 * Typography.scale, alignment: .leading)
                Text(state.label(size: size)).font(Typography.app(10))
                    .foregroundStyle(state.isFailed ? Palette.died : Palette.textDim)
                    .monospacedDigit().lineLimit(1)
                    .frame(height: 15 * Typography.scale, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image("ComposerClose").resizable().renderingMode(.template)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(hoveringRemove && canRemove ? Palette.text : Palette.textDim)
                    .frame(width: 24, height: 24)
                    .background(hoveringRemove && canRemove ? Palette.surface : .clear, in: Circle())
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .opacity(canRemove ? 1 : 0.25)
            .onHover { hoveringRemove = $0 }
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .padding(.vertical, 9)
        .frame(width: sizeClass == .compact ? 218 : 228)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 15, style: .circular))
    }
}

private struct ComposerProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: 2)
            Circle().trim(from: 0, to: 0.23)
                .stroke(Palette.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 270 : -90))
                .animation(reduceMotion ? nil : .linear(duration: 1.3).repeatForever(autoreverses: false),
                           value: spinning)
        }
        .onAppear { spinning = true }
    }
}

/// Whether a software keyboard is covering the screen, so the composer should offer a
/// button to dismiss it. Focus alone does not prove that (notably on iPad).
///
/// Judged from the keyboard's on-screen height, not from `GCKeyboard`. With a hardware
/// keyboard attached iOS shows only a short shortcut bar, and that stays hidden here. But
/// `GCKeyboard.coalesced` can report a keyboard while the full software keyboard is still
/// up (the simulator does; so can a phone with a paired keyboard), which used to hide the
/// only way to dismiss it.
@MainActor
final class ComposerKeyboard: ObservableObject {
    @Published private(set) var isVisible = false
    private var keyboardFrame = CGRect.zero
    private var observations: Set<AnyCancellable> = []

    init() {
        let center = NotificationCenter.default
        center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self else { return }
                keyboardFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                updateVisibility()
            }.store(in: &observations)
        center.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.keyboardFrame = .zero
                self?.updateVisibility()
            }.store(in: &observations)
    }

    /// Taller than any shortcut or candidate bar shown with a hardware keyboard, shorter
    /// than any software keyboard, including the iPad's floating one.
    static let softwareKeyboardMinimumHeight: CGFloat = 150

    private func updateVisibility() {
        let covered = keyboardFrame.intersection(UIScreen.main.bounds).height
        isVisible = !ProcessInfo.processInfo.isiOSAppOnMac && covered >= Self.softwareKeyboardMinimumHeight
    }
}
