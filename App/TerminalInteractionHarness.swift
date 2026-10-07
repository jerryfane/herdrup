#if DEBUG && canImport(UIKit)
import Foundation
import GameController
import SwiftUI
import SwiftTerm
import UIKit
import HerdrKit
import UniformTypeIdentifiers

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
            var dataBase64: String?
            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case dataBase64 = "data_base64"
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
    private var receivedHex = ""
    private var scenario = Scenario.quiet
    private var kitty = false
    /// What reached the host on the attachment path — uploaded bytes, gram posts and
    /// prompts — so a receipt can prove a send delivered, not just that its chip left.
    private var uploadedBytes = 0
    private var gramPosts = 0
    private var prompts = 0
    private var lastPrompt = ""
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
            locked {
                switch request.method {
                case "gram.upload_chunk":
                    uploadedBytes += Data(base64Encoded: request.params?.dataBase64 ?? "")?.count ?? 0
                case "gram.post": gramPosts += 1
                case "agent.prompt":
                    prompts += 1
                    lastPrompt = request.params?.text ?? ""
                default: break
                }
            }
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
                // Termination runs synchronously under the consumer task's status
                // lock. It must not take mutex while a producer holds mutex in yield.
                // Let the producer own cleanup after cancellation has unwound.
                defer {
                    if let self {
                        self.locked {
                            if self.lifetime == token {
                                self.continuation = nil
                                self.lifetime = nil
                            }
                        }
                    }
                }
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
            c.onTermination = { _ in ticker.cancel() }
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
                if n == 20 && ProcessInfo.processInfo.environment["HERDR_HISTORY_BOX"] == "1" {
                    body += "\u{1b}[48;2;35;30;50m"
                    body += "╭─ ANCHOR020 " + String(repeating: "─", count: 66) + "╮\r\n"
                    body += "│" + String(repeating: " ", count: 69) + "RIGHTEND │\r\n"
                    body += "╰" + String(repeating: "─", count: 78) + "╯\u{1b}[0m\r\n"
                } else {
                    body += marker + " " + String(repeating: String(UnicodeScalar(65 + n % 26)!), count: 80) + "\r\n"
                }
            }
        }
        if kitty { body += "\u{1b}[>9u" }
        if epoch > 7 { body += "RESET-EPOCH\(epoch)\r\n" }
        body += "fixture> " + input
        let bytes = Data(body.utf8)
        emitFrame("reset", extra: ["cols": cols, "rows": rows, "data_b64": bytes.base64EncodedString()])
        offset += UInt64(bytes.count)
    }

    /// One live record, now; returns its number.
    func appendNow() -> Int { locked { appendRecord(); return appended } }

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
        // The RAW BYTES, kept for the receipt. "the key never arrived" and "the key
        // arrived encoded differently" are different defects with different fixes, and
        // from the test side they look identical without this.
        receivedHex += text.unicodeScalars.map { String(format: "%02x", $0.value) }.joined(separator: " ") + " "
        if receivedHex.count > 200 { receivedHex.removeFirst(receivedHex.count - 200) }
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

    /// The attachment-path receipt. Kept on the ROOT driver: gram and prompt calls
    /// carry no `pane_id`, so they never reach a pane's child driver.
    func hostReceipt() -> [String: Any] {
        locked { ["uploadedBytes": uploadedBytes, "gramPosts": gramPosts,
                  "prompts": prompts, "lastPrompt": lastPrompt] }
    }

    func snapshot() -> [String: Any] {
        locked { ["effectiveCols": cols, "effectiveRows": rows, "opens": opens,
                  "requests": requests, "failures": failures, "appended": appended,
                  "previous": previousActions, "next": nextActions, "clears": clearActions,
                  "legacyPrevious": legacyPrevious, "kittyPrevious": kittyPrevious,
                  "input": input, "historyIndex": historyIndex, "offset": offset,
                  "scenario": scenario.rawValue, "epoch": epoch, "bytes": receivedHex] }
    }
}

/// The fixture keyboard's height, observed by the fixture root alone so the probe's
/// ten-per-second refresh cannot re-render the pane under test.
@MainActor
final class KeyboardSpacerBox: ObservableObject {
    @Published var height: CGFloat = 0
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
    /// A stand-in for the software keyboard's share of the pane, animated like the real
    /// thing so the terminal band really sweeps through intermediate heights.
    ///
    /// ITS OWN OBSERVABLE, not a property of the harness. The fixture bar ticks
    /// `revision` ten times a second to refresh the probe label, so a root that observed
    /// the harness re-rendered the whole pane at that rate: XCUITest then could not
    /// resolve a hit point for the header's find button ("Activation point invalid") and
    /// the iPhone suite ran long enough to hit the job's 120-minute ceiling. Measured in
    /// run 35329283397.
    let spacer = KeyboardSpacerBox()
    /// Grid proposals this pane actually COMMITTED — i.e. that reached the resize
    /// pipeline rather than being coalesced away. A keyboard sweep proposes one per
    /// animation frame, so this is what tells "the sweep was taken as one event" from
    /// "every frame was taken as its own resize".
    private var commits = 0
    /// The grid of the newest committed proposal, so a receipt can assert that the one
    /// commit a sweep makes is the fit the sweep ENDED on.
    private var commitGrid: (cols: Int, rows: Int)?
    private struct Surface {
        weak var view: TerminalView?
        let requestFit: (Int, Int) -> Void
        let isCovered: () -> Bool
        let coverInstalls: () -> Int
        let lastCoverMilliseconds: () -> Int
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

    /// The file the composer's attach sheet "picks" under this harness, in place of the
    /// out-of-process document picker XCUITest cannot drive. nil outside the harness,
    /// where the real picker opens. `HERDR_MOCK_PICKED_FILE` opts any other mock (the
    /// guest pane's) into the same pick.
    static func pickedFiles() -> [URL]? {
        let optedIn = ScreenshotMock.mode != nil
            && ProcessInfo.processInfo.environment["HERDR_MOCK_PICKED_FILE"] != nil
        guard enabled || optedIn else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("picked-notes.txt")
        guard (try? Data("picked through the paperclip".utf8).write(to: url, options: .atomic)) != nil
        else { return nil }
        return [url]
    }

    static func register(paneID: String, view: TerminalView,
                         requestFit: @escaping (Int, Int) -> Void, isCovered: @escaping () -> Bool,
                         coverInstalls: @escaping () -> Int,
                         lastCoverMilliseconds: @escaping () -> Int,
                         isForeground: @escaping () -> Bool) {
        guard enabled else { return }
        shared.surfaces[paneID] = Surface(view: view, requestFit: requestFit,
                                         isCovered: isCovered, coverInstalls: coverInstalls,
                                         lastCoverMilliseconds: lastCoverMilliseconds,
                                         isForeground: isForeground)
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
    /// Recorded when a proposal is committed as a new target, AFTER coalescing.
    static func noteCommittedFit(paneID: String, cols: Int, rows: Int) {
        guard enabled else { return }
        shared.commits += 1
        shared.commitGrid = (cols: cols, rows: rows)
    }

    /// Drives a keyboard transition the way UIKit does: the notification (carrying the
    /// animation's duration, which is what the pane keys its sweep off) first, then an
    /// animated height change that really sweeps the terminal band through ~20
    /// intermediate fits.
    ///
    /// A FIXTURE, because CI's simulator exposes a hardware keyboard and will not raise
    /// the software one: the code under test is the pane's own observer, sweep and
    /// commit path, not this trigger. Real software-keyboard timing stays a device
    /// check.
    /// The reported duration is UIKit's nominal 0.25s, which is what the pane keys its
    /// sweep window off.
    func sweepKeyboard(hiding: Bool) {
        // A real iPhone keyboard is ~300pt. This is deliberately smaller so the smallest
        // simulator CI may pick still leaves the terminal a usable grid — the receipt is
        // about how many grids one animated sweep commits, not about the exact height.
        startSweepJournal()
        postKeyboard(height: hiding ? 0 : 220, hiding: hiding)
    }

    /// A keyboard notification that leaves the keyboard where it is: what UIKit posts
    /// when focus moves between the terminal and the composer with the keyboard up.
    /// The pane's size does not change.
    func nudgeKeyboard() {
        postKeyboard(height: spacer.height, hiding: spacer.height == 0)
    }

    private func postKeyboard(height target: CGFloat, hiding: Bool) {
        let duration = 0.25
        let height: CGFloat = max(target, 1)
        let screen = surfaces[activeID]?.view?.window?.bounds
            ?? CGRect(x: 0, y: 0, width: 400, height: 900)
        let end = hiding
            ? CGRect(x: 0, y: screen.height, width: screen.width, height: height)
            : CGRect(x: 0, y: screen.height - height, width: screen.width, height: height)
        let info: [AnyHashable: Any] = [
            UIResponder.keyboardAnimationDurationUserInfoKey: duration,
            UIResponder.keyboardFrameEndUserInfoKey: end]
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: info)
        if hiding {
            NotificationCenter.default.post(
                name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: info)
        }
        withAnimation(.easeInOut(duration: duration)) {
            spacer.height = hiding ? 0 : target
        }
    }
    static func painted(paneID: String, view: TerminalView, cellSize: CGSize, complete: Bool) {
        guard enabled, var surface = shared.surfaces[paneID], cellSize.height > 0 else { return }
        surface.cellSize = cellSize
        if surface.isCovered(), surface.retained == nil { surface.retained = surface.painted }
        if !surface.isCovered() { surface.retained = nil }
        surface.painted = shared.viewport(view, cellSize: cellSize)
        surface.painted["complete"] = complete
        shared.surfaces[paneID] = surface
        shared.sampleSweep()
        // A draw must not synchronously invalidate its SwiftUI host.
    }

    // MARK: on-screen sweep journal
    //
    // What the reader SEES during a keyboard sweep: the rows fully inside the pane, from
    // the live terminal wherever it is placed, or from the retained frame while one
    // covers it. Sampled every paint and every ~8ms, because the interesting window
    // (the keyboard moving, the grid not yet committed) is shorter than one XCUITest
    // probe round trip.

    private struct SweepJournal {
        let startedAt: CFTimeInterval
        let rowsBefore: Int
        var mark = ""
        var markAt: CFTimeInterval = 0
        var markSeenMs = -1
        var markSeenRows = 0
        var samples = 0
        var promptMisses = 0
        var missedScreen = ""
        var firstMissMs = -1
        var lastMissMs = -1
    }
    private var journal: SweepJournal?
    /// Bumped per sweep, so a receipt never reads the previous sweep's closed journal.
    private var journalSerial = 0
    private var journalTimer: Timer?
    /// Long enough to outlast a retained frame's ~1 s ceiling after the sweep.
    private static let journalDuration: CFTimeInterval = 1.8

    private func startSweepJournal() {
        let rows = surfaces[activeID]?.view?.getTerminal().rows ?? 0
        journal = SweepJournal(startedAt: CACurrentMediaTime(), rowsBefore: rows)
        journalSerial += 1
        journalTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { TerminalInteractionHarness.shared.sampleSweep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        journalTimer = timer
    }

    /// Appends one record to the active pane while its keyboard sweep is running.
    private func appendSweepMark() {
        guard journal != nil else { return }
        journal?.mark = String(format: "APPENDED%04d", Self.driver.pane(activeID).appendNow())
        journal?.markAt = CACurrentMediaTime()
    }

    private func sampleSweep() {
        guard var entry = journal else { return }
        let now = CACurrentMediaTime()
        guard now - entry.startedAt < Self.journalDuration else {
            // Closed: the results stay for the probe.
            journalTimer?.invalidate()
            journalTimer = nil
            return
        }
        guard let surface = surfaces[activeID], let view = surface.view else { return }
        // Only a state that could be on screen. Between a relayout and its paint (the run
        // loop can fire this timer before Core Animation commits) the frame is new and
        // the last paint is old; that pairing never reaches the display.
        if view.layer.needsLayout() || view.layer.needsDisplay()
            || view.superview?.layer.needsLayout() == true { return }
        guard let rows = screenRows(surface) else { return }
        entry.samples += 1
        if !rows.contains(where: { $0.hasPrefix("fixture>") }) {
            entry.promptMisses += 1
            let at = Int(((now - entry.startedAt) * 1000).rounded())
            if entry.firstMissMs < 0 { entry.firstMissMs = at }
            entry.lastMissMs = at
            if entry.missedScreen.isEmpty { entry.missedScreen = rows.suffix(3).joined(separator: " | ") }
        }
        if !entry.mark.isEmpty, entry.markSeenMs < 0, rows.contains(where: { $0.hasPrefix(entry.mark) }) {
            entry.markSeenMs = Int(((now - entry.markAt) * 1000).rounded())
            entry.markSeenRows = surface.view?.getTerminal().rows ?? 0
        }
        journal = entry
    }

    /// Rows fully visible inside the pane, from what was actually PAINTED: a retained
    /// frame sits at the pane's origin at its captured size (`layoutCover`), the live
    /// terminal's last paint sits wherever its frame is now.
    private func screenRows(_ surface: Surface) -> [String]? {
        guard let view = surface.view, let pane = view.superview, surface.cellSize.height > 0 else { return nil }
        let cell = surface.cellSize.height
        let covered = surface.isCovered()
        let frame = covered ? (surface.retained ?? surface.painted) : surface.painted
        let originY = covered ? 0 : view.frame.minY
        let offset = CGFloat(frame["rowOffset"] as? Double ?? 0)
        let rows = (frame["visible"] as? String ?? "").components(separatedBy: "\n")
        return rows.enumerated().compactMap { index, text in
            let top = originY + CGFloat(index) * cell - offset
            return top >= -0.5 && top + cell <= pane.bounds.height + 0.5 ? text : nil
        }
    }

    private func journalProbe() -> [String: Any] {
        guard let entry = journal else { return [:] }
        return ["sweepSerial": journalSerial, "sweepOpen": journalTimer != nil, "sweepSamples": entry.samples,
                "sweepRowsBefore": entry.rowsBefore, "sweepMark": entry.mark,
                "sweepMarkSeenMs": entry.markSeenMs, "sweepMarkSeenRows": entry.markSeenRows,
                "sweepPromptMisses": entry.promptMisses, "sweepMissedScreen": entry.missedScreen,
                "sweepMissMs": "\(entry.firstMissMs)-\(entry.lastMissMs)"]
    }

    /// The painted row as text. A DOUBLE-WIDTH glyph occupies two cells and the second
    /// carries no character, so emitting it as a space rendered a correct paint of
    /// "日本" as "日 本" and failed an IME receipt on a defect that did not exist.
    /// Null cells are dropped; a real blank is a space (0x20), never a null.
    private func lineText(_ line: BufferLine, terminal: Terminal) -> String {
        var text = ""
        for column in 0..<line.count {
            // `CharData.code` is internal to SwiftTerm; the rendered character is the
            // public view of a cell, and a null cell renders as "\0".
            let character = terminal.getCharacter(for: line[column])
            if character != "\0" { text.append(character) }
        }
        return text
    }
    private func viewport(_ view: TerminalView, cellSize: CGSize) -> [String: Any] {
        let terminal = view.getTerminal()
        let top = max(0, Int(floor(view.contentOffset.y / cellSize.height)))
        let left = max(0, Int(floor(view.contentOffset.x / cellSize.width)))
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
            let right = Int(ceil((view.contentOffset.x + view.bounds.width) / max(1, cellSize.width)))
            let clipped = String(text.dropFirst(left).prefix(max(0, right - left)))
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
                "alternate": terminal.isCurrentBufferAlternate, "topPixelRow": top,
                "logicalTopRow": terminal.buffer.yDisp, "leftPixelColumn": left,
                "offsetX": Double(view.contentOffset.x), "contentWidth": Double(view.contentSize.width),
                "viewportWidth": Double(view.bounds.width),
                "rowOffset": Double(view.contentOffset.y - CGFloat(top) * cellSize.height)]
    }

    func probe() -> String {
        let id = activeID
        var value = Self.driver.pane(id).snapshot()
        value["pane"] = id
        if let surface = surfaces[id] {
            value.merge(surface.isCovered() ? (surface.retained ?? surface.painted) : surface.painted) { _, rhs in rhs }
            value["covered"] = surface.isCovered()
            value["coverInstalls"] = surface.coverInstalls()
            value["lastCoverMs"] = surface.lastCoverMilliseconds()
            value["focused"] = surface.view?.isFirstResponder ?? false
            // Asks SwiftTerm DIRECTLY, bypassing the app's find wiring, so a failing search
            // test can say which half is broken: a non-zero total here with an empty counter
            // in the UI means the wiring, not the engine.
            if let view = surface.view {
                value["engineMatches"] = view.searchMatchSummary("RECORD").total
                // The font the view has APPLIED, so a menu receipt can tell a Text size tap
                // that landed from one that was dropped, before any grid change follows it.
                value["fontPoints"] = Double(view.font.pointSize)
            }
        }
        value["mounted"] = surfaces.count
        value["iPad"] = UIDevice.current.userInterfaceIdiom == .pad
        value["physicalKeyboard"] = GCKeyboard.coalesced != nil
        value["commits"] = commits
        value["commitCols"] = commitGrid?.cols ?? 0
        value["commitRows"] = commitGrid?.rows ?? 0
        value["keyboardSpacer"] = Int(spacer.height.rounded())
        // The fixture's own record of what the last fit command asked for, so a receipt
        // can tell a command tap that landed from one that was dropped.
        value["naturalFit"] = naturalPanes.contains(id)
        value["fixtureFit"] = fits[id].map { "\($0.0)x\($0.1)" } ?? ""
        value.merge(journalProbe()) { _, rhs in rhs }
        value.merge(Self.driver.hostReceipt()) { _, rhs in rhs }
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
        case "keyboard-show": sweepKeyboard(hiding: false)
        case "keyboard-show-live":
            // A line of output while the keyboard is still rising (the animation runs
            // 0.25 s), long before the sweep's grid can reach the PTY.
            sweepKeyboard(hiding: false)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                appendSweepMark()
            }
        case "keyboard-hide": sweepKeyboard(hiding: true)
        case "keyboard-nudge": nudgeKeyboard()
        case "native-first-key":
            if let view = surfaces[activeID]?.view {
                _ = view.becomeFirstResponder()
                view.insertText("p")
            }
        case "native-first-backspace":
            if let view = surfaces[activeID]?.view {
                _ = view.becomeFirstResponder()
                view.deleteBackward()
            }
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
        case "photo-pasteboard":
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
            UIPasteboard.general.image = renderer.image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            }
        case "reply-multiline-pasteboard":
            UIPasteboard.general.string = "pasted-one\npasted-two\npasted-three\npasted-four\npasted-tail"
        case "newline-pasteboard":
            UIPasteboard.general.string = "\n\n"
        case "file-pasteboard":
            // A PDF, because the point of the receipt is a NON-IMAGE file: it exercises the
            // composer's file branch (no UIImage anywhere in the path) and, unlike a plain
            // text payload, it is a type the composer must attach rather than insert.
            let page = CGRect(x: 0, y: 0, width: 120, height: 60)
            let pdf = UIGraphicsPDFRenderer(bounds: page).pdfData { context in
                context.beginPage()
                UIColor.black.setStroke()
                context.cgContext.stroke(page.insetBy(dx: 8, dy: 8))
            }
            UIPasteboard.general.setData(pdf, forPasteboardType: UTType.pdf.identifier)
        case "file-url-pasteboard":
            // What COPY IN FINDER OR FILES puts on the pasteboard: a file url, plus the
            // path as text. The text is the trap — deferring to it pasted the path and
            // attached nothing, which is how Command-V looked broken on Mac and iPad.
            let dropped = FileManager.default.temporaryDirectory
                .appendingPathComponent("dropped-note.txt")
            try? Data("dropped from finder".utf8).write(to: dropped, options: .atomic)
            UIPasteboard.general.items = [[
                UTType.fileURL.identifier: dropped as NSURL,
                UTType.utf8PlainText.identifier: dropped.path,
            ]]
        case "finder-document-pasteboard":
            // What a MAC FINDER COPY of a document really carries: the file url, the path
            // as text, and the document's ICON as an image. Preferring the image staged
            // the icon — a 288 KB .icns named "photo-….icns" — instead of the PDF.
            let doc = FileManager.default.temporaryDirectory
                .appendingPathComponent("quarterly-report.pdf")
            let page = CGRect(x: 0, y: 0, width: 120, height: 60)
            let pdf = UIGraphicsPDFRenderer(bounds: page).pdfData { context in
                context.beginPage()
                UIColor.black.setStroke()
                context.cgContext.stroke(page.insetBy(dx: 8, dy: 8))
            }
            try? pdf.write(to: doc, options: .atomic)
            let icon = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            UIPasteboard.general.items = [[
                UTType.fileURL.identifier: doc as NSURL,
                UTType.utf8PlainText.identifier: doc.path,
                UTType.png.identifier: icon,
            ]]
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
    /// ONLY the spacer, never the harness itself: the probe's ten-per-second tick would
    /// otherwise re-render the pane under test (see `KeyboardSpacerBox`).
    @ObservedObject private var spacer = TerminalInteractionHarness.shared.spacer
    private let client = HerdrClient(transport: MockTransport(interactionDriver: TerminalInteractionHarness.driver))
    var body: some View {
        VStack(spacing: 0) {
            TerminalInteractionControls()
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
        // The keyboard's share of the pane, animated by `sweepKeyboard`. SwiftUI's own
        // keyboard avoidance does the same thing to the same view, so the terminal band
        // really sweeps through intermediate heights here.
        .padding(.bottom, spacer.height)
        // ABOVE THE PANE, NOT AS A BOTTOM INSET.
        //
        // As a bottom safe-area inset the fixture bar ended up drawn OVER the pane's
        // own reply bar: the field measured (28, 799, 250x22) while the command grid
        // occupied roughly 748-826, so every tap on the field hit the fixture instead
        // and focus never moved. That cost two rounds and looked like a SwiftUI focus
        // bug. Stacking it above the pane leaves the reply bar and the keyboard region
        // untouched.
    }
}

/// EVERY COMMAND IS ITS OWN LAID-OUT BUTTON, not a `Menu`.
///
/// The menu cost a whole CI round: on iPad its items stayed in the accessibility tree
/// with `{{inf, inf}, {0, 0}}` frames, so `fixture-history` was findable and
/// permanently unhittable, and every resize case died on its first command. A grid of
/// real buttons has real geometry on both idioms, needs no popover presentation and no
/// scrolling, so a fixture command can never be the flaky part of a receipt.
private struct TerminalInteractionControls: View {
    @ObservedObject private var harness = TerminalInteractionHarness.shared
    private let ticks = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private static let commands =
        ["80x24", "120x24", "80x32", "natural", "history", "tail", "kitty",
         "reset", "server", "switch", "close", "bounce", "paste-batch", "photo-pasteboard",
         "reply-multiline-pasteboard", "newline-pasteboard", "file-pasteboard",
         "file-url-pasteboard", "finder-document-pasteboard",
         "batch-insert", "ime-commit", "keyboard-show", "keyboard-hide", "keyboard-nudge",
         "keyboard-show-live",
         "native-first-key", "native-first-backspace"]
        + TerminalInteractionDriver.Scenario.allCases.map(\.rawValue)

    var body: some View {
        VStack(spacing: 2) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 6), spacing: 2) {
                ForEach(Self.commands, id: \.self) { command in
                    Button(command) { harness.perform(command) }
                        .font(.system(size: 8))
                        .frame(maxWidth: .infinity, minHeight: 18)
                        .background(Color.white.opacity(0.12))
                        .accessibilityIdentifier("fixture-" + command)
                }
            }
            Text("Terminal receipt").font(.system(size: 8))
                .accessibilityIdentifier("terminal-interaction-probe")
                .accessibilityLabel(harness.probe())
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity).background(Color.black)
        .onReceive(ticks) { _ in harness.tick() }
    }
}
#endif
