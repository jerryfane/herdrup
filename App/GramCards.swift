import HerdrKit
import SwiftUI
import UIKit

// Building blocks for Gram's final design (option D's iMessage layout and agent cards in
// option C's herdr colours; spec gram-final-d-with-c-colours.html, round 3). Every colour
// is a Palette or GramBubble token. These views draw their CONTENT only: the outer margins
// the spec gives them (time separator 16 pt above, unread rule 12 pt above, the saved
// badge's -17/-15 corner offset, 9 pt above an embedded file card) belong to the feed.

/// Sizes shared by the Gram cards.
enum GramCardMetrics {
    /// A card's width (code, text + file, a lone file): phone, then iPad/Mac.
    static let compactCardWidth: CGFloat = 295
    static let regularCardWidth: CGFloat = 520

    static func cardWidth(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? regularCardWidth : compactCardWidth
    }

    /// An image card: 295 x 124 on a phone, 440 x 236 on iPad/Mac.
    static func imageSize(_ sizeClass: UserInterfaceSizeClass?) -> CGSize {
        sizeClass == .regular ? CGSize(width: 440, height: 236) : CGSize(width: 295, height: 124)
    }
}

/// Gram's type roles with the spec's line heights (body 17/22, code 13/18, row preview
/// 14/18). SwiftUI has no line-height modifier, so the spacing is the line height minus
/// the bundled font's own, at the current `Typography.scale`.
enum GramType {
    static var body: Font { Typography.app(17) }
    static var bodyLineSpacing: CGFloat { lineSpacing("Geist-Regular", size: 17, lineHeight: 22) }
    static var code: Font { Typography.machine(13) }
    static var codeLineSpacing: CGFloat { lineSpacing("IBMPlexMono", size: 13, lineHeight: 18) }
    static var preview: Font { Typography.app(14) }
    static var previewLineSpacing: CGFloat { lineSpacing("Geist-Regular", size: 14, lineHeight: 18) }

    private static func lineSpacing(_ postScriptName: String, size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let scale = Typography.scale
        guard let font = UIFont(name: postScriptName, size: size * scale) else { return 0 }
        return max(0, lineHeight * scale - font.lineHeight)
    }
}

/// Day and time wording for the feed's separators and the sidebar rows, like Messages.
enum GramDates {
    /// "Today" / "Yesterday" / a weekday within the last week / a date, plus the time.
    static func separator(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> (day: String, time: String) {
        let time = timeFormatter.string(from: date)
        switch day(of: date, now: now, calendar: calendar) {
        case .today: return ("Today", time)
        case .yesterday: return ("Yesterday", time)
        case .thisWeek: return (weekdayFormatter.string(from: date), time)
        case .thisYear: return (dayMonthFormatter.string(from: date), time)
        case .earlier: return (dayMonthYearFormatter.string(from: date), time)
        }
    }

    /// A sidebar row's time: the time today, then "Yesterday", a weekday, a short date.
    static func rowTime(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch day(of: date, now: now, calendar: calendar) {
        case .today: return timeFormatter.string(from: date)
        case .yesterday: return "Yesterday"
        case .thisWeek: return weekdayFormatter.string(from: date)
        case .thisYear, .earlier: return shortDateFormatter.string(from: date)
        }
    }

    private enum Day { case today, yesterday, thisWeek, thisYear, earlier }

    private static func day(of date: Date, now: Date, calendar: Calendar) -> Day {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? .max
        if (2..<7).contains(days) { return .thisWeek }
        return calendar.isDate(date, equalTo: now, toGranularity: .year) ? .thisYear : .earlier
    }

    private static func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let timeFormatter = formatter(template: "jmm")
    private static let weekdayFormatter = formatter(template: "EEEE")
    private static let dayMonthFormatter = formatter(template: "EEEdMMM")
    private static let dayMonthYearFormatter = formatter(template: "dMMMyyyy")
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Avatars

/// An agent's round avatar: its name's identity gradient and initial. A federated name
/// (`<machine>/<name>`) shows its bare name, so one agent reads the same on every machine.
struct GramAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let bare = GramMessage.agentName(from: name)
        Text(AgentIdentity.glyph(forName: bare))
            .font(Typography.app((size * 0.45).rounded(), .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: size, height: size)
            .background(AgentIdentity.gradient(forName: bare), in: Circle())
            .accessibilityHidden(true)
    }
}

private extension View {
    /// A ring of `color` drawn OUTSIDE the view (it cuts the avatar out of whatever it
    /// overlaps), without changing the view's layout size.
    func gramRing(_ color: Color, width: CGFloat) -> some View {
        background(Circle().fill(color).padding(-width))
    }
}

/// Distinct bare names, in order, at most `limit`.
private func distinctAgentNames(_ names: [String], limit: Int) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for name in names {
        let bare = GramMessage.agentName(from: name)
        guard seen.insert(bare).inserted else { continue }
        result.append(bare)
        if result.count == limit { break }
    }
    return result
}

/// The conversation header's avatar group: the first name (the most recent sender) as a
/// 38 pt avatar in the middle, the next two as 26 pt avatars either side, each ringed in
/// the ground. A fixed 78 x 48 box so the header does not move as senders change.
struct GramAvatarCluster: View {
    let names: [String]

    var body: some View {
        let shown = distinctAgentNames(names, limit: 3)
        ZStack(alignment: .topLeading) {
            if shown.count > 1 { side(shown[1], x: 0) }
            if shown.count > 2 { side(shown[2], x: 52) }
            if let main = shown.first {
                GramAvatar(name: main, size: 38)
                    .gramRing(Palette.ground, width: 2)
                    .offset(x: 20, y: 2)
            }
        }
        .frame(width: 78, height: 48, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func side(_ name: String, x: CGFloat) -> some View {
        GramAvatar(name: name, size: 26)
            .gramRing(Palette.ground, width: 2)
            .offset(x: x, y: 16)
    }
}

// MARK: - Text

/// A long message folded to four lines, with "Show more" laid over the end of the fourth
/// line on a fade into the bubble (the spec's `.clamp` + `.more`). No button when the text
/// fits. Expanding is one-way, like Messages; the caller holds `isExpanded` so the state
/// survives the row being recycled.
///
/// The font is the 17/22 body; the colour is inherited, so the caller tints it for its side.
/// `fill` is the bubble's fill, which the fade runs into.
struct GramFoldingText: View {
    let text: AttributedString
    @Binding var isExpanded: Bool
    var fill: Color = GramBubble.inFill

    static let foldedLineLimit = 4

    @State private var fullHeight: CGFloat = 0
    @State private var foldedHeight: CGFloat = 0

    private var folds: Bool { fullHeight > foldedHeight + 0.5 }

    var body: some View {
        bodyText
            .lineLimit(isExpanded ? nil : Self.foldedLineLimit)
            .fixedSize(horizontal: false, vertical: true)
            // Measured at the shown text's width: the whole text, and four lines of it.
            .background(alignment: .topLeading) { probes }
            .overlay(alignment: .bottomTrailing) {
                if folds && !isExpanded { showMore }
            }
    }

    private var bodyText: some View {
        Text(text)
            .font(GramType.body)
            .lineSpacing(GramType.bodyLineSpacing)
    }

    private var showMore: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isExpanded = true }
        } label: {
            HStack(spacing: 0) {
                // 28 pt lead-in, opaque from 26 pt: the line under it fades out, not cuts off.
                LinearGradient(stops: [.init(color: fill.opacity(0), location: 0),
                                       .init(color: fill, location: 26.0 / 28.0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
                Text("Show more")
                    .font(Typography.app(17, .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .fixedSize()
                    .background(fill)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("gram-show-more")
    }

    private var probes: some View {
        ZStack(alignment: .topLeading) {
            bodyText
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            bodyText
                .lineLimit(Self.foldedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { foldedHeight = $0 }
        }
        // `.hidden()`, not opacity 0: an invisible copy still sits in the accessibility tree
        // (the probe test found the report three times there, so VoiceOver read it three
        // times) and its full height counted in the bubble's frame. Hidden views keep their
        // layout, so the measurements still arrive.
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Code

/// A fenced code block: monospaced 13/18 on the machine ground, with Copy. One line shows
/// only a copy glyph beside the code; several lines get a header with the language and
/// "Copy". Long lines scroll sideways rather than wrap, so a command keeps its shape.
///
/// Copy WRITES the pasteboard only (never reads it: a programmatic read raises the system
/// paste prompt), through the receipt `CopyableCommand` uses, so only the block whose code
/// is actually on the clipboard says "Copied", and only for a moment.
struct GramCodeBlock: View {
    let code: String
    let language: String?

    @State private var receipt = CopiedCommandReceipt.shared

    private var copied: Bool { receipt.text == code }
    private var isOneLine: Bool { !code.contains("\n") }
    private static let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    var body: some View {
        Group {
            if isOneLine {
                HStack(spacing: 8) {
                    codeText
                    copyButton {
                        copyGlyph(size: 14, tint: Palette.textDim)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 3)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let language, !language.isEmpty {
                            Text(language)
                                .font(Typography.app(11.5))
                                .foregroundStyle(Palette.textDim)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        // An acting control: ink, like the file card's actions.
                        copyButton {
                            HStack(spacing: 4) {
                                copyGlyph(size: 11, tint: Palette.text)
                                Text(copied ? "Copied" : "Copy")
                                    .font(Typography.app(12, .semibold))
                                    .foregroundStyle(copied ? Palette.done : Palette.text)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                    }
                    codeText
                }
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.groundMachine, in: Self.shape)
        .overlay(Self.shape.strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var codeText: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(GramType.code)
                .lineSpacing(GramType.codeLineSpacing)
                .foregroundStyle(Palette.text)
                .fixedSize()
        }
    }

    private func copyGlyph(size: CGFloat, tint: Color) -> some View {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(copied ? Palette.done : tint)
    }

    private func copyButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button(action: { receipt.record(code) }, label: label)
            .buttonStyle(.plain)
            .accessibilityLabel(Text(copied ? "Copied" : "Copy code"))
            .accessibilityIdentifier("gram-code-copy")
    }
}

// MARK: - Attachments

private func sizeLabel(_ byteCount: Int?) -> String? {
    byteCount.map { GramFile.displaySize(of: UInt64(max(0, $0))) }
}

/// An attached image: the picture (top-aligned, filled) with a caption bar over its foot
/// holding the name and size. On iPad/Mac the bar carries "Open" and "Save to Files"; the
/// phone's narrower card has the name as the Open control and a save glyph. Tapping the
/// picture opens it too. `thumbnail` is nil until the file is cached.
struct GramImageCard: View {
    let name: String
    let byteCount: Int?
    let thumbnail: UIImage?
    let onOpen: () -> Void
    let onSave: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let size = GramCardMetrics.imageSize(sizeClass)
        let regular = sizeClass == .regular
        ZStack(alignment: .bottom) {
            picture
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .accessibilityHidden(true)
            caption(regular: regular)
                .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: GramBubble.radius, style: .continuous))
    }

    @ViewBuilder
    private var picture: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Palette.surfaceRaised
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(Palette.textFaint)
            }
        }
    }

    private var spokenName: String {
        [name, sizeLabel(byteCount)].compactMap { $0 }.joined(separator: ", ")
    }

    private var nameLabel: some View {
        (Text(name).foregroundStyle(Palette.text)
            + Text(sizeLabel(byteCount).map { " · \($0)" } ?? "").foregroundStyle(Palette.textDim))
            .font(Typography.app(13))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(regular: Bool) -> some View {
        HStack(spacing: regular ? 4 : 6) {
            if regular {
                nameLabel
                    .accessibilityLabel(spokenName)
                captionButton("Open", id: "gram-attachment-open", action: onOpen)
                captionButton("Save to Files", id: "gram-attachment-save", action: onSave)
            } else {
                Button(action: onOpen) {
                    nameLabel.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open")
                .accessibilityValue(spokenName)
                .accessibilityIdentifier("gram-attachment-open")
                Button(action: onSave) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Palette.text)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save to Files")
                .accessibilityIdentifier("gram-attachment-save")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, regular ? 4 : 1)
        .frame(height: 30)
        .background(Palette.surface.opacity(0.82), in: Capsule())
    }

    private func captionButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(13, .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Palette.surfaceRaised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// An attached file: a document icon labelled with the extension, the name, "<kind> · <size>",
/// and an "Open" | "Save to Files" action row. On its own it is an agent card (bubble fill,
/// card radius, card width); `embedded` draws it inside a card that has text above it, so it
/// has no background or corners of its own and opens with the hairline that divides the two
/// (the caller leaves 9 pt between its text and this).
struct GramFileCard: View {
    let name: String
    let kind: String
    let byteCount: Int?
    let onOpen: () -> Void
    let onSave: () -> Void
    var embedded = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if embedded {
            content
        } else {
            content
                .frame(width: GramCardMetrics.cardWidth(sizeClass))
                .background(GramBubble.inFill)
                .clipShape(RoundedRectangle(cornerRadius: GramBubble.radius, style: .continuous))
        }
    }

    private var detail: String {
        [kind.isEmpty ? nil : kind, sizeLabel(byteCount)].compactMap { $0 }.joined(separator: " · ")
    }

    private var content: some View {
        VStack(spacing: 0) {
            if embedded { rule }
            HStack(spacing: 10) {
                GramDocumentIcon(label: String((name as NSString).pathExtension.uppercased().prefix(4)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(Typography.app(13))
                            .foregroundStyle(Palette.textDim)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
            rule
            HStack(spacing: 0) {
                actionButton("Open", id: "gram-attachment-open", action: onOpen)
                Rectangle().fill(Palette.hairline).frame(width: 1)
                actionButton("Save to Files", id: "gram-attachment-save", action: onSave)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rule: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }

    private func actionButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(15, .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.top, 9)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// A 32 x 40 page with a folded-looking corner and the file's extension at its foot.
private struct GramDocumentIcon: View {
    let label: String

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                               bottomTrailingRadius: 3, topTrailingRadius: 9, style: .continuous)
            .fill(Palette.textDim)
            .frame(width: 32, height: 40)
            .overlay(alignment: .bottom) {
                Text(label)
                    .font(Typography.app(8, .bold))
                    .foregroundStyle(Palette.ground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 6)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Feed marks

/// The saved mark, drawn like an iMessage tapback on the bubble's top corner: a violet
/// 32 x 30 badge with a white bookmark and two trailing dots, all ringed in the ground.
/// The feed places it (overlay top-trailing, offset x +15, y -17) and gives that bubble
/// 12 pt more room above.
struct GramSavedBadge: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Circle().fill(GramBubble.outFill)
                .frame(width: 4.5, height: 4.5)
                .gramRing(Palette.ground, width: 1.5)
                .offset(x: -5, y: 7)
            Circle().fill(GramBubble.outFill)
                .frame(width: 9, height: 9)
                .gramRing(Palette.ground, width: 2)
                .offset(x: 0, y: 2)
            Image(systemName: "bookmark.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 30)
                .background(GramBubble.outFill, in: Capsule())
                .background(Capsule().fill(Palette.ground).padding(-2))
        }
        .frame(width: 32, height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved")
        .accessibilityIdentifier("gram-saved-badge")
    }
}

/// A centred time mark between messages: "**Today** 14:32".
struct GramTimeSeparator: View {
    let date: Date

    var body: some View {
        let parts = GramDates.separator(for: date)
        (Text(parts.day).font(Typography.app(11, .semibold)) + Text(" \(parts.time)").font(Typography.app(11)))
            .foregroundStyle(Palette.textFaint)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The amber "N unread" rule above the first unread message.
struct GramUnreadRule: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            line
            Text("\(count) unread")
                .font(Typography.app(11, .semibold))
                .foregroundStyle(Palette.waiting)
                .lineLimit(1)
                .fixedSize()
            line
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) unread")
    }

    private var line: some View {
        Rectangle().fill(Palette.waiting.opacity(0.45)).frame(height: 1)
    }
}

// MARK: - Sidebar

/// One conversation in the iPad/Mac sidebar, like a Messages row: stacked avatars of the
/// latest senders (or a symbol, e.g. Saved's bookmark), the title and time, and a two-line
/// preview. Selected rows fill with your bubble's violet; unread ones get the amber dot.
/// The row is only the label: the caller wraps it in a Button and owns its identifier and
/// selected trait. `avatarNames` are most recent first.
struct GramConversationRow: View {
    let title: String
    let avatarNames: [String]
    let systemImage: String?
    let preview: AttributedString
    let time: Date?
    let unread: Bool
    let selected: Bool

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    private var secondary: Color { selected ? Color.white.opacity(0.82) : Palette.textDim }

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(Typography.app(16, .semibold))
                        .foregroundStyle(selected ? Color.white : Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let time {
                        Text(GramDates.rowTime(for: time))
                            .font(Typography.app(14))
                            .foregroundStyle(selected ? Color.white.opacity(0.82) : Palette.textFaint)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Text(preview)
                    .font(GramType.preview)
                    .lineSpacing(GramType.previewLineSpacing)
                    .foregroundStyle(secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 74, maxHeight: 74)
        .background {
            if selected { Self.shape.fill(GramBubble.outFill) }
        }
        .overlay(alignment: .leading) {
            if unread {
                Circle().fill(Palette.waiting)
                    .frame(width: 10, height: 10)
                    .padding(.leading, 7)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Self.shape)
        .accessibilityElement(children: .combine)
        .accessibilityValue(unread ? "Unread" : "")
    }

    @ViewBuilder
    private var avatar: some View {
        let names = distinctAgentNames(avatarNames, limit: 2)
        if let systemImage {
            symbolAvatar(systemImage)
        } else if names.count == 2 {
            // Two 29 pt avatars stacked corner to corner in a 44 pt square; the front one is
            // ringed in the row's own fill so it cuts cleanly out of the back one.
            ZStack(alignment: .topLeading) {
                GramAvatar(name: names[0], size: 29)
                GramAvatar(name: names[1], size: 29)
                    .gramRing(selected ? GramBubble.outFill : Palette.ground, width: 2)
                    .offset(x: 15, y: 15)
            }
            .frame(width: 44, height: 44, alignment: .topLeading)
        } else if let name = names.first {
            GramAvatar(name: name, size: 44)
        } else {
            symbolAvatar("bubble.left.and.bubble.right.fill")
        }
    }

    private func symbolAvatar(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(Palette.brand)
            .frame(width: 44, height: 44)
            .background(Palette.surfaceRaised, in: Circle())
            .accessibilityHidden(true)
    }
}
