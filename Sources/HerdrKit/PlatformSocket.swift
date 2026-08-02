#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `SOCK_STREAM`, as an `Int32`, on both platforms.
///
/// Glibc models it as an enum case, so it needs `.rawValue`; Darwin already
/// declares it as `Int32`, where `.rawValue` does not exist. Written inline as
/// `Int32(SOCK_STREAM.rawValue)` it compiled on Linux and failed on macOS —
/// one of three defects in this package that Linux could not see, so it lives
/// in one place rather than being spelled at each call site.
#if canImport(Darwin)
public let sockStream = SOCK_STREAM
#else
public let sockStream = Int32(SOCK_STREAM.rawValue)
#endif

/// `bind(2)`, reached unambiguously.
///
/// On Darwin, `XCTestCase` exposes an instance method named `bind`, so a bare
/// `bind(fd, ...)` inside a test resolves to it and fails to compile. Naming the
/// module explicitly is the fix, and it lives here beside `sockStream` because
/// it is the same problem: a C symbol whose spelling differs by platform.
public func platformBind(
    _ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t
) -> Int32 {
#if canImport(Darwin)
    return Darwin.bind(fd, addr, len)
#else
    return Glibc.bind(fd, addr, len)
#endif
}
