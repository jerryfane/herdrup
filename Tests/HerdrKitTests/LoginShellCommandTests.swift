import XCTest
import Foundation
@testable import HerdrKit

/// herdrup#276, against real shells. sshd does not exec the command the app sends:
/// it runs `<account's login shell> -c <command>`, so a fish account broke every
/// channel with exit 127 before herdr ran. This runs the exact command strings the
/// transport sends through each login shell installed here, the way sshd does, with
/// a fake `herdr` that echoes its arguments. Shells that are not installed are
/// skipped; `/bin/sh` always exists.
final class LoginShellCommandTests: XCTestCase {

    private static let candidateShells = ["sh", "bash", "dash", "zsh", "fish", "csh", "tcsh"]
    private static let binDirectories = ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

    private var scratch: URL!
    private var home: URL!
    private var emptyPath: URL!
    private var herdrPath: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("herdrkit-login-shell-\(UUID().uuidString)")
        home = scratch.appendingPathComponent("home")
        emptyPath = scratch.appendingPathComponent("empty-bin")
        herdrPath = scratch.appendingPathComponent("path-bin")
        for directory in [home!, emptyPath!, herdrPath!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testEveryCommandRunsHerdrUnderEveryInstalledLoginShell() throws {
        let shells = Self.installedShells()
        print("LoginShellCommandTests: running under \(shells.map(\.path))")

        let agentList = #"{"id":"1","method":"agent.list","params":{}}"#
        // Near the size limit: the whole command is one argv element to the shell.
        let large = String(repeating: #"{"text":"it's \"q\" \\ !x $(id)\n"}"#, count: 2_560)
        let largeCommand = try CitadelTransport.bridgeCommand(for: large)
        XCTAssertGreaterThan(largeCommand.utf8.count, CitadelTransport.maxCommandBytes - 2_000,
                             "the large case no longer exercises a near-limit command")
        let profileID = "0123456789abcdef0123456789abcdef"
        let cases: [(name: String, command: String, argv: [String])] = [
            ("agent.list", try CitadelTransport.bridgeCommand(for: agentList),
             ["api-bridge", CitadelTransport.encodedRequest(for: agentList)]),
            ("near-limit request", largeCommand,
             ["api-bridge", CitadelTransport.encodedRequest(for: large)]),
            ("duplex upload", CitadelTransport.herdrCommand(["api-bridge", "--duplex"]),
             ["api-bridge", "--duplex"]),
            ("machine federate", CitadelTransport.herdrCommand(["machine", "federate", profileID]),
             ["machine", "federate", profileID]),
        ]

        // Default install location only: PATH has no herdr (non-login SSH shells lack ~/.local/bin).
        try installFakeHerdr(in: home.appendingPathComponent(".local/bin"), tag: "fallback")
        for shell in shells {
            for (name, command, argv) in cases {
                let result = try run(shell, command, path: emptyPath)
                XCTAssertEqual(result.status, 0, "\(shell.name), \(name): exit \(result.status); stderr: \(result.stderr)")
                XCTAssertEqual(result.stdout, Self.echo(tag: "fallback", argv),
                               "\(shell.name), \(name): ~/.local/bin/herdr did not receive the arguments intact")
            }
        }

        // herdr on PATH wins over the fallback.
        try installFakeHerdr(in: herdrPath, tag: "path")
        for shell in shells {
            let (name, command, argv) = cases[0]
            let result = try run(shell, command, path: herdrPath)
            XCTAssertEqual(result.status, 0, "\(shell.name), \(name): exit \(result.status); stderr: \(result.stderr)")
            XCTAssertEqual(result.stdout, Self.echo(tag: "path", argv),
                           "\(shell.name): herdr on PATH was not preferred over ~/.local/bin")
        }

        // Neither: the sentinel and exit 127, which the client classifies as not installed.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".local/bin/herdr"))
        for shell in shells {
            let result = try run(shell, cases[0].command, path: emptyPath)
            XCTAssertEqual(result.status, 127, "\(shell.name): exit \(result.status); stderr: \(result.stderr)")
            XCTAssertEqual(result.stdout, "", "\(shell.name): produced stdout without herdr")
            let error = CitadelTransport.classifyBridgeFailure(
                stderr: result.stderr, exitCode: Int(result.status), host: "box.example")
            guard case TransportError.herdrNotInstalled = error else {
                XCTFail("\(shell.name): absent herdr classified as \(error)")
                continue
            }
        }
    }

    // MARK: - helpers

    private struct Shell { let name: String; let path: String }
    private struct Result { let status: Int32; let stdout: String; let stderr: String }

    private static func installedShells() -> [Shell] {
        candidateShells.compactMap { name in
            binDirectories.lazy
                .map { "\($0)/\(name)" }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
                .map { Shell(name: name, path: $0) }
        }
    }

    /// What the fake herdr prints: its tag, then each argument on its own line.
    private static func echo(tag: String, _ argv: [String]) -> String {
        ([tag] + argv.map { "<\($0)>" }).map { $0 + "\n" }.joined()
    }

    private func installFakeHerdr(in directory: URL, tag: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let herdr = directory.appendingPathComponent("herdr")
        let script = "#!/bin/sh\necho \(tag)\nfor argument in \"$@\"; do printf '<%s>\\n' \"$argument\"; done\n"
        try script.write(to: herdr, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)
    }

    /// `<shell> -c <command>`, as sshd runs an exec request. Output goes to files, not
    /// pipes, so a large write on either stream cannot block the child.
    private func run(_ shell: Shell, _ command: String, path: URL) throws -> Result {
        let stdoutURL = scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        for url in [stdoutURL, stderrURL] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.path)
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": path.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
            stderr: try String(contentsOf: stderrURL, encoding: .utf8))
    }
}
