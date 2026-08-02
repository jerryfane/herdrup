// The readiness experiment specified in docs/transport-measurements.md.
//
// Three arms, each trial on a FRESH authenticated session, order randomised:
//   A  immediate — open the measured channel straight after auth
//   B  age-only  — idle 100 ms, then open the measured channel
//   C  prewarmed — open and free a sacrificial direct-streamlocal channel,
//                  then open the measured channel
//
// Measured per trial, retained raw (the earlier p50=40.7ms episode became
// unexplainable precisely because only summaries were kept):
//   t_request   — from the call opening the measured channel to the complete
//                 response line having been read
//   t_ready     — the off-request-path cost of the treatment (0 / idle / sacrificial)
//   session_age — ms between auth completing and the measured open
//   started_at  — wall-clock ms since the run began; retained so temporal
//                 imbalance between arms can be inspected, since randomisation
//                 balances drift only in expectation
//
// Errors are recorded as rows, never dropped: a censored trial that vanishes
// silently is how a tail gets underreported.
//
// This file mirrors production's libssh2 call sequence (task/1
// SSHTransport.swift) ON THE MEASURED WINDOW: blocking mode, TCP_NODELAY,
// identical direct-streamlocal open, same write loop and newline-terminated
// read. Three deviations sit BEFORE the window and are named so "mirrors the
// call sequence" cannot be read as full-path parity:
//   - auth is publickey_fromfile, production uses frommemory;
//   - no host-key verification step between handshake and auth;
//   - a 10 s per-call libssh2 timeout stays set on the measured path, where
//     production clears it to 0 after auth. Below 10 s it bounds without
//     distorting; a trial that hits it records as an error row, and error rows
//     block the decision in the analyzer.
// It is a measurement harness, not production code: no cancellation.
//
// Build:  swiftc -I Sources/CSSH -lssh2 -O -o /tmp/readiness scripts/readiness-experiment.swift
// Run:    /tmp/readiness [trials-per-arm] [output.csv]

import CSSH
import Foundation

#if canImport(Glibc)
import Glibc
#endif

// MARK: - Configuration

let trialsPerArm = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 100 : 100
let outputPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2] : "scripts/readiness-experiment-results.csv"

let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let username = NSUserName()
let privateKeyPath = "\(home)/.ssh/id_ed25519"
let publicKeyPath = "\(home)/.ssh/id_ed25519.pub"
let socketPath = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
    ?? "\(home)/.config/herdr/herdr.sock"
let sshHost = "127.0.0.1"
let sshPort: UInt16 = 22
let idleMicroseconds: useconds_t = 100_000          // arm B's treatment
let perCallTimeoutMs = 10_000                        // bounds a wedged trial; far above the 2594ms worst outlier ever observed
let pingRequest = "{\"id\":\"readiness\",\"method\":\"ping\",\"params\":{}}\n"

guard FileManager.default.fileExists(atPath: privateKeyPath) else {
    FileHandle.standardError.write(Data("no key at \(privateKeyPath)\n".utf8)); exit(2)
}
guard FileManager.default.fileExists(atPath: socketPath) else {
    FileHandle.standardError.write(Data("no herdr socket at \(socketPath)\n".utf8)); exit(2)
}
let publicKeyOrNil = FileManager.default.fileExists(atPath: publicKeyPath) ? publicKeyPath : nil

// MARK: - Timing

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

// MARK: - One trial

enum Arm: String, CaseIterable { case A, B, C }

struct TrialRow {
    let sequence: Int
    let arm: Arm
    let startedAtMs: Double        // since run start, wall-clock of the trial
    var tRequestMs: Double?
    var tReadyMs: Double?
    var sessionAgeMs: Double?
    var error: String?

    var csv: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }
        return "\(sequence),\(arm.rawValue),\(String(format: "%.1f", startedAtMs)),"
            + "\(f(tRequestMs)),\(f(tReadyMs)),\(f(sessionAgeMs)),\(error ?? "")"
    }
}

func tcpConnect() -> Int32? {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    var info: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(sshHost, String(sshPort), &hints, &info) == 0, let list = info else { return nil }
    defer { freeaddrinfo(list) }
    var candidate = Optional(list)
    while let entry = candidate {
        let fd = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
        if fd >= 0 {
            if connect(fd, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 {
                var on: Int32 = 1   // same rationale as the transport: Nagle adds a fixed ~40ms floor
                setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                return fd
            }
            close(fd)
        }
        candidate = entry.pointee.ai_next
    }
    return nil
}

/// Opens a direct-streamlocal channel to herdr's socket. Timing is the caller's job.
func openChannel(_ session: OpaquePointer) -> OpaquePointer? {
    socketPath.withCString { path in
        libssh2_channel_direct_streamlocal_ex(session, path, "localhost", 0)
    }
}

func runTrial(sequence: Int, arm: Arm, runStart: Double) -> TrialRow {
    var row = TrialRow(sequence: sequence, arm: arm, startedAtMs: nowMs() - runStart)

    guard let sock = tcpConnect() else { row.error = "tcp_connect_failed"; return row }
    defer { close(sock) }

    guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
        row.error = "session_init_failed"; return row
    }
    libssh2_session_set_blocking(session, 1)
    libssh2_session_set_timeout(session, perCallTimeoutMs)
    defer {
        libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
        libssh2_session_free(session)
    }

    guard libssh2_session_handshake(session, sock) == 0 else {
        row.error = "handshake_failed"; return row
    }
    let auth = username.withCString { user in
        libssh2_userauth_publickey_fromfile_ex(
            session, user, UInt32(strlen(user)), publicKeyOrNil, privateKeyPath, nil)
    }
    guard auth == 0 else { row.error = "auth_failed_\(auth)"; return row }
    let authenticatedAt = nowMs()

    // Treatment.
    switch arm {
    case .A:
        row.tReadyMs = 0
    case .B:
        let t0 = nowMs()
        usleep(idleMicroseconds)
        row.tReadyMs = nowMs() - t0
    case .C:
        let t0 = nowMs()
        guard let sacrificial = openChannel(session) else {
            row.error = "sacrificial_open_failed_\(libssh2_session_last_errno(session))"
            return row
        }
        libssh2_channel_free(sacrificial)
        row.tReadyMs = nowMs() - t0
    }

    // Measured request: channel open through complete response line.
    row.sessionAgeMs = nowMs() - authenticatedAt
    let requestStart = nowMs()
    guard let channel = openChannel(session) else {
        row.error = "measured_open_failed_\(libssh2_session_last_errno(session))"
        return row
    }
    defer { libssh2_channel_free(channel) }

    let payload = Array(pingRequest.utf8)
    var offset = 0
    while offset < payload.count {
        let sent = payload.withUnsafeBytes { raw -> Int in
            libssh2_channel_write_ex(
                channel, 0,
                raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                payload.count - offset)
        }
        if sent > 0 { offset += sent }
        else if sent == Int(LIBSSH2_ERROR_EAGAIN) { continue }
        else { row.error = "write_failed_\(sent)"; return row }
    }

    // The response is VALIDATED, not merely received. The first version stopped
    // at any newline and recorded success, so zero error rows proved only that
    // libssh2 delivered lines — a server error envelope, or an answer to some
    // other request, would have been counted as a successful ping.
    var received: [UInt8] = []
    var buffer = [CChar](repeating: 0, count: 16 * 1024)
    while !received.contains(UInt8(ascii: "\n")) {
        let n = buffer.withUnsafeMutableBufferPointer { p -> Int in
            libssh2_channel_read_ex(channel, 0, p.baseAddress!, p.count)
        }
        if n > 0 {
            received.append(contentsOf: buffer[0..<n].map { UInt8(bitPattern: $0) })
        } else if n == Int(LIBSSH2_ERROR_EAGAIN) {
            continue
        } else if n == 0 {
            // Production distinguishes these: a NEGATIVE return is the eof QUERY
            // failing, not an end-of-file, and folding them mislabels the cause.
            let eof = libssh2_channel_eof(channel)
            if eof > 0 { row.error = "eof_before_response"; return row }
            if eof < 0 { row.error = "eof_query_failed_\(eof)"; return row }
        } else {
            row.error = "read_failed_\(n)"; return row
        }
    }
    let elapsed = nowMs() - requestStart   // clock stops before validation

    let lineEnd = received.firstIndex(of: UInt8(ascii: "\n"))!
    let line = Data(received[..<lineEnd])
    guard
        let decoded = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        decoded["id"] as? String == "readiness"
    else { row.error = "malformed_or_mismatched_response"; return row }
    guard decoded["error"] == nil, decoded["result"] != nil else {
        row.error = "server_error_envelope"; return row
    }
    row.tRequestMs = elapsed
    return row
}

// MARK: - Run

guard libssh2_init(0) == 0 else {
    FileHandle.standardError.write(Data("libssh2_init failed\n".utf8)); exit(2)
}

// Randomised interleave of all trials. The realised order is retained in the
// CSV (sequence + started_at), so temporal imbalance is inspectable after the
// fact — randomisation balances drift only in expectation.
var order: [Arm] = Arm.allCases.flatMap { Array(repeating: $0, count: trialsPerArm) }
order.shuffle()

// Refuses to overwrite retained data. The committed results CSV is the raw
// artifact the document's retention argument rests on, and the first version of
// this file truncated it unconditionally on an argument-less rerun — destroying
// the record behind a published Results section is a git-recoverable but
// entirely silent failure. Overwriting is now an explicit choice.
if let existing = try? FileManager.default.attributesOfItem(atPath: outputPath),
   (existing[.size] as? Int ?? 0) > 0 {
    FileHandle.standardError.write(Data(
        "refusing to overwrite non-empty \(outputPath); pass an explicit output path\n".utf8))
    exit(2)
}
_ = FileManager.default.createFile(atPath: outputPath, contents: nil)
guard let out = FileHandle(forWritingAtPath: outputPath) else {
    FileHandle.standardError.write(Data("cannot open \(outputPath)\n".utf8)); exit(2)
}
out.write(Data("sequence,arm,started_at_ms,t_request_ms,t_ready_ms,session_age_ms,error\n".utf8))

let runStart = nowMs()
for (index, arm) in order.enumerated() {
    let row = runTrial(sequence: index, arm: arm, runStart: runStart)
    out.write(Data((row.csv + "\n").utf8))   // written per-row so a crash retains everything before it
    if (index + 1) % 25 == 0 {
        FileHandle.standardError.write(Data("\(index + 1)/\(order.count)\n".utf8))
    }
}
out.closeFile()
FileHandle.standardError.write(Data("done: \(order.count) trials -> \(outputPath)\n".utf8))
