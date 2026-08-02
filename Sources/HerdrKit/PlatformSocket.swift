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
let sockStream = SOCK_STREAM
#else
let sockStream = Int32(SOCK_STREAM.rawValue)
#endif
