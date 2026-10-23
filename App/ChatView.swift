import HerdrKit
import SwiftUI

/// Who is reading the chat. A guest sees the same conversation without notes or step
/// details (the server leaves them out) and cannot answer omp's questions.
enum ChatViewer: Equatable {
    case owner
    case guest(name: String, ownerName: String)

    var isGuest: Bool { if case .guest = self { return true } else { return false } }
}

enum ChatStyle {
    /// The answered-question tick and a table's gains: the mockup's `--ok`.
    static let ok = Color(hex: 0x7FC89A)
    static let columnWidth: CGFloat = 720
}

/// Why an answer from the chat did not land, shown under the question.
struct ChatAnswerProblem: Equatable {
    let askID: String
    let message: String
    /// omp's question UI could not be driven from here; the person can still answer it in
    /// the Terminal view by hand.
    let offersTerminal: Bool
}

/// The Chat view's state for SwiftUI: HerdrKit's `TranscriptStore` republished, plus the
/// in-flight answer. Owned by the page (not the `ChatView`), so switching to the Terminal
/// and back keeps what was loaded.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var turns: [TranscriptTurn] = []
    @Published private(set) var working: TranscriptWorking?
    @Published private(set) var loaded = false
    @Published private(set) var failure: String?
    @Published private(set) var hasOlder = false
    @Published private(set) var loadingOlder = false
    @Published private(set) var olderFailed = false
    @Published private(set) var answeringAskID: String?
    @Published private(set) var answerProblem: ChatAnswerProblem?
    /// The server cannot give this agent a transcript (not omp, no session file, an older
    /// server or peer): the page goes back to the terminal for good.
    @Published private(set) var unsupported = false

    let store: TranscriptStore

    init(target: String) {
        store = TranscriptStore(target: target)
        store.onChange = { [weak self] in self?.sync() }
    }

    var target: String { store.target }

    func refresh(client: HerdrClient) async {
        await store.refresh(client: client)
    }

    func reload(client: HerdrClient) async {
        await store.reload(client: client)
    }

    func loadOlder(client: HerdrClient) async {
        olderFailed = false
        do {
            try await store.loadOlder(client: client)
        } catch {
            olderFailed = true
        }
    }

    /// Answers omp's open question with one of its options (owner only). The card shows
    /// the choice at once; a refusal puts the buttons back with the reason.
    func answer(client: HerdrClient, askID: String, option: String) async {
        guard answeringAskID == nil else { return }
        answeringAskID = askID
        answerProblem = nil
        defer { answeringAskID = nil }
        do {
            _ = try await client.agentAnswer(target: target, askID: askID, option: option)
            store.noteAnswered(askID: askID, option: option)
        } catch let error as APIError {
            switch error.code {
            case "ask_not_pending":
                // Answered elsewhere (the terminal, the lock screen): the refresh shows it.
                break
            case "selection_mismatch":
                answerProblem = ChatAnswerProblem(
                    askID: askID, message: "omp's options changed. Check the question in the Terminal.",
                    offersTerminal: true)
            default:
                answerProblem = ChatAnswerProblem(
                    askID: askID,
                    message: error.asksForTerminalAnswer
                        ? "This question can't be answered from the chat."
                        : "Couldn't answer: \(error.message)",
                    offersTerminal: error.asksForTerminalAnswer)
            }
        } catch is CancellationError {
            return
        } catch {
            answerProblem = ChatAnswerProblem(askID: askID, message: "Couldn't reach the agent. Try again.",
                                              offersTerminal: false)
        }
        await store.refresh(client: client)
    }

    /// Keeps the chat current while it is on screen: the agent's own events where the
    /// server sends them (owner), a 3 s poll while omp works, and a slow poll otherwise as
    /// a backstop for a missed event (and for guests, who have no event stream).
    func follow(client: HerdrClient, paneID: String?) async {
        await store.refresh(client: client)
        await withTaskGroup(of: Void.self) { group in
            if let paneID {
                group.addTask { await self.followEvents(client: client, paneID: paneID) }
            }
            group.addTask {
                while !Task.isCancelled {
                    let working = await self.store.isWorking
                    try? await Task.sleep(nanoseconds: (working ? 3 : 30) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    await self.store.refresh(client: client)
                }
            }
        }
    }

    private func followEvents(client: HerdrClient, paneID: String) async {
        let subscriptions = [Subscription(.paneAgentStatusChanged, paneID: paneID),
                             Subscription(.paneTurnCompleted, paneID: paneID)]
        while !Task.isCancelled {
            do {
                for try await line in client.subscribe(subscriptions) {
                    if case .event = line { await store.refresh(client: client) }
                }
            } catch is APIError {
                return   // the server refuses the subscription: polling alone keeps up
            } catch {}
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func sync() {
        turns = store.turns
        working = store.working
        hasOlder = store.hasOlder
        loadingOlder = store.loadingOlder
        loaded = store.loaded
        if let error = store.lastError as? AgentTranscriptError {
            switch error {
            case .unsupported: unsupported = true
            case .agentNotFound: failure = "This agent is gone."
            case .unavailable: failure = "omp's session file can't be read right now."
            case .cursorExpired: failure = nil
            }
        } else if let error = store.lastError {
            // A guest whose host refuses the method for guests: the Chat tab goes away.
            let code = (error as? APIError)?.code
            if code == "forbidden" || code == "guest_forbidden" {
                unsupported = true
                failure = nil
            } else {
                failure = "Couldn't load the chat."
            }
        } else {
            failure = nil
        }
    }
}

/// One line of the chat list, flattened from the turns so every row scrolls by id.
private enum ChatRow: Identifiable {
    case day(id: String, ms: UInt64)
    case prompt(TranscriptTurn)
    case item(TranscriptItem)

    var id: String {
        switch self {
        case .day(let id, _): return "day:" + id
        case .prompt(let turn): return "prompt:" + turn.id
        case .item(let item): return "item:" + item.id
        }
    }
}

/// The omp Chat view: the conversation read from omp's session file, newest at the bottom,
/// older turns loading as the reader scrolls up (Gram's pattern). Owner and guest share it.
struct ChatView: View {
    let client: HerdrClient
    @ObservedObject var model: ChatModel
    let viewer: ChatViewer
    /// The pane id to follow events for (owner); nil for a guest, who polls.
    let eventsPaneID: String?
    /// Only the front, visible chat keeps itself current.
    let isActive: Bool
    /// The agent's status as the page knows it: a change prompts a refresh.
    let agentStatus: String?
    /// The page's ground, for the top fade.
    let ground: Color
    let onOpenTerminal: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var expanded: Set<String> = []
    @State private var openNote: TranscriptNote?
    @State private var viewportHeight: CGFloat = 0
    @State private var atBottom = true
    /// The first scroll to the newest turn has landed: until then the top of the list is
    /// on screen for a moment and must not fetch older pages.
    @State private var landed = false
    /// The top of the list is within reach (40 pt) of the viewport's top.
    @State private var topVisible = false

    private static let scrollSpace = "chat-scroll"
    private static let bottomID = "chat-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    topSentinel(proxy)
                    ForEach(rows) { row in
                        rowView(row).id(row.id)
                    }
                    if let working = model.working {
                        workingLine(working).id("chat-working")
                    }
                    if let failure = model.failure {
                        Text(failure).font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("chat-failure")
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.scrollSpace)).minY } action: { minY in
                            atBottom = minY <= viewportHeight + 8
                        }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: ChatStyle.columnWidth)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .overlay(alignment: .top) {
                LinearGradient(colors: [ground, ground.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 26)
                    .allowsHitTesting(false)
            }
            .overlay {
                if !model.loaded {
                    ProgressView().tint(Palette.textDim).accessibilityIdentifier("chat-loading")
                } else if rows.isEmpty, model.failure == nil {
                    Text("No messages yet").font(Typography.app(14)).foregroundStyle(Palette.textFaint)
                }
            }
            .task(id: model.loaded) {
                guard model.loaded, !landed else { return }
                for _ in 0..<8 {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if atBottom { break }
                }
                landed = true
            }
            // New entries while the reader is at the newest: follow them down.
            .onChange(of: rows.last?.id) { _, _ in
                guard landed, atBottom else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: model.working) { _, _ in
                guard landed, atBottom else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
        .background(ground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-view")
        .accessibilityValue("turns=\(model.turns.count)")
        .task(id: isActive) {
            guard isActive else { return }
            await model.follow(client: client, paneID: eventsPaneID)
        }
        .onChange(of: agentStatus) { _, _ in
            guard isActive else { return }
            Task { await model.refresh(client: client) }
        }
        .sheet(item: Binding(get: { openNote.map(IdentifiedNote.init) }, set: { openNote = $0?.note })) { item in
            ChatNoteSheet(note: item.note)
        }
    }

    // MARK: - Rows

    private var rows: [ChatRow] {
        var rows: [ChatRow] = []
        var previousMs: UInt64?
        for turn in model.turns {
            if turn.prompt != nil, turn.startMs > 0 {
                if ChatDay.needsSeparator(previousMs: previousMs, ms: turn.startMs) {
                    rows.append(.day(id: turn.id, ms: turn.startMs))
                }
                previousMs = turn.startMs
                rows.append(.prompt(turn))
            }
            for item in turn.items { rows.append(.item(item)) }
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .day(_, let ms):
            dayLabel(ms)
        case .prompt(let turn):
            promptBubble(turn)
        case .item(let item):
            itemView(item)
        }
    }

    @ViewBuilder
    private func itemView(_ item: TranscriptItem) -> some View {
        switch item {
        case .work(let work):
            workView(work)
        case .reply(_, let text, _):
            ChatMarkdownView(markdown: text)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat-reply")
        case .note(_, let tsMs, let note):
            noteCard(note, tsMs: tsMs)
        case .plan(_, let items):
            planCard(items)
        case .ask(let id, let ask, let pending):
            ChatAskCard(id: id, ask: ask, pending: pending, viewer: viewer,
                        answering: model.answeringAskID == id,
                        problem: model.answerProblem?.askID == id ? model.answerProblem : nil,
                        onAnswer: { option in
                            Task { await model.answer(client: client, askID: id, option: option) }
                        },
                        onOpenTerminal: onOpenTerminal)
                .frame(maxWidth: sizeClass == .regular ? 520 : .infinity, alignment: .leading)
        case .turnFailed(_, let status, let error):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: status == .aborted ? "stop.circle" : "exclamationmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(status == .aborted ? "Stopped" : "Failed\(error.map { " · \($0)" } ?? "")")
                    .font(Typography.app(14)).lineLimit(3)
            }
            .foregroundStyle(status == .aborted ? Palette.textFaint : Palette.died)
            .accessibilityIdentifier("chat-turn-failed")
        case .summary(_, let text):
            HStack(spacing: 10) {
                Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
                Text(text).font(Typography.app(13)).foregroundStyle(Palette.textFaint).fixedSize()
                Rectangle().fill(Palette.hairlineQuiet).frame(height: 1)
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("chat-summary")
        }
    }

    // MARK: - Top of the list

    @ViewBuilder
    private func topSentinel(_ proxy: ScrollViewProxy) -> some View {
        Group {
            if model.loadingOlder {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Palette.textDim)
                    Text("Loading earlier messages").font(Typography.app(13)).foregroundStyle(Palette.textDim)
                }
                .accessibilityIdentifier("chat-older-loading")
            } else if model.olderFailed {
                Button { loadOlder(proxy, retry: true) } label: {
                    Text("Couldn't load earlier messages · Retry").font(Typography.app(13, .medium))
                        .foregroundStyle(Palette.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-older-retry")
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 1)
        .onGeometryChange(for: Bool.self) { proxyGeometry in
            proxyGeometry.frame(in: .named(Self.scrollSpace)).maxY > -40
        } action: { visible in
            topVisible = visible
            if visible { loadOlder(proxy) }
        }
        // `landed` flips after the first scroll; the sentinel may already be on screen.
        .onChange(of: landed) { _, _ in if topVisible { loadOlder(proxy) } }
    }

    /// Fetches the next older page and keeps the row that was on top where it was.
    private func loadOlder(_ proxy: ScrollViewProxy, retry: Bool = false) {
        guard landed, model.hasOlder, !model.loadingOlder, retry || !model.olderFailed else { return }
        let anchor = rows.first?.id
        Task {
            await model.loadOlder(client: client)
            guard let anchor else { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    // MARK: - Pieces

    private func dayLabel(_ ms: UInt64) -> some View {
        let (day, time) = ChatDay.label(ms: ms, now: Date())
        return (Text(day).font(Typography.app(13, .semibold)) + Text(" " + time).font(Typography.app(13)))
            .foregroundStyle(Palette.textFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityIdentifier("chat-day")
    }

    @ViewBuilder
    private func promptBubble(_ turn: TranscriptTurn) -> some View {
        let byline = byline(for: turn.promptAuthor)
        VStack(alignment: .trailing, spacing: 4) {
            if let byline {
                Text(byline).font(Typography.app(12, .medium)).foregroundStyle(Palette.textFaint)
                    .padding(.trailing, 6)
            }
            Text(turn.promptText ?? "")
                .font(Typography.app(16))
                .foregroundStyle(Palette.text)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 10)
                .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                   bottomTrailingRadius: 6, topTrailingRadius: 18)
                    .fill(Palette.surfaceRaised))
                .frame(maxWidth: sizeClass == .regular ? 480 : 296, alignment: .trailing)
                .accessibilityIdentifier("chat-user-bubble")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }

    /// Whose prompt this was, when it was not the reader's own.
    private func byline(for author: TranscriptAuthor?) -> String? {
        switch (viewer, author) {
        case (.owner, .guest(let name)?):
            return "\(name ?? "Guest") · guest"
        case (.guest(_, let owner), .owner?):
            return owner
        case (.guest(let me, _), .guest(let name)?):
            return name == me ? nil : "\(name ?? "Guest") · guest"
        default:
            return nil
        }
    }

    @ViewBuilder
    private func workView(_ work: TranscriptWork) -> some View {
        let thoughtKey = "t:" + work.id
        let stepsKey = "s:" + work.id
        VStack(alignment: .leading, spacing: 10) {
            if let thought = work.latestThought {
                Button { toggle(thoughtKey) } label: {
                    HStack(spacing: 6) {
                        chevron(open: expanded.contains(thoughtKey), color: Palette.textFaint)
                        Text("Thought").font(Typography.app(14, .semibold)).foregroundStyle(Palette.textDim)
                            .fixedSize()
                        if !expanded.contains(thoughtKey) {
                            Text(ChatDay.firstSentence(thought)).font(Typography.app(14))
                                .foregroundStyle(Palette.textFaint).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Thought: \(ChatDay.firstSentence(thought))")
                .accessibilityHint(expanded.contains(thoughtKey) ? "Collapses the thought" : "Shows the whole thought")
                .accessibilityIdentifier("chat-thought")
                if expanded.contains(thoughtKey) {
                    Text(work.thoughts.joined(separator: "\n\n"))
                        .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.vertical, 2).padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairlineQuiet).frame(width: 2) }
                        .padding(.leading, 5)
                        .accessibilityIdentifier("chat-thought-open")
                }
            }
            if !work.steps.isEmpty {
                Button { toggle(stepsKey) } label: {
                    HStack(spacing: 7) {
                        chevron(open: expanded.contains(stepsKey), color: Palette.textDim)
                        stepsSummary(work)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-steps")
                if expanded.contains(stepsKey) {
                    stepList(work)
                }
            }
        }
    }

    private func stepsSummary(_ work: TranscriptWork) -> some View {
        TimelineView(.periodic(from: .now, by: work.live ? 30 : 3600)) { context in
            let endMs = work.live ? UInt64(max(context.date.timeIntervalSince1970 * 1000, 0)) : work.endMs
            let duration = ChatDay.duration(ms: endMs > work.startMs ? endMs - work.startMs : 0)
            let count = work.steps.count == 1 ? "1 step" : "\(work.steps.count) steps"
            (Text("\(work.live ? "Working" : "Worked") for \(duration)").foregroundColor(Palette.textDim)
                + Text(" · \(count)").foregroundColor(Palette.textFaint))
                .font(Typography.app(14))
                .lineLimit(1)
        }
    }

    private func stepList(_ work: TranscriptWork) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(work.steps) { step in
                let running = step.status == .running && work.live
                let detailKey = "d:" + step.id
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(step.status == .error ? Palette.died : running ? Palette.working : Palette.hairline)
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2.5 }
                        Text(step.intent).font(Typography.app(13.5))
                            .foregroundStyle(running ? Palette.textDim : Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if expanded.contains(detailKey), let detail = step.detail, !detail.isEmpty {
                        Text(detail).font(Typography.machine(11.5)).foregroundStyle(Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.leading, 12)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if step.detail != nil { toggle(detailKey) } }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(running ? "\(step.intent), running" : step.intent)
                .accessibilityIdentifier(running ? "chat-step-running" : "chat-step")
            }
        }
        .padding(.vertical, 1).padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairlineQuiet).frame(width: 2) }
        .padding(.leading, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-steplist")
    }

    private func noteCard(_ note: TranscriptNote, tsMs: UInt64) -> some View {
        Button { openNote = note } label: {
            HStack(spacing: 10) {
                Image(systemName: ChatNoteStyle.icon(note.source))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.textDim)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.surfaceRaised))
                VStack(alignment: .leading, spacing: 1) {
                    Text(ChatNoteStyle.kicker(note, tsMs: tsMs))
                        .font(Typography.machine(10.5, .semibold)).tracking(1.2)
                        .foregroundStyle(Palette.textFaint).lineLimit(1)
                    Text(ChatNoteStyle.title(note)).font(Typography.app(14.5)).foregroundStyle(Palette.text).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textFaint)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ChatNoteStyle.sourceName(note.source)) note: \(note.title)")
        .accessibilityHint("Opens the full message")
        .accessibilityIdentifier("chat-note")
    }

    private func planCard(_ items: [TranscriptPlanItem]) -> some View {
        let done = items.filter(\.done).count
        return VStack(alignment: .leading, spacing: 0) {
            Text("PLAN · \(done) OF \(items.count)")
                .font(Typography.machine(10.5, .semibold)).tracking(1.2).foregroundStyle(Palette.textFaint)
                .padding(.bottom, 6)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Image(systemName: item.done ? "checkmark" : "circle")
                        .font(.system(size: item.done ? 11 : 10, weight: .semibold))
                        .foregroundStyle(item.done ? ChatStyle.ok : Palette.textDim)
                        .frame(width: 14)
                    Text(item.text).font(Typography.app(14))
                        .strikethrough(item.done, color: Palette.textFaint.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(item.done ? Palette.textFaint : Palette.textDim)
                .frame(minHeight: 21)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.text)\(item.done ? ", done" : "")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-plan")
    }

    private func workingLine(_ working: TranscriptWorking) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.working).frame(width: 7, height: 7)
                .background(Circle().fill(Palette.working.opacity(0.18)).frame(width: 15, height: 15))
            Text("WORKING · \(working.intent.uppercased())")
                .font(Typography.machine(11.5, .medium)).tracking(0.6)
                .foregroundStyle(Palette.textDim).lineLimit(1)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working: \(working.intent)")
        .accessibilityIdentifier("chat-working")
    }

    private func chevron(open: Bool, color: Color) -> some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 12, height: 12)
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }
}

private struct IdentifiedNote: Identifiable {
    let note: TranscriptNote
    var id: String { note.title + note.body }
}

// MARK: - The question card

/// omp's `ask` question. Owner, open and answerable: the options are buttons (the
/// recommended one, else the first, primary). Guest: the options read-only with "Waiting
/// for <owner> to answer". Answered: "You chose …".
struct ChatAskCard: View {
    let id: String
    let ask: TranscriptAsk
    let pending: TranscriptPendingAsk?
    let viewer: ChatViewer
    let answering: Bool
    let problem: ChatAnswerProblem?
    let onAnswer: (String) -> Void
    let onOpenTerminal: () -> Void

    private var question: TranscriptQuestion? { ask.questions.first }

    var body: some View {
        Group {
            if let answer = ask.answer {
                answered(answer)
            } else if pending != nil {
                open
            } else {
                unanswered
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-ask")
    }

    private var questionText: String {
        ask.questions.map(\.question).joined(separator: "\n")
    }

    private func answered(_ answer: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(questionText).font(Typography.app(14, .medium)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(ChatStyle.ok)
                (Text(chooser + " chose ").foregroundColor(Palette.textDim)
                    + Text(answer.joined(separator: ", ")).font(Typography.app(14.5, .semibold)).foregroundColor(Palette.text))
                    .font(Typography.app(14.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-ask-chosen")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(card)
    }

    private var chooser: String {
        switch viewer {
        case .owner: return "You"
        case .guest(_, let owner): return owner
        }
    }

    private var canAnswer: Bool {
        viewer == .owner && pending?.answerable == true && question != nil
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(questionText).font(Typography.app(15, .semibold)).foregroundStyle(Palette.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            let options = question?.options ?? []
            let primary = question?.recommended ?? 0
            VStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    if canAnswer {
                        Button { onAnswer(option) } label: {
                            optionLabel(option, primary: index == primary, readOnly: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(answering)
                        .accessibilityIdentifier("chat-ask-option-\(index)")
                    } else {
                        optionLabel(option, primary: false, readOnly: true)
                            .accessibilityIdentifier("chat-ask-option-\(index)")
                    }
                }
            }
            .opacity(answering ? 0.6 : 1)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(card)
    }

    @ViewBuilder
    private var footer: some View {
        if case .guest(_, let owner) = viewer {
            HStack(spacing: 8) {
                Circle().fill(Palette.waiting).frame(width: 7, height: 7)
                Text("WAITING FOR \(owner.uppercased()) TO ANSWER")
                    .font(Typography.machine(10.5, .semibold)).tracking(1.2).foregroundStyle(Palette.waiting)
            }
            .padding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-ask-waiting")
        } else if let problem {
            VStack(alignment: .leading, spacing: 8) {
                Text(problem.message).font(Typography.app(13)).foregroundStyle(Palette.waiting)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat-ask-problem")
                if problem.offersTerminal { terminalButton }
            }
            .padding(.top, 10)
        } else if !canAnswer {
            // A multi-part or multi-select question: the chat shows it, the terminal answers it.
            terminalButton.padding(.top, 10)
        }
    }

    private var terminalButton: some View {
        Button(action: onOpenTerminal) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 12, weight: .semibold))
                Text("Answer in Terminal").font(Typography.app(14, .semibold))
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14).frame(height: 36)
            .background(Capsule().fill(Palette.surfaceRaised))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-ask-terminal")
    }

    private var unanswered: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(questionText).font(Typography.app(14, .medium)).foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text("Not answered").font(Typography.app(13)).foregroundStyle(Palette.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(card)
    }

    private func optionLabel(_ option: String, primary: Bool, readOnly: Bool) -> some View {
        Text(option)
            .font(Typography.app(15, .medium))
            .foregroundStyle(readOnly ? Palette.textDim : primary ? Palette.ground : Palette.text)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(readOnly ? Color.clear : primary ? Palette.text : Palette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(readOnly ? Palette.hairlineQuiet : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 16).fill(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

// MARK: - Notes

enum ChatNoteStyle {
    static func icon(_ source: TranscriptNoteSource) -> String {
        switch source {
        case .gitmoot: return "envelope"
        case .asyncResult: return "tray.and.arrow.down"
        case .advisor: return "lightbulb"
        case .other: return "bell"
        }
    }

    static func sourceName(_ source: TranscriptNoteSource) -> String {
        switch source {
        case .gitmoot: return "Gitmoot"
        case .asyncResult: return "Async result"
        case .advisor: return "Advisor"
        case .other: return "Agent"
        }
    }

    /// "GITMOOT · 4:51 PM", as the mockup labels it; the sender goes after the title.
    static func kicker(_ note: TranscriptNote, tsMs: UInt64) -> String {
        let source = sourceName(note.source).uppercased()
        guard tsMs > 0 else { return source }
        let time = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000)
            .formatted(date: .omitted, time: .shortened)
        return "\(source) · \(time.uppercased())"
    }

    /// "Review approved · herdr #305 · from herdr-kimi-review".
    static func title(_ note: TranscriptNote) -> String {
        guard let from = note.from, !from.isEmpty else { return note.title }
        return "\(note.title) · from \(from)"
    }
}

/// The full text of a note card. Notes never notify; this is the only place they open.
private struct ChatNoteSheet: View {
    let note: TranscriptNote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ChatNoteStyle.kicker(note, tsMs: 0))
                        .font(Typography.machine(10.5, .semibold)).tracking(1.2).foregroundStyle(Palette.textFaint)
                    Text(ChatNoteStyle.title(note)).font(Typography.app(18, .semibold)).foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    ChatMarkdownView(markdown: note.body)
                }
                .padding(16)
                .frame(maxWidth: ChatStyle.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.ground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("chat-note-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("chat-note-sheet")
    }
}

// MARK: - Time

enum ChatDay {
    /// A separator before a prompt on a new day, or after an hour's quiet.
    static func needsSeparator(previousMs: UInt64?, ms: UInt64) -> Bool {
        guard let previousMs else { return true }
        let previous = Date(timeIntervalSince1970: TimeInterval(previousMs) / 1000)
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        if !Calendar.current.isDate(previous, inSameDayAs: date) { return true }
        return ms > previousMs && ms - previousMs >= 60 * 60 * 1000
    }

    /// ("Today", "2:05 PM"), ("Yesterday", …), a weekday this week, else the date.
    static func label(ms: UInt64, now: Date) -> (String, String) {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return ("Today", time) }
        if calendar.isDateInYesterday(date) { return ("Yesterday", time) }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return (date.formatted(.dateTime.weekday(.wide)), time)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return (date.formatted(.dateTime.month(.abbreviated).day()), time)
        }
        return (date.formatted(.dateTime.month(.abbreviated).day().year()), time)
    }

    static func duration(ms: UInt64) -> String {
        let seconds = Int(ms / 1000)
        if seconds < 60 { return "\(max(seconds, 1)) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The collapsed thought line: its first sentence (the line truncates the rest).
    static func firstSentence(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        if let end = line.range(of: ". ") { return String(line[..<end.lowerBound]) + "." }
        return line
    }
}
