import Foundation
import XCTest
@testable import HerdrKit

/// Starting an agent on a freshly split pane waits for the shell the way herdr's CLI does
/// (herdrup#435; herdr src/cli/agent.rs `agent start` readiness loop): `agent_pane_busy` is
/// retried every 100 ms for 2 s while `pane.process_info` shows the shell still leading the
/// foreground group, and never otherwise. Runs on a fake clock, so no test sleeps.
final class AgentStartShellReadinessTests: XCTestCase {

    /// Answers each request by method, and counts the calls per method.
    private final class ScriptedTransport: HerdrTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var methods: [String] = []
        private var lines: [String] = []
        let answer: (_ method: String, _ callIndex: Int) -> String

        init(answer: @escaping (_ method: String, _ callIndex: Int) -> String) {
            self.answer = answer
        }

        func calls(_ method: String) -> Int { lock.withLock { methods.filter { $0 == method }.count } }
        var requestLines: [String] { lock.withLock { lines } }

        func roundTrip(_ requestLine: String) async throws -> String {
            let object = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any]
            let method = object?["method"] as? String ?? ""
            let index = lock.withLock { () -> Int in
                methods.append(method)
                lines.append(requestLine)
                return methods.filter { $0 == method }.count - 1
            }
            return answer(method, index)
        }

        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// A clock that only moves when the loop sleeps; records every sleep.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private let origin = ContinuousClock.now
        private var elapsedStorage: Duration = .zero
        private var sleepsStorage: [Duration] = []
        var elapsed: Duration { lock.withLock { elapsedStorage } }
        var sleeps: [Duration] { lock.withLock { sleepsStorage } }

        var timing: HerdrClient.ShellReadinessTiming {
            HerdrClient.ShellReadinessTiming(
                now: { [self] in origin + elapsed },
                sleep: { [self] duration in
                    lock.withLock {
                        elapsedStorage += duration
                        sleepsStorage.append(duration)
                    }
                })
        }
    }

    private static let started = #"{"id":"x","result":{"type":"agent_started","agent":{"pane_id":"w1:p9","name":"fix-tests","agent":"codex","agent_status":"working"},"argv":["codex"]}}"#
    private static let busy = #"{"id":"x","error":{"code":"agent_pane_busy","message":"agent target pane w1:p9 is not an available shell"}}"#

    /// The shell (pid 100) leads the foreground group while an rc-file child shares it —
    /// what a shell still sourcing its startup files looks like.
    private static let initializing = #"{"id":"x","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p9","shell_pid":100,"foreground_process_group_id":100,"tty":"/dev/pts/3","foreground_processes":[{"pid":100,"name":"-zsh","argv":["-zsh"]},{"pid":101,"name":"git","argv":["git","status"]}]}}}"#

    /// A job-controlled foreground process (its own group) owns the terminal.
    private static let foregroundJob = #"{"id":"x","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p9","shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"vim","argv":["vim","notes.md"]}]}}}"#

    /// What an older herdr's request deserializer answers for a method it lacks.
    private static let unknownMethod = #"{"id":"unknown","error":{"code":"invalid_request","message":"invalid request: unknown variant `pane.process_info`, expected one of `ping`, `agent.start`"}}"#

    private func start(_ transport: ScriptedTransport, _ clock: FakeClock) async throws -> AgentInfo {
        try await HerdrClient(transport: transport).startAgentWhenShellReady(
            name: "fix-tests", kind: "codex", paneID: "w1:p9", timing: clock.timing)
    }

    private func assertThrowsAPIError(
        code: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> AgentInfo
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("expected APIError \(code), got \(error)", file: file, line: line)
        }
    }

    // (a) The shell is still starting for the first two attempts, then takes the agent.
    func testBusyWhileShellInitializesIsRetriedUntilTheStartSucceeds() async throws {
        let transport = ScriptedTransport { method, index in
            switch method {
            case "agent.start": return index < 2 ? Self.busy : Self.started
            case "pane.process_info": return Self.initializing
            default: return #"{"id":"x","result":{}}"#
            }
        }
        let clock = FakeClock()

        let agent = try await start(transport, clock)

        XCTAssertEqual(agent.paneID, "w1:p9")
        XCTAssertEqual(transport.calls("agent.start"), 3)
        XCTAssertEqual(clock.sleeps, [.milliseconds(100), .milliseconds(100)],
                       "each retry waits one 100 ms poll interval")
        // Like the CLI: checked once after each busy answer and again before each retry.
        XCTAssertEqual(transport.calls("pane.process_info"), 4)
    }

    // (b) Another process owns the foreground: waiting cannot free the pane.
    func testGenuinelyBusyPaneIsNotRetried() async {
        let transport = ScriptedTransport { method, _ in
            method == "pane.process_info" ? Self.foregroundJob : Self.busy
        }
        let clock = FakeClock()

        await assertThrowsAPIError(code: "agent_pane_busy") { try await self.start(transport, clock) }

        XCTAssertEqual(transport.calls("agent.start"), 1)
        XCTAssertEqual(transport.calls("pane.process_info"), 1)
        XCTAssertEqual(clock.sleeps, [])
    }

    // (c) A shell that never finishes starting gets exactly the 2 s window, then the error.
    func testShellStillInitializingAfterTheWindowSurfacesTheBusyError() async {
        let transport = ScriptedTransport { method, _ in
            method == "pane.process_info" ? Self.initializing : Self.busy
        }
        let clock = FakeClock()

        await assertThrowsAPIError(code: "agent_pane_busy") { try await self.start(transport, clock) }

        // Attempts at t = 0, 0.1, …, 1.9 s; at t = 2 s the window is spent.
        XCTAssertEqual(transport.calls("agent.start"), 20)
        XCTAssertEqual(clock.elapsed, .seconds(2))
        XCTAssertTrue(clock.sleeps.allSatisfy { $0 <= .milliseconds(100) })
    }

    // (d) An older herdr without pane.process_info: plain retries in the same window, and the
    // unsupported method is asked about only once.
    func testOlderHerdrWithoutProcessInfoFallsBackToPlainRetries() async throws {
        let transport = ScriptedTransport { method, index in
            switch method {
            case "agent.start": return index < 2 ? Self.busy : Self.started
            case "pane.process_info": return Self.unknownMethod
            default: return #"{"id":"x","result":{}}"#
            }
        }
        let clock = FakeClock()

        let agent = try await start(transport, clock)

        XCTAssertEqual(agent.paneID, "w1:p9")
        XCTAssertEqual(transport.calls("agent.start"), 3)
        XCTAssertEqual(transport.calls("pane.process_info"), 1)
        XCTAssertEqual(clock.sleeps, [.milliseconds(100), .milliseconds(100)])
    }

    // (d') The fallback is bounded by the same 2 s window.
    func testOlderHerdrPlainRetriesStopWhenTheWindowEnds() async {
        let transport = ScriptedTransport { method, _ in
            method == "pane.process_info" ? Self.unknownMethod : Self.busy
        }
        let clock = FakeClock()

        await assertThrowsAPIError(code: "agent_pane_busy") { try await self.start(transport, clock) }

        XCTAssertEqual(transport.calls("agent.start"), 20)
        XCTAssertEqual(clock.elapsed, .seconds(2))
    }

    // (e) Any error other than agent_pane_busy is thrown at once, without probing the pane.
    func testNonBusyErrorsAreNotRetried() async {
        let transport = ScriptedTransport { method, _ in
            method == "pane.process_info"
                ? Self.initializing
                : #"{"id":"x","error":{"code":"agent_name_taken","message":"agent name fix-tests is already in use"}}"#
        }
        let clock = FakeClock()

        await assertThrowsAPIError(code: "agent_name_taken") { try await self.start(transport, clock) }

        XCTAssertEqual(transport.calls("agent.start"), 1)
        XCTAssertEqual(transport.calls("pane.process_info"), 0)
        XCTAssertEqual(clock.sleeps, [])
    }

    // MARK: pane.process_info decoding and the CLI's initialization rule

    func testProcessInfoRequestAndDecodeMatchHerdrSchema() async throws {
        let transport = ScriptedTransport { _, _ in Self.initializing }
        let info = try await HerdrClient(transport: transport).paneProcessInfo(paneID: "w1:p9")

        XCTAssertEqual(transport.calls("pane.process_info"), 1)
        XCTAssertTrue(transport.requestLines[0].contains(#""params":{"pane_id":"w1:p9"}"#),
                      "PaneProcessInfoParams is { pane_id }: \(transport.requestLines[0])")
        XCTAssertEqual(info.paneID, "w1:p9")
        XCTAssertEqual(info.shellPID, 100)
        XCTAssertEqual(info.foregroundProcessGroupID, 100)
        XCTAssertEqual(info.tty, "/dev/pts/3")
        XCTAssertEqual(info.foregroundProcesses.map(\.pid), [100, 101])
        XCTAssertEqual(info.foregroundProcesses.last?.argv, ["git", "status"])
        XCTAssertTrue(info.showsShellInitialization)
    }

    func testShellInitializationRuleMirrorsTheCLI() throws {
        func info(_ json: String) throws -> PaneProcessInfo {
            try JSONDecoder().decode(PaneProcessInfo.self, from: Data(json.utf8))
        }
        // Idle shell alone in its group: still "initializing" by the CLI's rule, so the
        // retry proceeds and the server's own lone-shell check decides.
        XCTAssertTrue(try info(#"{"pane_id":"p","shell_pid":7,"foreground_process_group_id":7,"foreground_processes":[{"pid":7,"name":"/bin/bash"}]}"#).showsShellInitialization)
        // Name unrecognised but argv[0] is a shell (`.exe` and case normalised).
        XCTAssertTrue(try info(#"{"pane_id":"p","shell_pid":7,"foreground_process_group_id":7,"foreground_processes":[{"pid":7,"name":"login","argv":["C:\\Tools\\PWSH.exe"]}]}"#).showsShellInitialization)
        // Shell pid not among the foreground processes.
        XCTAssertFalse(try info(#"{"pane_id":"p","shell_pid":7,"foreground_process_group_id":7,"foreground_processes":[{"pid":8,"name":"zsh"}]}"#).showsShellInitialization)
        // Not a shell.
        XCTAssertFalse(try info(#"{"pane_id":"p","shell_pid":7,"foreground_process_group_id":7,"foreground_processes":[{"pid":7,"name":"codex"}]}"#).showsShellInitialization)
        // No foreground group exposed (herdr on Windows) and no processes at all.
        XCTAssertFalse(try info(#"{"pane_id":"p","shell_pid":7}"#).showsShellInitialization)
    }
}
