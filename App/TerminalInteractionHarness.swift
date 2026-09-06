#if DEBUG && canImport(UIKit)
import Foundation
import SwiftUI
import SwiftTerm
import UIKit
import HerdrKit

/// A tiny ordered PTY peer. Every pane owns its own continuation, byte offset,
/// history reader and resize script; the root only routes decoded envelopes.
final class TerminalInteractionDriver: @unchecked Sendable {
    enum Scenario: String, CaseIterable {
        case quiet, delayed, wider, failure, busy, synchronized, beforeMarker, afterResponse
    }
    private struct Request: Decodable {
        let id: String
        let method: String
        let params: Params?
        struct Params: Decodable {
            var paneID: String?
            var cols: Int?
            var rows: Int?
            var text: String?
            var lock: Bool?
            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case cols, rows, text, lock
            }
        }
    }
    static let fixtureAgents: [[String: String]] = [("ix:a", "RESIZE-ALFA"), ("ix:b", "RESIZE-BRAVO")].map { pane, name in
        ["pane_id": pane, "name": name, "agent": name, "agent_status": "idle", "cwd": "/root/" + name]
    }
    private let mutex = NSLock()
    private var children: [String: TerminalInteractionDriver] = [:]
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var lifetime: UUID?
    private var offset: UInt64 = 0
    private var epoch: UInt64 = 7
    private var cols = 80
    private var rows = 24
    private var opens = 0
    private var requests = 0
    private var failures = 0
    private var appended = 0
    private var previousActions = 0
    private var nextActions = 0
    private var clearActions = 0
    private var legacyPrevious = 0
    private var kittyPrevious = 0
    private var historyIndex = 2
    private var input = ""
    private var pendingInput = ""
    private var scenario = Scenario.quiet
    private var kitty = false
    private let paneID: String
    private let control: Bool
    private let history = ["first-known-command", "second-known-command"]

    init(paneID: String = "", control: Bool = false) {
        self.paneID = paneID
        self.control = control
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock(); defer { mutex.unlock() }
        return try body()
    }

    func pane(_ id: String) -> TerminalInteractionDriver {
        if id == paneID { return self }
        return locked {
            if let existing = children[id] { return existing }
            let child = TerminalInteractionDriver(paneID: id, control: control)
            children[id] = child
            return child
        }
    }

    static func json(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    func roundTrip(_ line: String) async throws -> String {
        let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
        if let id = request.params?.paneID, id != paneID {
            return try await pane(id).roundTrip(line)
        }
        switch request.method {
        case "agent.list":
            return Self.json(["id": request.id, "result": ["type": "agent_list", "agents": Self.fixtureAgents]])
        case "pane.set_pty_size":
            return try await resize(request)
        case "pane.send_text":
            locked { consume(request.params?.text ?? "") }
            return Self.json(["id": request.id, "result": [:]])
        case "agent.read":
            return Self.json(["id": request.id, "result": ["read": [
                "pane_id": paneID, "text": "", "truncated": false,
                "source": "recent", "format": "ansi"]]])
        default:
            // Existing canned replies retain their contracts. Only PTY-specific
            // methods above are intercepted, by decoded method rather than substring.
            return try await MockTransport().roundTrip(line)
        }
    }

    private func resize(_ request: Request) async throws -> String {
        let plan = locked { () -> (Scenario, Int, Int, UInt64, UUID?) in
            requests += 1
            return (scenario, max(4, request.params?.cols ?? cols),
                    max(2, request.params?.rows ?? rows), epoch, lifetime)
        }
        if plan.0 == .failure {
            locked { failures += 1 }
            throw NSError(domain: "TerminalInteractionFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "deliberate PTY request failure"])
        }
        if plan.0 == .delayed { try await Task.sleep(nanoseconds: 450_000_000) }
        let effectiveCols = plan.0 == .wider ? max(140, plan.1) : plan.1
        let commit = { [self] in
            locked {
                guard epoch == plan.3, lifetime == plan.4 else { return }
                if plan.0 == .beforeMarker { emitData("\r\nBEFORE-MARKER old-grid\r\nfixture> ") }
                cols = effectiveCols; rows = plan.2
                emitFrame("resize", extra: ["cols": cols, "rows": rows])
                if plan.0 == .busy { appendRecord() }
            }
        }
        if plan.0 == .afterResponse {
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                commit()
            }
        } else {
            commit()
        }
        if plan.0 == .synchronized { await splitRedraw(epoch: plan.3, lifetime: plan.4) }
        // Geometry is already on the stream while this response is deliberately late.
        if plan.0 == .delayed { try await Task.sleep(nanoseconds: 450_000_000) }
        return Self.json(["id": request.id, "result": ["type": "pane_pty_size",
            "pane_id": paneID, "cols": effectiveCols, "rows": plan.2,
            "locked": request.params?.lock ?? false]])
    }

    func stream(_ line: String) -> AsyncThrowingStream<String, Error> {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)),
              request.method == "pane.stream", let id = request.params?.paneID else {
            return AsyncThrowingStream { $0.finish() }
        }
        if id != paneID { return pane(id).stream(line) }
        return AsyncThrowingStream { c in
            let token = UUID()
            locked {
                continuation = c; lifetime = token; opens += 1
                c.yield(Self.json(["id": request.id, "result": ["type": "stream_started",
                    "pane_id": paneID, "epoch": epoch, "cols": cols, "rows": rows,
                    "base_seq": offset, "resync": true]]))
                seed()
            }
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled, let self else { break }
                    self.locked {
                        guard self.lifetime == token else { return }
                        if self.scenario == .busy { self.appendRecord() }
                        self.emitFrame("ping")
                    }
                }
            }
            c.onTermination = { [weak self] _ in
                ticker.cancel()
                self?.locked {
                    if self?.lifetime == token { self?.continuation = nil; self?.lifetime = nil }
                }
            }
        }
    }

    private func emitFrame(_ frame: String, extra: [String: Any] = [:]) {
        var value: [String: Any] = ["stream": "pane.bytes", "frame": frame, "seq": offset, "epoch": epoch]
        value.merge(extra) { _, rhs in rhs }
        continuation?.yield(Self.json(value))
    }

    private func emitData(_ text: String) {
        let bytes = Data(text.utf8)
        emitFrame("data", extra: ["data_b64": bytes.base64EncodedString()])
        offset += UInt64(bytes.count)
    }

    private func seed() {
        var body = "\u{1b}[?25l"
        if !control {
            for n in 0..<100 {
                let marker = n == 20 ? "ANCHOR020" : String(format: "RECORD%03d", n)
                body += marker + " " + String(repeating: String(UnicodeScalar(65 + n % 26)!), count: 80) + "\r\n"
            }
        }
        if kitty { body += "\u{1b}[>9u" }
        if epoch > 7 { body += "RESET-EPOCH\(epoch)\r\n" }
        body += "fixture> " + input
        let bytes = Data(body.utf8)
        emitFrame("reset", extra: ["cols": cols, "rows": rows, "data_b64": bytes.base64EncodedString()])
        offset += UInt64(bytes.count)
    }

    private func appendRecord() {
        appended += 1
        emitData(String(format: "\r\nAPPENDED%04d unique-live-record\r\nfixture> ", appended))
    }

    private func splitRedraw(epoch expected: UInt64, lifetime token: UUID?) async {
        locked {
            guard epoch == expected, lifetime == token else { return }
            emitData("\u{1b}[?2026h\u{1b}[?1049h\u{1b}[H\u{1b}[2JINCOMPLETE-RESIZE-FRAME")
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        locked {
            guard epoch == expected, lifetime == token else { return }
            emitData("\r\nINCOMPLETE-BODY")
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        locked {
            guard epoch == expected, lifetime == token else { return }
            emitData("\u{1b}[?1049l\u{1b}[?2026l")
        }
    }

    func configure(_ next: Scenario) { locked { scenario = next } }
    func enableKitty() { locked { kitty = true; emitData("\u{1b}[>9u") } }
    func reset() { locked { epoch += 1; offset = 0; seed() } }
    func unsolicitedResize() {
        locked { cols = cols == 120 ? 80 : 120; emitFrame("resize", extra: ["cols": cols, "rows": rows]) }
    }

    private func consume(_ text: String) {
        pendingInput += text
        while !pendingInput.isEmpty {
            if pendingInput.hasPrefix("\u{1b}[") {
                let bodyStart = pendingInput.index(pendingInput.startIndex, offsetBy: 2)
                guard let end = pendingInput[bodyStart...].firstIndex(where: {
                    $0.unicodeScalars.count == 1 && (0x40...0x7e).contains($0.unicodeScalars.first!.value)
                }) else { return }
                let final = pendingInput[end]
                let event = String(pendingInput[bodyStart..<end])
                pendingInput.removeSubrange(...end)
                guard final == "u" else { continue }
                let fields = event.split(separator: ";")
                guard let code = fields.first.flatMap({ UInt32($0) }) else { continue }
                let modifiers = fields.count > 1 ? Int(fields[1].split(separator: ":")[0]) ?? 1 : 1
                if modifiers == 5 && code == 112 { kittyPrevious += 1; action(16) }
                else if modifiers == 5 && code == 110 { action(14) }
                else if modifiers == 5 && code == 99 { action(3) }
                else if modifiers == 1, let scalar = UnicodeScalar(code) { input.unicodeScalars.append(scalar) }
            } else {
                let scalar = pendingInput.unicodeScalars.removeFirst()
                if scalar.value == 16 { legacyPrevious += 1; action(16) }
                else if [14, 3, 8, 127].contains(scalar.value) { action(scalar.value) }
                else if scalar.value >= 32 { input.unicodeScalars.append(scalar) }
            }
        }
        emitData("\r\u{1b}[2Kfixture> " + input)
    }

    private func action(_ code: UInt32) {
        switch code {
        case 16: previousActions += 1; historyIndex = max(0, historyIndex - 1); input = history[historyIndex]
        case 14: nextActions += 1; historyIndex = min(2, historyIndex + 1); input = historyIndex == 2 ? "" : history[historyIndex]
        case 3: clearActions += 1; historyIndex = 2; input = ""
        case 8, 127: if !input.isEmpty { input.removeLast() }
        default: break
        }
    }

    func snapshot() -> [String: Any] {
        locked { ["effectiveCols": cols, "effectiveRows": rows, "opens": opens,
                  "requests": requests, "failures": failures, "appended": appended,
                  "previous": previousActions, "next": nextActions, "clears": clearActions,
                  "legacyPrevious": legacyPrevious, "kittyPrevious": kittyPrevious,
                  "input": input, "historyIndex": historyIndex, "offset": offset,
                  "scenario": scenario.rawValue, "epoch": epoch] }
    }
}

/// DEBUG-only bridge. The probe reads rendered cells and UIKit scroll coordinates;
/// it never reads the emulator's private resize anchor or the requested logical row.
@MainActor
final class TerminalInteractionHarness: ObservableObject {
    static let shared = TerminalInteractionHarness()
    static let navigateNotification = Notification.Name("TerminalInteractionNavigate")
    static let agents = [MockTransport.pagingAgent(kind: "RESIZE-ALFA", pane: "ix:a"),
                         MockTransport.pagingAgent(kind: "RESIZE-BRAVO", pane: "ix:b")]
    static let driver = TerminalInteractionDriver(control: ScreenshotMock.mode == .control)
    @Published private(set) var revision = 0
    private struct Surface {
        weak var view: TerminalView?
        let requestFit: (Int, Int) -> Void
        let isCovered: () -> Bool
        let isForeground: () -> Bool
        var cellSize = CGSize.zero
        var painted: [String: Any] = [:]
        var retained: [String: Any]?
    }
    private var surfaces: [String: Surface] = [:]
    private var fits: [String: (Int, Int)] = [:]
    private var activeID: String {
        surfaces.first(where: { $0.value.isForeground() })?.key ?? "ix:a"
    }
    static var enabled: Bool { ScreenshotMock.mode == .resize || ScreenshotMock.mode == .control }

    static func register(paneID: String, view: TerminalView,
                         requestFit: @escaping (Int, Int) -> Void, isCovered: @escaping () -> Bool,
                         isForeground: @escaping () -> Bool) {
        guard enabled else { return }
        shared.surfaces[paneID] = Surface(view: view, requestFit: requestFit,
                                         isCovered: isCovered, isForeground: isForeground)
    }
    static func unregister(paneID: String, view: TerminalView) {
        guard shared.surfaces[paneID]?.view === view else { return }
        shared.surfaces.removeValue(forKey: paneID)
    }
    static func fit(paneID: String, cols: Int, rows: Int) -> (Int, Int) {
        guard enabled else { return (cols, rows) }
        if shared.naturalPanes.contains(paneID) { return (cols, rows) }
        return shared.fits[paneID] ?? (ScreenshotMock.mode == .resize ? (80, 24) : (cols, rows))
    }
    static func painted(paneID: String, view: TerminalView, cellSize: CGSize, complete: Bool) {
        guard enabled, var surface = shared.surfaces[paneID], cellSize.height > 0 else { return }
        surface.cellSize = cellSize
        if surface.isCovered(), surface.retained == nil { surface.retained = surface.painted }
        if !surface.isCovered() { surface.retained = nil }
        surface.painted = shared.viewport(view, cellSize: cellSize)
        surface.painted["complete"] = complete
        shared.surfaces[paneID] = surface
        // A draw must not synchronously invalidate its SwiftUI host.
    }

    private func lineText(_ line: BufferLine, terminal: Terminal) -> String {
        (0..<line.count).map { String(terminal.getCharacter(for: line[$0])) }
            .joined().replacingOccurrences(of: "\0", with: " ")
    }
    private func viewport(_ view: TerminalView, cellSize: CGSize) -> [String: Any] {
        let terminal = view.getTerminal()
        let top = max(0, Int(floor(view.contentOffset.y / cellSize.height)))
        let start = terminal.buffer.totalLinesTrimmed
        let count = max(0, Int((view.contentSize.height / cellSize.height).rounded()))
        var markerRow = -999, markerColumn = -1, topText = "", visible: [String] = []
        var records: [Int] = [], appendedRecords: [Int] = []
        for row in 0..<count {
            guard let line = terminal.getScrollInvariantLine(row: start + row) else { break }
            let text = lineText(line, terminal: terminal)
            if text.hasPrefix("RECORD"), let number = Int(text.dropFirst(6).prefix(3)) { records.append(number) }
            if text.hasPrefix("ANCHOR020") { records.append(20) }
            if text.hasPrefix("APPENDED"), let number = Int(text.dropFirst(8).prefix(4)) { appendedRecords.append(number) }
            let clipped = String(text.prefix(max(0, Int(floor(view.bounds.width / max(1, cellSize.width))))))
            if row == top { topText = clipped }
            if row >= top && row < top + Int(ceil(view.bounds.height / cellSize.height)) { visible.append(clipped) }
            if let range = text.range(of: "ANCHOR020") {
                markerRow = row - top
                markerColumn = text.distance(from: text.startIndex, to: range.lowerBound)
            }
        }
        return ["top": topText, "visible": visible.joined(separator: "\n"),
                "markerRow": markerRow, "markerColumn": markerColumn,
                "markerText": markerRow == -999 ? "" : "ANCHOR020",
                "records": records, "appendedRecords": appendedRecords,
                "tail": view.contentOffset.y >= max(0, view.contentSize.height - view.bounds.height) - cellSize.height,
                "cols": terminal.cols, "rows": terminal.rows,
                "alternate": terminal.isCurrentBufferAlternate, "topPixelRow": top]
    }

    func probe() -> String {
        let id = activeID
        var value = Self.driver.pane(id).snapshot()
        value["pane"] = id
        if let surface = surfaces[id] {
            value.merge(surface.isCovered() ? (surface.retained ?? surface.painted) : surface.painted) { _, rhs in rhs }
            value["covered"] = surface.isCovered()
            value["focused"] = surface.view?.isFirstResponder ?? false
            value["keyDriveEnabled"] = (surface.view as? LiveTerminalView.ReadOnlyTerminalView)?.keyDriveEnabled ?? false
        }
        value["mounted"] = surfaces.count
        value["iPad"] = UIDevice.current.userInterfaceIdiom == .pad
        return TerminalInteractionDriver.json(value)
    }
    func tick() { revision += 1 }
    func grid(_ cols: Int, _ rows: Int) {
        naturalPanes.remove(activeID)
        fits[activeID] = (cols, rows)
        surfaces[activeID]?.requestFit(cols, rows)
    }
    func naturalFit() {
        // Opt this pane back into real sidebar/orientation/font fitting.
        fits[activeID] = nil
        naturalPanes.insert(activeID)
        surfaces[activeID]?.view?.setNeedsLayout()
        if let view = surfaces[activeID]?.view, view.cellSize.width > 0, view.cellSize.height > 0 {
            surfaces[activeID]?.requestFit(Int(view.bounds.width / view.cellSize.width),
                                           Int(view.bounds.height / view.cellSize.height))
        }
    }
    private var naturalPanes: Set<String> = []
    func history() {
        guard let surface = surfaces[activeID], let view = surface.view, surface.cellSize.height > 0 else { return }
        let terminal = view.getTerminal()
        let start = terminal.buffer.totalLinesTrimmed
        let count = Int((view.contentSize.height / surface.cellSize.height).rounded())
        for row in 0..<max(0, count) {
            guard let line = terminal.getScrollInvariantLine(row: start + row) else { break }
            if lineText(line, terminal: terminal).contains("ANCHOR020") { view.scrollTo(row: row); break }
        }
    }
    func perform(_ command: String) {
        let pane = Self.driver.pane(activeID)
        if let scenario = TerminalInteractionDriver.Scenario(rawValue: command) { pane.configure(scenario); return }
        switch command {
        case "80x24": grid(80, 24)
        case "120x24": grid(120, 24)
        case "80x32": grid(80, 32)
        case "bounce":
            let id = activeID
            Task { @MainActor in
                for width in [120, 80, 120] {
                    guard let surface = surfaces[id], surface.view?.window != nil else { return }
                    naturalPanes.remove(id)
                    fits[id] = (width, 24)
                    surface.requestFit(width, 24)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        case "natural": naturalFit()
        case "history": history()
        case "tail": surfaces[activeID]?.view?.scrollTo(row: Int.max)
        case "kitty": pane.enableKitty()
        case "reset": pane.reset()
        case "server": pane.unsolicitedResize()
        case "switch", "close": NotificationCenter.default.post(name: Self.navigateNotification, object: command)
        case "paste-batch":
            UIPasteboard.general.string = "paste-payload"
            surfaces[activeID]?.view?.paste(nil)
        case "batch-insert":
            surfaces[activeID]?.view?.insertText("batch-payload")
        case "ime-commit":
            surfaces[activeID]?.view?.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            surfaces[activeID]?.view?.insertText("日本")
            surfaces[activeID]?.view?.unmarkText()
        default: break
        }
    }
}

struct TerminalInteractionRoot: View {
    let control: Bool
    private let client = HerdrClient(transport: MockTransport(interactionDriver: TerminalInteractionHarness.driver))
    var body: some View {
        Group {
            if control {
                NavigationStack {
                    TerminalPaneContent(client: client, paneID: "ix:a", title: "CONTROL",
                                        agent: TerminalInteractionHarness.agents[0])
                }
            } else {
                TerminalHomeView(client: client, onDisconnect: {}, onTrustHostKey: { _ in false },
                                 livePaneIDs: ["ix:a", "ix:b"])
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { TerminalInteractionControls() }
    }
}

private struct TerminalInteractionControls: View {
    @ObservedObject private var harness = TerminalInteractionHarness.shared
    private let ticks = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    var body: some View {
            HStack {
                Menu("Fixture") {
                    ForEach(["80x24", "120x24", "80x32", "natural", "history", "tail", "kitty",
                             "reset", "server", "switch", "close", "bounce", "paste-batch", "batch-insert", "ime-commit"] + TerminalInteractionDriver.Scenario.allCases.map(\.rawValue), id: \.self) { command in
                        Button(command) { harness.perform(command) }.accessibilityIdentifier("fixture-" + command)
                    }
                }.accessibilityIdentifier("terminal-fixture-menu")
                Text("Terminal receipt").font(.system(size: 8))
                    .accessibilityIdentifier("terminal-interaction-probe")
                    .accessibilityLabel(harness.probe())
            }
            .frame(maxWidth: .infinity).background(Color.black)
        .onReceive(ticks) { _ in harness.tick() }
    }
}
#endif
