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

        /// Read-only inspection, for tests and diagnostics.
        public func pinned(key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return pins[key]
        }

        /// Seeds a pin. Expressed through the same atomic primitive so there is
        /// no separate write path to misuse.
        @discardableResult
        public func pin(host: String, port: UInt16 = 22, fingerprint: String) -> HostKeyDecision {
            compareAndPin(key: "\(host):\(port)", presented: fingerprint)
        }

        /// THE ONLY WRITE PATH. Structural, not merely careful: with no separate
        /// lookup-then-store API, the racy split form cannot be written at all.
        /// A concurrency test can only ever sample a race — the reviewer showed
        /// the previous one let the split form survive 492 times in 500 — so the
        /// guarantee has to come from the shape of the interface, not from a
        /// test that hopes to catch it.
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
    /// The setup budget ran out in a named phase. Distinct from a connection
    /// refusal: nothing failed, the peer simply never answered in time, and the
    /// caller may want to retry where it would not retry a refusal.
    case setupTimedOut(phase: String)
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
        case .setupTimedOut(let phase): return "SSH setup timed out during \(phase)"
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
    /// Total budget for establishing a session: resolution, connect, handshake
    /// and authentication share it, and each phase gets what the previous ones
    /// left.
    ///
    /// The default of 20s is **not** a measured value and is not offered as one.
    /// It is a liveness ceiling — the point past which a phone user is owed an
    /// error rather than a spinner — chosen to sit far above anything observed:
    /// `docs/transport-measurements.md` puts handshake plus authentication at
    /// ~39ms on loopback, with a worst recorded outlier of 2594ms. Tuning for
    /// latency belongs to the pool work, where checkout cost is measured;
    /// nothing here should be read as a tuned number.
    public let setupTimeout: TimeInterval

    public init(
        credentials: SSHCredentials,
        hostKeyPolicy: HostKeyPolicy = PinningHostKeyPolicy(),
        setupTimeout: TimeInterval = 20
    ) {
        self.credentials = credentials
        self.hostKeyPolicy = hostKeyPolicy
        self.setupTimeout = SSHTransport.representableSetupTimeout(setupTimeout)
    }

    /// Below this, millisecond truncation would turn a bound into no bound.
    public static let minimumSetupTimeout: TimeInterval = 0.001

    /// Above this, the request is a bound in name only.
    public static let maximumSetupTimeout: TimeInterval = 600

    /// Maps any `TimeInterval` onto a bound libssh2 can actually be given.
    ///
    /// Three ways a caller's number stops being a bound, all of which reached
    /// libssh2 before:
    ///
    /// - **Under 1ms** truncates to 0 milliseconds, and libssh2 documents 0 as
    ///   *no timeout* — so the smallest possible request produced the largest
    ///   possible behaviour.
    /// - **NaN** slips through `max(_:_:)` untouched, because every comparison
    ///   against NaN is false and `max` returns its first argument. `Int(nan *
    ///   1000)` then traps, so an unusable value became a crash rather than a
    ///   clamp.
    /// - **Infinity** has no `Int` representation and traps on conversion.
    ///
    /// Non-finite values clamp to the ceiling rather than disabling the bound:
    /// "wait forever" is exactly the behaviour this transport refuses to expose,
    /// since an unbounded setup occupies a worker no cancellation can reach.
    static func representableSetupTimeout(_ requested: TimeInterval) -> TimeInterval {
        guard requested.isFinite else { return maximumSetupTimeout }
        return min(max(requested, minimumSetupTimeout), maximumSetupTimeout)
    }

    /// Remaining budget in milliseconds, floored at 1.
    ///
    /// Floored because libssh2 reads 0 as *no timeout*: an exhausted budget
    /// passed through verbatim would remove the bound at precisely the moment
    /// it is most needed.
    static func milliseconds(remainingUntil deadline: Date) -> Int {
        max(Int(deadline.timeIntervalSinceNow * 1000), 1)
    }

    /// Bound on teardown, separate from setup.
    ///
    /// The session timeout is cleared to zero after authentication so an idle
    /// subscription is never truncated — but zero means *no timeout* for every
    /// blocking call, including `libssh2_channel_free`, which may wait for the
    /// peer's close message. Teardown therefore takes its own finite bound: a
    /// silent peer must not strand a worker after `roundTrip` has already
    /// resumed its caller.
    public static let teardownTimeout: TimeInterval = 2

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

    /// Name resolution running off the caller's thread, so a stalled resolver
    /// strands a throwaway thread instead of a pool worker.
    ///
    /// `getaddrinfo` has no timeout and no cancellation: once called, it returns
    /// when the resolver decides to. On a queue of four workers that is
    /// unbounded occupancy, and no interrupt can reach it — there is no
    /// descriptor to shut down yet, which is what makes this different from
    /// every other blocking call here. Running it on a detached thread lets the
    /// caller give up on a deadline; the abandoned thread frees its own result
    /// when the resolver finally answers.
    final class Resolution: @unchecked Sendable {
        enum Outcome {
            case resolved(UnsafeMutablePointer<addrinfo>)
            case failed(Int32)
            case gaveUp
        }

        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var list: UnsafeMutablePointer<addrinfo>?
        private var code: Int32 = 0
        private var abandoned = false

        init(host: String, port: UInt16) {
            let thread = Thread { [self] in
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
                var info: UnsafeMutablePointer<addrinfo>?
                let rc = getaddrinfo(host, String(port), &hints, &info)
                lock.lock()
                if abandoned {
                    lock.unlock()
                    // Nobody is waiting any more, so this thread owns the result
                    // and must free it or it leaks for the life of the process.
                    if let info { freeaddrinfo(info) }
                    return
                }
                code = rc
                list = info
                lock.unlock()
                ready.signal()
            }
            thread.name = "herdrkit.ssh.resolve"
            thread.start()
        }

        /// Waits in slices so an interrupt is noticed without sitting out the
        /// whole deadline. On success the caller owns the list and must free it.
        func claim(by deadline: Date, isInterrupted: () -> Bool) -> Outcome {
            while true {
                if isInterrupted() { abandon(); return .gaveUp }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { abandon(); return .gaveUp }
                if ready.wait(timeout: .now() + min(0.02, remaining)) == .success { break }
            }
            lock.lock(); defer { lock.unlock() }
            if let list {
                self.list = nil          // ownership transfers to the caller
                return .resolved(list)
            }
            return .failed(code)
        }

        /// Hands cleanup back to the resolver thread — or performs it here if
        /// the thread already delivered. Either order is safe because both sides
        /// check `abandoned` under the same lock, so exactly one frees.
        private func abandon() {
            lock.lock(); defer { lock.unlock() }
            abandoned = true
            if let list { freeaddrinfo(list); self.list = nil }
        }
    }

    /// Resolves and connects within `deadline`, publishing every candidate
    /// descriptor before it can block on that descriptor.
    ///
    /// The previous version could not be bounded or cancelled at all: it
    /// resolved and then called blocking `connect`, both before the socket was
    /// handed to `LiveChannel`. A SYN to a host that accepts nothing holds the
    /// worker for the kernel's retry schedule — minutes — and four of those
    /// exhaust the queue while `setupTimeout` and task cancellation both look
    /// on. Non-blocking connect plus `poll` turns that into the deadline the
    /// caller actually asked for.
    private func tcpConnect(by deadline: Date, publishingTo live: LiveChannel?) throws -> Int32 {
        let resolution = Resolution(host: credentials.host, port: credentials.port)
        let list: UnsafeMutablePointer<addrinfo>
        switch resolution.claim(by: deadline, isInterrupted: { live?.isInterrupted ?? false }) {
        case .resolved(let resolved):
            list = resolved
        case .failed:
            throw SSHError.resolveFailed(host: credentials.host)
        case .gaveUp:
            if live?.isInterrupted == true { throw CancellationError() }
            throw SSHError.setupTimedOut(phase: "resolve")
        }
        defer { freeaddrinfo(list) }

        var lastErrno: Int32 = 0
        var candidate = Optional(list)
        while let entry = candidate {
            candidate = entry.pointee.ai_next
            let fd = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
            guard fd >= 0 else { lastErrno = errno; continue }
            // Published before the first call that can block on it, so an
            // interrupt arriving mid-connect has a real descriptor to shut down.
            guard live?.adopt(rawSocket: fd) ?? true else {
                _ = Glibc_close(fd)
                throw CancellationError()
            }
            do {
                try connectCandidate(fd, entry.pointee, by: deadline, live: live)
                // SSH carries small request/response exchanges; Nagle holds a
                // small write waiting for an ACK the peer has delayed, which
                // shows up as a fixed ~40ms floor rather than as work.
                var on: Int32 = 1
                setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                return fd
            } catch {
                // This candidate is ours to clean up, so relinquish the
                // published number before closing it — otherwise `close()` closes
                // it a second time, by which point it may name another socket.
                live?.release()
                _ = Glibc_close(fd)
                guard case SSHError.connectFailed(_, _, let failure) = error else {
                    // A deadline or an interrupt ends the attempt outright: both
                    // are global, and trying the next address cannot help.
                    throw error
                }
                lastErrno = failure
            }
        }
        throw SSHError.connectFailed(host: credentials.host, port: credentials.port, errno: lastErrno)
    }

    private func connectCandidate(
        _ fd: Int32, _ entry: addrinfo, by deadline: Date, live: LiveChannel?
    ) throws {
        func failed(_ code: Int32) -> SSHError {
            .connectFailed(host: credentials.host, port: credentials.port, errno: code)
        }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw failed(errno) }

        if connect(fd, entry.ai_addr, entry.ai_addrlen) != 0 {
            let pending = errno
            guard pending == EINPROGRESS || pending == EINTR else { throw failed(pending) }
            try waitWritable(fd, by: deadline, live: live)
            // poll() reporting the socket writable says the attempt finished,
            // not that it succeeded — a refusal is also a completion. SO_ERROR
            // carries which one it was.
            var pendingError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &pendingError, &size) == 0 else {
                throw failed(errno)
            }
            guard pendingError == 0 else { throw failed(pendingError) }
        }

        // libssh2 is used in blocking mode, so hand it back a blocking
        // descriptor: non-blocking was only ever a device for bounding connect.
        guard fcntl(fd, F_SETFL, flags) == 0 else { throw failed(errno) }
    }

    /// Waits for a connect to finish, in slices, until the deadline.
    ///
    /// The interrupt check is **not** what unblocks a cancelled connect —
    /// measured, not assumed: `shutdown()` on a still-connecting socket wakes
    /// `poll` on Linux within a millisecond (`revents` = POLLOUT|POLLERR|POLLHUP,
    /// `SO_ERROR` = ECONNRESET). What the check provides is the *right error*.
    /// Without it, a cancelled connect surfaces as `connectFailed(ECONNRESET)`,
    /// indistinguishable from a peer that reset us — and a caller that retries
    /// connection failures would then retry a request the user cancelled.
    ///
    /// Sliced so the check is reached promptly even where that wakeup does not
    /// hold, rather than depending on one platform's behaviour for correctness.
    private func waitWritable(_ fd: Int32, by deadline: Date, live: LiveChannel?) throws {
        while true {
            if live?.isInterrupted == true { throw CancellationError() }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SSHError.setupTimedOut(phase: "connect") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let slice = Int32(max(min(remaining, 0.05) * 1000, 1))
            let ready = poll(&descriptor, 1, slice)
            if ready < 0 {
                if errno == EINTR { continue }
                throw SSHError.connectFailed(
                    host: credentials.host, port: credentials.port, errno: errno
                )
            }
            if ready > 0 {
                // Readiness is not necessarily a finished connect. Shutting the
                // socket down to cancel makes poll ready too, with SO_ERROR set
                // to ECONNRESET — so returning here unasked turns a cancellation
                // into a peer reset. Checking only at the top of the loop missed
                // this entirely, because the wakeup arrives inside the slice.
                if live?.isInterrupted == true { throw CancellationError() }
                return
            }
        }
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

    /// Establishes a session, publishing the raw socket to `live` BEFORE any
    /// blocking call so cancellation can interrupt establishment itself.
    ///
    /// The previous shape completed connect, handshake, host-key check and auth
    /// and only then handed the socket over — so a cancel arriving during those
    /// steps had nothing to shut down. A peer that accepts TCP and withholds its
    /// banner would hold a worker indefinitely, and four such peers exhaust the
    /// whole queue.
    func openSession(publishingTo live: LiveChannel? = nil) throws -> Session {
        try SSHRuntime.ensureStarted()
        // One budget for the whole of establishment. Each phase gets what the
        // ones before it left, so a slow resolver cannot buy the handshake a
        // fresh 20 seconds and the caller's bound means what it says.
        let deadline = Date().addingTimeInterval(setupTimeout)
        // tcpConnect publishes each candidate before it can block on it, so by
        // the time it returns, ownership is already with `live`.
        let sock = try tcpConnect(by: deadline, publishingTo: live)
        if let live, live.isInterrupted {
            live.release()
            _ = Glibc_close(sock)
            throw CancellationError()
        }
        // SO_RCVTIMEO/SO_SNDTIMEO do NOT bound libssh2 in blocking mode — a
        // reviewer measured establishment still blocked after 17s against a peer
        // that withheld its banner, so the 15s bound previously claimed here was
        // simply false. libssh2's own session timeout does bound it; it is set
        // for setup and cleared after authentication so it never truncates a
        // long-lived subscription.
        guard let handle = libssh2_session_init_ex(nil, nil, nil, nil) else {
            live?.release()
            _ = Glibc_close(sock)
            throw SSHError.sessionInitFailed
        }
        libssh2_session_set_blocking(handle, 1)

        func fail(_ error: SSHError) -> SSHError {
            libssh2_session_free(handle)
            live?.release()          // we close it here; LiveChannel must not repeat it
            _ = Glibc_close(sock)
            return error
        }

        libssh2_session_set_timeout(handle, SSHTransport.milliseconds(remainingUntil: deadline))
        let hs = libssh2_session_handshake(handle, sock)
        guard hs == 0 else { throw fail(.handshakeFailed(code: hs)) }

        do {
            try verifyHostKey(handle)
        } catch {
            libssh2_session_free(handle)
            live?.release()
            _ = Glibc_close(sock)
            throw error
        }

        // Re-armed with what is left. libssh2's timeout bounds each blocking
        // call individually, not the session's total, so leaving the handshake's
        // value in place would hand authentication a second full budget.
        libssh2_session_set_timeout(handle, SSHTransport.milliseconds(remainingUntil: deadline))
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

        // Cleared so an intentionally idle event stream is not truncated. This
        // DOES reopen unbounded blocking for channel open, write and read — the
        // reviewer confirmed it against libssh2's own documentation. That is
        // accepted deliberately: a subscription must be able to sit silent for
        // minutes, and the interrupt path (LiveChannel shutting the socket down)
        // is what bounds those operations instead of a timer.
        libssh2_session_set_timeout(handle, 0)
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
                        // A queued operation may have been cancelled while it
                        // waited for a worker; do not begin setup at all.
                        guard !live.isInterrupted else { throw CancellationError() }
                        let session = try openSession(publishingTo: live)
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
                    guard !live.isInterrupted else {
                        continuation.finish()
                        return
                    }
                    let session = try openSession(publishingTo: live)
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
final class LiveChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var session: SSHTransport.Session?
    private var channel: OpaquePointer?
    private var rawSocket: Int32 = -1
    /// Set only while `close()` tears down outside the lock, so an interrupt
    /// arriving during teardown still has something to shut down.
    private var teardownSocket: Int32 = -1
    private var closed = false

    /// Signalled as `close()` enters libssh2's teardown.
    ///
    /// Internal, and here for one reason: timing `interrupt()` against a sleep
    /// is a race, and the test that did so passed and failed on alternate runs
    /// against the same code. A semaphore needs no lock to observe, so it
    /// reports teardown has begun even in the broken shape where the lock is
    /// held throughout — which is exactly the shape the test has to distinguish.
    let teardownBegan = DispatchSemaphore(value: 0)

    /// Relinquish ownership of the published descriptor without closing it,
    /// for failure paths that close it themselves.
    ///
    /// Without this, a failure path closed the fd while LiveChannel still held
    /// the number, and close() closed it a second time — by which point the
    /// process may have reused that descriptor for an unrelated socket. A
    /// host-key rejection probe reproduced exactly that.
    func release() {
        lock.lock(); defer { lock.unlock() }
        rawSocket = -1
    }

    /// Publish a bare descriptor before a Session exists, so establishment is
    /// interruptible rather than only the read loop.
    func adopt(rawSocket fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        rawSocket = fd
        return true
    }

    func adopt(_ session: SSHTransport.Session) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        self.session = session
        rawSocket = -1     // the Session owns it from here
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
        // Any phase may be in flight: establishment (raw socket published, no
        // Session yet), the read loop (Session owns it), or teardown (detached,
        // but still worth unblocking).
        if let sock = session?.sock { _ = Glibc_shutdownSocket(sock) }
        else if rawSocket >= 0 { _ = Glibc_shutdownSocket(rawSocket) }
        else if teardownSocket >= 0 { _ = Glibc_shutdownSocket(teardownSocket) }
    }

    /// Detaches everything under the lock, then tears down outside it.
    ///
    /// Holding the mutex across teardown deadlocked the interrupt path against
    /// the very stall it exists to break: `libssh2_channel_free` and the session
    /// disconnect can wait for the peer, the post-auth timeout is zero so they
    /// wait without bound, and `interrupt()` could not take the lock to shut the
    /// socket down. A silent peer therefore held a worker after `roundTrip` had
    /// already resumed its caller.
    ///
    /// Two things fix it together, because either alone still fails:
    /// detaching frees the lock so an interrupt can land, and the finite
    /// teardown bound covers the case where no interrupt ever comes.
    func close() {
        lock.lock()
        closed = true
        let channel = self.channel
        let session = self.session
        let raw = self.rawSocket
        self.channel = nil
        self.session = nil
        self.rawSocket = -1
        // Kept shuttable-down while teardown runs unlocked: a concurrent
        // interrupt must still be able to unblock a teardown stalling on a
        // peer that has stopped answering.
        teardownSocket = session?.sock ?? raw
        lock.unlock()

        teardownBegan.signal()
        if let session {
            libssh2_session_set_timeout(
                session.handle, Int(SSHTransport.teardownTimeout * 1000)
            )
        }
        if let channel { libssh2_channel_free(channel) }
        if let session {
            session.close()
        } else if raw >= 0 {
            DescriptorAudit.close(raw)
        }

        lock.lock()
        teardownSocket = -1
        lock.unlock()
    }
}

/// Counts descriptors closed that were already closed.
///
/// A double close is otherwise invisible from a test: `close(2)` returns EBADF
/// and nothing reads it, and by the time it happens the number may already name
/// an unrelated socket — which is the actual damage, and it lands somewhere else
/// entirely. This exists because a double close shipped here once behind a test
/// whose name said it was guarded, and nothing in the suite could have noticed.
enum DescriptorAudit {
    private static let lock = NSLock()
    private static var doubleCloseCount = 0

    /// Closes, and records the close of a descriptor that was not open.
    static func close(_ fd: Int32) {
        guard Glibc_close(fd) != 0, errno == EBADF else { return }
        lock.lock(); doubleCloseCount += 1; lock.unlock()
    }

    /// Process-wide tally. Compared against a baseline rather than zero, since
    /// tests share a process.
    static var doubleCloses: Int {
        lock.lock(); defer { lock.unlock() }
        return doubleCloseCount
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
