import CSSH
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// How to reach and authenticate to a herdr host.
public struct SSHCredentials: Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    /// PEM private key bytes. Held in memory and handed to
    /// `libssh2_userauth_publickey_frommemory` — never written to disk and never
    /// referenced by path, so the key material's lifetime is the caller's to
    /// control rather than the filesystem's.
    public var privateKeyPEM: String
    /// Optional public key bytes. libssh2 derives one when absent.
    public var publicKeyPEM: String?
    public var passphrase: String?
    /// Remote unix socket to forward to, e.g. `~/.config/herdr/herdr.sock`
    /// resolved to an absolute path on the host.
    public var remoteSocketPath: String

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
        self.privateKeyPEM = privateKeyPEM
        self.publicKeyPEM = publicKeyPEM
        self.passphrase = passphrase
        self.remoteSocketPath = remoteSocketPath
    }
}

/// What the caller decides when a host key is seen.
public enum HostKeyDecision: Sendable, Equatable {
    /// Accept and remember this fingerprint.
    case trust
    /// Refuse the connection.
    case reject
}

/// Consulted on every connect. A changed key is never silently accepted: the
/// policy is asked separately for first-contact and for change, and a change
/// defaults to refusal at the call site rather than here.
public protocol HostKeyPolicy: Sendable {
    /// Decide, compare and pin as ONE operation.
    ///
    /// A split lookup-then-callback interface is a TOFU race: two concurrent
    /// first connections can both observe no pin, trust different keys, and
    /// overwrite each other — silently violating hard-stop-on-change at exactly
    /// the moment pinning is supposed to establish trust. Keyed by host AND
    /// port, since two hosts can share a name on different ports.
    func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision
}

/// Pins on first contact and hard-stops on change.
public struct PinningHostKeyPolicy: HostKeyPolicy {
    private let store: PinStore

    public init(store: PinStore = PinStore()) {
        self.store = store
    }

    /// Compare-and-pin under a single lock, so concurrent first contacts cannot
    /// both win. A key that differs from the pin is always refused: a changed
    /// host key is indistinguishable from interception, and this transport
    /// carries an operator's whole fleet.
    public func evaluate(host: String, port: UInt16, presented: String) -> HostKeyDecision {
        store.compareAndPin(key: "\(host):\(port)", presented: presented)
    }

    public func pinnedFingerprint(for host: String, port: UInt16 = 22) -> String? {
        store.pinned(key: "\(host):\(port)")
    }

    /// In-memory pin store. The iOS target substitutes a Keychain-backed one.
    public final class PinStore: @unchecked Sendable {
        private let lock = NSLock()
        private var pins: [String: String] = [:]

        public init() {}

        public func pinned(key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return pins[key]
        }

        public func pin(host: String, port: UInt16 = 22, fingerprint: String) {
            lock.lock(); defer { lock.unlock() }
            pins["\(host):\(port)"] = fingerprint
        }

        /// The whole decision inside one critical section.
        func compareAndPin(key: String, presented: String) -> HostKeyDecision {
            lock.lock(); defer { lock.unlock() }
            if let existing = pins[key] {
                return existing == presented ? .trust : .reject
            }
            pins[key] = presented
            return .trust
        }
    }
}

public enum SSHError: Error, CustomStringConvertible {
    case resolveFailed(host: String)
    case connectFailed(host: String, port: UInt16, errno: Int32)
    case sessionInitFailed
    case handshakeFailed(code: Int32)
    case hostKeyUnavailable
    case hostKeyRejected(host: String, reason: String)
    case authenticationFailed(code: Int32)
    case channelOpenFailed(socket: String, code: Int32)
    case writeFailed(code: Int32)
    case runtimeInitFailed(code: Int32)
    case readFailed(code: Int32)

    public var description: String {
        switch self {
        case .resolveFailed(let h): return "could not resolve \(h)"
        case .connectFailed(let h, let p, let e): return "connect \(h):\(p) failed (errno \(e))"
        case .sessionInitFailed: return "libssh2_session_init failed"
        case .handshakeFailed(let c): return "SSH handshake failed (\(c))"
        case .hostKeyUnavailable: return "server presented no host key"
        case .hostKeyRejected(let h, let r): return "host key rejected for \(h): \(r)"
        case .authenticationFailed(let c): return "public-key authentication failed (\(c))"
        case .channelOpenFailed(let s, let c):
            return "direct-streamlocal to \(s) failed (\(c))"
        case .writeFailed(let c): return "channel write failed (\(c))"
        case .runtimeInitFailed(let c): return "libssh2_init failed (\(c))"
        case .readFailed(let c): return "channel read failed (\(c))"
        }
    }
}

/// Carries herdr's JSON API over an SSH tunnel.
///
/// Uses `direct-streamlocal@openssh.com`, not `direct-tcpip`: only the former
/// can reach a *remote unix socket*, which is where herdr listens. That single
/// capability is why this is built on libssh2 — SwiftNIO-SSH and Citadel expose
/// direct-tcpip only.
///
/// Conforms to `HerdrTransport` so the two connection shapes stay distinct, as
/// they must: herdr's command socket answers one request and closes, while
/// `events.subscribe` holds its connection open. Each `roundTrip` and each
/// `stream` therefore opens its own SSH channel.
public struct SSHTransport: HerdrTransport {
    /// Shared, bounded pool for blocking libssh2 work. Bounded because a thread
    /// per request grows without limit under concurrency; shared because each
    /// request needs its own connection but not its own operating-system thread.
    /// Stack size is left at the platform default rather than a number picked
    /// without measuring.
    static let blockingQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "herdrkit.ssh.blocking"
        q.maxConcurrentOperationCount = 4
        return q
    }()

    public let credentials: SSHCredentials
    private let hostKeyPolicy: HostKeyPolicy

    public init(credentials: SSHCredentials, hostKeyPolicy: HostKeyPolicy = PinningHostKeyPolicy()) {
        self.credentials = credentials
        self.hostKeyPolicy = hostKeyPolicy
    }

    // MARK: - Session

    /// An authenticated session plus the socket beneath it. Both are torn down
    /// together; the caller owns the lifetime.
    final class Session {
        let sock: Int32
        let handle: OpaquePointer

        init(sock: Int32, handle: OpaquePointer) {
            self.sock = sock
            self.handle = handle
        }

        func close() {
            libssh2_session_disconnect_ex(handle, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(handle)
            _ = Glibc_close(sock)
        }
    }

    private func tcpConnect() throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(credentials.host, String(credentials.port), &hints, &info)
        guard rc == 0, let list = info else { throw SSHError.resolveFailed(host: credentials.host) }
        defer { freeaddrinfo(list) }

        var candidate = Optional(list)
        while let entry = candidate {
            let fd = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
            if fd >= 0 {
                if connect(fd, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 {
                    // SSH carries small request/response exchanges; Nagle holds a
                    // small write waiting for an ACK the peer has delayed, which
                    // shows up as a fixed ~40ms floor rather than as work.
                    var on: Int32 = 1
                    setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                    return fd
                }
                _ = Glibc_close(fd)
            }
            candidate = entry.pointee.ai_next
        }
        throw SSHError.connectFailed(host: credentials.host, port: credentials.port, errno: errno)
    }

    /// SHA-256 of the presented host key, hex, lowercase.
    private func fingerprint(_ session: OpaquePointer) throws -> String {
        guard let raw = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256) else {
            throw SSHError.hostKeyUnavailable
        }
        return (0..<32).map { String(format: "%02x", UInt8(bitPattern: raw[$0])) }.joined()
    }

    private func verifyHostKey(_ session: OpaquePointer) throws {
        let presented = try fingerprint(session)
        // One decision, one rejection path. An earlier version rejected in two
        // places, which made the first branch redundant — and a mutation of it
        // left the test green, because the second branch was doing the work.
        // Two guards for one property means neither is pinned by its test.
        // One call: the policy compares and pins atomically. A split
        // lookup-then-decide interface leaves a window where two concurrent
        // first contacts both observe no pin, trust different keys, and
        // overwrite each other — silently defeating hard-stop-on-change at the
        // exact moment pinning is meant to establish trust.
        let decision = hostKeyPolicy.evaluate(
            host: credentials.host, port: credentials.port, presented: presented
        )
        guard decision == .trust else {
            throw SSHError.hostKeyRejected(
                host: credentials.host, reason: "host key not trusted for this host:port"
            )
        }
    }

    func openSession() throws -> Session {
        try SSHRuntime.ensureStarted()
        let sock = try tcpConnect()
        guard let handle = libssh2_session_init_ex(nil, nil, nil, nil) else {
            _ = Glibc_close(sock)
            throw SSHError.sessionInitFailed
        }
        libssh2_session_set_blocking(handle, 1)

        func fail(_ error: SSHError) -> SSHError {
            libssh2_session_free(handle)
            _ = Glibc_close(sock)
            return error
        }

        let hs = libssh2_session_handshake(handle, sock)
        guard hs == 0 else { throw fail(.handshakeFailed(code: hs)) }

        do {
            try verifyHostKey(handle)
        } catch {
            libssh2_session_free(handle)
            _ = Glibc_close(sock)
            throw error
        }

        let auth = credentials.privateKeyPEM.withCString { priv -> Int32 in
            let privLen = strlen(priv)
            let run: (UnsafePointer<CChar>?, Int) -> Int32 = { pub, pubLen in
                credentials.username.withCString { user in
                    libssh2_userauth_publickey_frommemory(
                        handle, user, strlen(user),
                        pub, pubLen,
                        priv, privLen,
                        credentials.passphrase
                    )
                }
            }
            if let pub = credentials.publicKeyPEM {
                return pub.withCString { run($0, strlen($0)) }
            }
            return run(nil, 0)
        }
        guard auth == 0 else { throw fail(.authenticationFailed(code: auth)) }

        return Session(sock: sock, handle: handle)
    }

    /// Opens a direct-streamlocal channel to herdr's socket on the host.
    func openChannel(_ session: Session) throws -> OpaquePointer {
        guard let channel = credentials.remoteSocketPath.withCString({ path in
            libssh2_channel_direct_streamlocal_ex(session.handle, path, "localhost", 0)
        }) else {
            throw SSHError.channelOpenFailed(
                socket: credentials.remoteSocketPath,
                code: libssh2_session_last_errno(session.handle)
            )
        }
        return channel
    }

    // MARK: - Channel IO

    private func write(_ channel: OpaquePointer, _ line: String) throws {
        var bytes = Array(line.utf8)
        if bytes.last != UInt8(ascii: "\n") { bytes.append(UInt8(ascii: "\n")) }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                libssh2_channel_write_ex(
                    channel, 0,
                    raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                    bytes.count - offset
                )
            }
            if n > 0 {
                offset += n
            } else if n == Int(LIBSSH2_ERROR_EAGAIN) {
                continue
            } else {
                throw SSHError.writeFailed(code: Int32(n))
            }
        }
    }

    /// Reads to the next newline. Returns nil at channel EOF with nothing buffered.
    private func readLine(_ channel: OpaquePointer, carry: inout [UInt8]) throws -> String? {
        while true {
            if let idx = carry.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Array(carry[carry.startIndex..<idx])
                carry.removeSubrange(carry.startIndex...idx)
                return String(decoding: line, as: UTF8.self)
            }
            var buf = [CChar](repeating: 0, count: 16 * 1024)
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                libssh2_channel_read_ex(channel, 0, p.baseAddress!, p.count)
            }
            if n > 0 {
                carry.append(contentsOf: buf[0..<n].map { UInt8(bitPattern: $0) })
            } else if n == Int(LIBSSH2_ERROR_EAGAIN) {
                continue
            } else if n == 0 {
                // A zero-byte read is NOT proof of EOF for libssh2 — it also
                // occurs on a live channel with nothing available. Ask the
                // channel. Treating zero as EOF ended streams that were merely
                // idle, which on an event subscription is most of the time.
                // libssh2_channel_eof: 1 = EOF, 0 = not EOF, NEGATIVE = query
                // failed. Continuing only on exactly 0 meant every negative —
                // i.e. every failure — was silently treated as a clean EOF.
                let eof = libssh2_channel_eof(channel)
                if eof == 0 { continue }
                if eof < 0 { throw SSHError.readFailed(code: eof) }
                if carry.isEmpty { return nil }
                let rest = String(decoding: carry, as: UTF8.self)
                carry.removeAll()
                return rest
            } else {
                // A negative code other than EAGAIN is a failure, not a clean
                // close. Treating it as EOF turned network and protocol errors
                // into normal stream completion, so a broken connection looked
                // like a server that had finished talking.
                throw SSHError.readFailed(code: Int32(n))
            }
        }
    }

    // MARK: - HerdrTransport

    public func roundTrip(_ requestLine: String) async throws -> String {
        // Blocking work needs a real thread — Task.detached does not isolate it —
        // but a thread PER REQUEST is unbounded and uncancellable. Concurrent
        // callers would each allocate an OS thread that keeps connecting,
        // handshaking or reading long after the awaiting task is gone.
        //
        // So: a shared bounded queue, plus a cancellation handle that publishes
        // the socket so an in-flight blocking read can actually be interrupted.
        let live = LiveChannel()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                SSHTransport.blockingQueue.addOperation {
                    do {
                        let session = try openSession()
                        guard live.adopt(session) else {
                            session.close()
                            throw CancellationError()
                        }
                        defer { live.close() }
                        let channel = try openChannel(session)
                        live.adopt(channel: channel)

                        try write(channel, requestLine)
                        var carry: [UInt8] = []
                        guard let line = try readLine(channel, carry: &carry) else {
                            throw TransportError.closedBeforeResponse
                        }
                        continuation.resume(returning: line)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Shuts the socket down so a blocked read returns now, rather than
            // leaving the worker running until the peer speaks.
            live.interrupt()
        }
    }

    public func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let live = LiveChannel()
            // Same reasoning as roundTrip: a detached task is not a thread, and
            // this loop blocks for the life of the subscription.
            let work = Thread {
                do {
                    let session = try openSession()
                    guard live.adopt(session) else {
                        session.close()
                        continuation.finish()
                        return
                    }
                    let channel = try openChannel(session)
                    live.adopt(channel: channel)
                    try write(channel, requestLine)

                    var carry: [UInt8] = []
                    while !live.isInterrupted, let line = try readLine(channel, carry: &carry) {
                        continuation.yield(line)
                    }
                    live.close()
                    continuation.finish()
                } catch {
                    live.close()
                    continuation.finish(throwing: error)
                }
            }
            work.name = "herdrkit.ssh.stream"
            work.start()
            continuation.onTermination = { _ in
                // Same discipline as UnixSocketTransport: Task.cancel() cannot
                // interrupt a blocking read, so the underlying socket is shut
                // down to force it to return. Without this a cancelled
                // subscription holds its descriptor and a pool thread until the
                // server next writes — which on an idle stream may be never
                // (herdr-ios#1).
                live.interrupt()
            }
        }
    }
}

/// Owns a session and channel shared between a blocking reader and a cancelling
/// caller, so cancellation can interrupt a read that is already in progress.
private final class LiveChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var session: SSHTransport.Session?
    private var channel: OpaquePointer?
    private var closed = false

    func adopt(_ session: SSHTransport.Session) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        self.session = session
        return true
    }

    func adopt(channel: OpaquePointer) {
        lock.lock(); defer { lock.unlock() }
        self.channel = channel
    }

    /// Unblocks a pending read without freeing anything the reader still holds.
    var isInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        if let sock = session?.sock {
            _ = Glibc_shutdownSocket(sock)
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        if let channel { libssh2_channel_free(channel) }
        channel = nil
        session?.close()
        session = nil
    }
}

#if canImport(Glibc)
private func Glibc_close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
private func Glibc_shutdownSocket(_ fd: Int32) -> Int32 { Glibc.shutdown(fd, Int32(SHUT_RDWR)) }
#else
private func Glibc_close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
private func Glibc_shutdownSocket(_ fd: Int32) -> Int32 { Darwin.shutdown(fd, Int32(SHUT_RDWR)) }
#endif

/// Process-wide libssh2 init.
///
/// libssh2 requires this before any session call. It was previously only ever
/// invoked by tests while a comment claimed callers got it "for free" — a
/// documented behaviour that did not exist, so production paths ran
/// uninitialised. `openSession` now calls it, and the return code is preserved
/// rather than discarded.
public enum SSHRuntime {
    private static let lock = NSLock()
    private static var started = false
    private static var result: Int32 = 0

    /// Idempotent and thread-safe. Throws if libssh2 refused to initialise.
    public static func ensureStarted() throws {
        lock.lock(); defer { lock.unlock() }
        if !started {
            result = libssh2_init(0)
            started = true
        }
        guard result == 0 else { throw SSHError.runtimeInitFailed(code: result) }
    }

    /// Retained for callers that want to initialise eagerly.
    public static func start() { try? ensureStarted() }
}
