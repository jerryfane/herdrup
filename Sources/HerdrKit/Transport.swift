import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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

    public var description: String {
        switch self {
        case .socketCreationFailed(let e): return "socket() failed (errno \(e))"
        case .connectFailed(let p, let e): return "connect(\(p)) failed (errno \(e))"
        case .pathTooLong(let p): return "socket path too long for sockaddr_un: \(p)"
        case .writeFailed(let e): return "write failed (errno \(e))"
        case .closedBeforeResponse: return "peer closed before sending a response line"
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
