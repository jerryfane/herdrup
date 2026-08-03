import XCTest
import Foundation
@testable import HerdrKit

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Decides whether the live SSH path is exercisable using signals INDEPENDENT of
/// the transport under test — a private key on disk, an sshd accepting TCP, and a
/// herdr control socket present. The point (review findings #5/#6): the skip
/// decision must not be satisfiable by the transport ITSELF throwing, or a real
/// connection-setup regression is reported as a green skip. With the environment
/// proven present up front, the tests run the transport without catching its
/// errors — so a broken transport FAILS.
enum LiveEnvironment {
    static let keyPath = "\(NSHomeDirectory())/.ssh/id_ed25519"

    static var privateKeyPEM: String? {
        try? String(contentsOfFile: keyPath, encoding: .utf8)
    }

    static var socketPath: String {
        ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? UnixSocketTransport.defaultPath()
    }

    static var herdrSocketExists: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// A raw TCP connect — independent of Citadel/the transport — proving an sshd
    /// is actually listening. Localhost accepts or refuses immediately (no SYN
    /// blackhole), so a blocking connect needs no timeout machinery.
    static func tcpReachable(host: String = "127.0.0.1", port: UInt16 = 22) -> Bool {
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// Credentials for the live localhost path, or `XCTSkip` if the environment
    /// cannot support it. After this returns, the transport is expected to work —
    /// callers must NOT swallow its errors as skips.
    static func requireLiveCredentials() throws -> SSHCredentials {
        guard let keyText = privateKeyPEM else {
            throw XCTSkip("no \(keyPath); live SSH path not exercisable here")
        }
        guard herdrSocketExists else {
            throw XCTSkip("no herdr socket at \(socketPath); live path not exercisable here")
        }
        guard tcpReachable() else {
            throw XCTSkip("no sshd on 127.0.0.1:22; live path not exercisable here")
        }
        return SSHCredentials(
            host: "127.0.0.1", port: 22, username: NSUserName(),
            privateKeyPEM: keyText, remoteSocketPath: "")
    }
}
