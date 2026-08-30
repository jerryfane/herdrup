import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// How to reach and authenticate to a herdr host.
///
/// Transport-agnostic — moved here from SSHTransport.swift when the libssh2
/// transport was removed, since `CitadelTransport` authenticates from exactly
/// the same credentials.
public struct SSHCredentials: Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    /// How to authenticate to the host. Either method's secret is held in memory
    /// and handed to the SSH stack directly — never written to disk, never
    /// referenced by path — so its lifetime is the caller's, not the filesystem's.
    public var auth: Auth
    /// Vestigial under the pure-Swift transport: the server-side `api-bridge`
    /// resolves the API socket itself, so `CitadelTransport` ignores this. Kept
    /// so existing call sites compile; pruning it is a follow-up.
    public var remoteSocketPath: String

    /// The two SSH auth methods herdr offers. `Equatable` for tests; the secrets
    /// live only here and in the Keychain on the client.
    public enum Auth: Sendable, Equatable {
        /// PEM private key bytes, plus an optional passphrase for an encrypted key.
        case privateKey(pem: String, passphrase: String?)
        /// A plaintext password, offered to the server's password authentication.
        case password(String)
    }

    /// Key-based auth. Signature preserved so existing call sites are unchanged;
    /// `publicKeyPEM` is accepted and ignored (nio-ssh derives it from the key).
    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        privateKeyPEM: String,
        publicKeyPEM: String? = nil,
        passphrase: String? = nil,
        remoteSocketPath: String
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = .privateKey(pem: privateKeyPEM, passphrase: passphrase)
        self.remoteSocketPath = remoteSocketPath
    }

    /// Password-based auth. Disambiguated from the key init by the `password:` label.
    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        password: String,
        remoteSocketPath: String
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = .password(password)
        self.remoteSocketPath = remoteSocketPath
    }
}

/// How a request reaches a herdr server.
///
/// The two methods are not stylistic variants — they encode a measured property
/// of the herdr control socket, verified against a live server (build d293951f):
///
/// - The command socket is **single-shot**. The server writes one response line
///   and closes (`src/api/server.rs:706-707`). A second request on the same
///   connection fails with EPIPE. So every command is its own connection.
/// - `events.subscribe` is **persistent**. It answers `subscription_started`
///   and then holds the connection open, streaming event lines.
///
/// Keeping these separate at the type level stops callers from assuming a
/// long-lived command channel that does not exist.
public protocol HerdrTransport: Sendable {
    /// Opens a connection, writes one request line, reads one response line, closes.
    func roundTrip(_ requestLine: String) async throws -> String

    /// Opens a connection, writes one request line, and streams response lines
    /// until the peer closes or the task is cancelled.
    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error>
}

public enum TransportError: Error, CustomStringConvertible {
    case socketCreationFailed(errno: Int32)
    case connectFailed(path: String, errno: Int32)
    case pathTooLong(String)
    case writeFailed(errno: Int32)
    case closedBeforeResponse
    /// The request, once base64'd into the `herdr api-bridge <arg>` command
    /// line, would exceed the kernel's per-arg limit (MAX_ARG_STRLEN) and be
    /// rejected by execve with E2BIG BEFORE the bridge runs — so it is refused
    /// here, where a caller can see it, rather than failing opaquely on the host.
    case requestTooLarge(bytes: Int, max: Int)
    /// The server's host key did not match the pinned key (or a first-contact
    /// pin was refused). Transport-agnostic — the pure-Swift transport fails the
    /// SSH handshake with this before any auth or command runs.
    case hostKeyRejected(host: String, fingerprint: String)
    /// The api-bridge (or the remote shell) produced no reply on stdout but wrote
    /// to stderr — surfaced rather than handed back as an empty, undecodable line.
    case bridgeFailed(stderr: String)
    /// herdr is not installed on the host: neither on `PATH` nor at the default
    /// `~/.local/bin/herdr`, so the api-bridge command line has no executable to
    /// run. Distinguished from a generic `bridgeFailed` by an explicit sentinel the
    /// exec wrapper emits (not by matching the shell's locale-specific "not found"
    /// text), so the client can guide the user to install it rather than showing a
    /// raw stderr line.
    case herdrNotInstalled(host: String)
    /// herdr IS installed on the host, but it does not understand the `api-bridge`
    /// subcommand the app drives — an upstream/official build, or a fork too old to
    /// have it. Its arg-parser exits with code 2, which `classifyBridgeFailure` maps
    /// here so the client can say "update / install the fork" rather than showing a
    /// raw "command failed, exit code 2".
    case herdrIncompatible(host: String)
    /// A password connection was attempted against a server that does not offer
    /// password authentication (e.g. `PasswordAuthentication no`). Distinct from a
    /// wrong password and from a host-key mismatch.
    case passwordAuthUnsupported(host: String)
    /// The server rejected the credentials — a wrong password, or a key it would
    /// not accept.
    case authenticationFailed(host: String)
    /// The connection did not complete within the budget. `onTailnet` is true when
    /// the destination is a Tailscale address, which makes the cause almost certain
    /// and the remedy specific — so it gets its own sentence rather than a generic
    /// "couldn't connect".
    ///
    /// Without a budget this failure had no error at all: an unroutable address
    /// hangs at the TCP layer until the OS gives up (~75s on iOS), which the user
    /// experiences as an endless spinner rather than as a failure.
    case connectTimedOut(host: String, onTailnet: Bool)

    public var description: String {
        switch self {
        case .socketCreationFailed(let e): return "socket() failed (errno \(e))"
        case .connectFailed(let p, let e): return "connect(\(p)) failed (errno \(e))"
        case .pathTooLong(let p): return "socket path too long for sockaddr_un: \(p)"
        case .writeFailed(let e): return "write failed (errno \(e))"
        case .closedBeforeResponse: return "peer closed before sending a response line"
        case .requestTooLarge(let b, let m):
            return "request too large for the argument transport: \(b) > \(m) command bytes"
        case .hostKeyRejected(let h, let fp):
            return "host key for \(h) rejected: \(fp) does not match the pinned key"
        case .bridgeFailed(let stderr):
            return "api-bridge produced no reply; stderr: \(stderr)"
        case .herdrNotInstalled(let h):
            return "herdr is not installed on \(h)"
        case .herdrIncompatible(let h):
            return "the herdr on \(h) is too old or isn't the fork. Update it (or install the fork) and reconnect"
        case .passwordAuthUnsupported(let h):
            return "\(h) does not offer password authentication; use a key instead"
        case .authenticationFailed(let h):
            return "authentication to \(h) failed. Check the password or key"
        case .connectTimedOut(let h, let onTailnet):
            // The tailnet wording names the remedy, because on a Tailscale address
            // "not on the tailnet" is overwhelmingly the cause and the user can fix
            // it in one step. The generic wording deliberately does NOT guess.
            return onTailnet
                ? "\(h) is on Tailscale. Your device needs to be on the same tailnet — "
                    + "open Tailscale and connect, then try again."
                : "couldn't reach \(h) in time. It may be offline, or on a network "
                    + "this device cannot see."
        }
    }
}

/// Talks to a herdr control socket over AF_UNIX.
///
/// On device this is not used directly — the SSH transport forwards to the same
/// socket via `direct-streamlocal@openssh.com`. It exists so the protocol layer
/// can be tested against a real server without an SSH hop in the way.
public struct UnixSocketTransport: HerdrTransport {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Default control socket location used by a herdr server.
    public static func defaultPath(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? "/root"
    ) -> String {
        "\(home)/.config/herdr/herdr.sock"
    }

    private func connectFD() throws -> Int32 {
        let fd = socket(AF_UNIX, sockStream, 0)
        guard fd >= 0 else { throw TransportError.socketCreationFailed(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < capacity else {
            close(fd)
            throw TransportError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw TransportError.connectFailed(path: path, errno: e)
        }
        return fd
    }

    private func writeLine(_ fd: Int32, _ line: String) throws {
        var bytes = Array(line.utf8)
        if bytes.last != UInt8(ascii: "\n") { bytes.append(UInt8(ascii: "\n")) }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                throw TransportError.writeFailed(errno: errno)
            }
        }
    }

    /// Reads bytes until a newline. Returns nil once the peer closes with nothing buffered.
    private func readLine(_ fd: Int32, carry: inout [UInt8]) -> String? {
        while true {
            if let idx = carry.firstIndex(of: UInt8(ascii: "\n")) {
                let lineBytes = Array(carry[carry.startIndex..<idx])
                carry.removeSubrange(carry.startIndex...idx)
                return String(decoding: lineBytes, as: UTF8.self)
            }
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                carry.append(contentsOf: buf[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                if carry.isEmpty { return nil }
                let rest = String(decoding: carry, as: UTF8.self)
                carry.removeAll()
                return rest
            }
        }
    }

    public func roundTrip(_ requestLine: String) async throws -> String {
        let fd = try connectFD()
        defer { close(fd) }
        try writeLine(fd, requestLine)
        var carry: [UInt8] = []
        guard let line = readLine(fd, carry: &carry) else {
            throw TransportError.closedBeforeResponse
        }
        return line
    }

    public func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let socket = SharedSocket()
            let work = Task.detached {
                do {
                    let fd = try connectFD()
                    // Publish before the first read so cancellation arriving
                    // mid-connect still finds a descriptor to interrupt.
                    guard socket.adopt(fd) else {
                        close(fd)
                        continuation.finish()
                        return
                    }
                    try writeLine(fd, requestLine)
                    var carry: [UInt8] = []
                    while !Task.isCancelled, let line = readLine(fd, carry: &carry) {
                        continuation.yield(line)
                    }
                    socket.close()
                    continuation.finish()
                } catch {
                    socket.close()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                // Task.cancel() only sets a flag; it cannot interrupt a blocking
                // read(2). Shutting the socket down forces that read to return
                // now, so the loop exits instead of holding a descriptor and a
                // cooperative-pool thread until the server next writes — which,
                // on an idle events.subscribe stream, may be never.
                socket.shutdown()
                work.cancel()
            }
        }
    }
}

/// Owns a descriptor shared between a blocking reader and a cancelling caller.
///
/// `shutdown` is what unblocks the reader; `close` releases the descriptor.
/// Both are guarded so a shutdown racing a normal close cannot double-close a
/// descriptor number the process may have already reused.
private final class SharedSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var closed = false

    /// Takes ownership. Returns false if teardown already happened, in which
    /// case the caller must close the descriptor itself.
    func adopt(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        fd = descriptor
        return true
    }

    /// Interrupts a pending read without releasing the descriptor, so the reader
    /// observes EOF and unwinds through its normal path.
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        if fd >= 0 {
            _ = Glibc_shutdown(fd)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        if fd >= 0 {
            _ = Foundation_close(fd)
            fd = -1
        }
    }
}

#if canImport(Glibc)
private func Glibc_shutdown(_ fd: Int32) -> Int32 { Glibc.shutdown(fd, Int32(SHUT_RDWR)) }
private func Foundation_close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
#else
private func Glibc_shutdown(_ fd: Int32) -> Int32 { Darwin.shutdown(fd, Int32(SHUT_RDWR)) }
private func Foundation_close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#endif
