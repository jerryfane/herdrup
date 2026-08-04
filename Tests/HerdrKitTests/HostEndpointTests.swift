import XCTest
@testable import HerdrKit

final class HostEndpointTests: XCTestCase {

    // MARK: - the valid shapes

    func testPlainHostDefaultsTo22() {
        XCTAssertEqual(HostEndpoint.parse("mac.tail-scale.ts.net"), HostEndpoint(host: "mac.tail-scale.ts.net", port: 22))
    }

    func testHostColonPort() {
        XCTAssertEqual(HostEndpoint.parse("host:2222"), HostEndpoint(host: "host", port: 2222))
    }

    func testBracketedIPv6WithPort() {
        XCTAssertEqual(HostEndpoint.parse("[::1]:22"), HostEndpoint(host: "::1", port: 22))
    }

    func testBracketedIPv6WithoutPortDefaults() {
        XCTAssertEqual(HostEndpoint.parse("[fe80::1]"), HostEndpoint(host: "fe80::1", port: 22))
    }

    /// AXIS: a bare IPv6 literal (many colons, no brackets) is NOT split into
    /// host:port — the whole thing is the host on the default port.
    func testBareIPv6StaysWhole() {
        XCTAssertEqual(HostEndpoint.parse("::1"), HostEndpoint(host: "::1", port: 22))
        XCTAssertEqual(HostEndpoint.parse("fe80::1"), HostEndpoint(host: "fe80::1", port: 22))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(HostEndpoint.parse("  host:2222 \n"), HostEndpoint(host: "host", port: 2222))
    }

    // MARK: - the fail-OPEN class the reviewers found

    /// AXIS: an EXPLICIT but invalid port is REJECTED, never silently defaulted
    /// to 22. Before the fix the bracketed branch returned the valid inner host on
    /// port 22 for every one of these, connecting to a port the user never typed
    /// and TOFU-pinning whatever answered there. Each case must now be nil.
    func testBracketedInvalidPortIsRejectedNotDefaulted() {
        for bad in ["[fe80::1]:80222",   // > 65535 (UInt16 overflow)
                    "[fe80::1]:0",        // port 0
                    "[fe80::1]:notaport", // non-numeric
                    "[fe80::1]:",         // empty port
                    "[fe80::1]garbage"] { // junk after the bracket, no colon
            XCTAssertNil(HostEndpoint.parse(bad),
                         "\(bad) should be rejected, not silently connected to :22")
        }
    }

    /// The unbracketed branch must fail the SAME way — an explicit bad port is a
    /// rejection, so the two branches agree (they disagreed before the fix).
    func testUnbracketedInvalidPortIsRejected() {
        for bad in ["host:notaport", "host:80222", "host:0", "host:"] {
            XCTAssertNil(HostEndpoint.parse(bad), "\(bad) should be rejected")
        }
    }

    /// The port must read EXACTLY as a number — no leading sign or spaces that
    /// UInt16(_:) would quietly normalise ("+22" would otherwise parse to 22).
    func testNonDigitPortsAreRejected() {
        for bad in ["host:+22", "host:-1", "host: 22", "[::1]:+1"] {
            XCTAssertNil(HostEndpoint.parse(bad), "\(bad) should be rejected — port is not plain digits")
        }
    }

    func testMalformedBracketsAndEmptyAreRejected() {
        for bad in ["", "   ", "[::1", "[]", "[]:22", "[]:notaport"] {
            XCTAssertNil(HostEndpoint.parse(bad), "\(bad.debugDescription) should be rejected")
        }
    }

    /// Boundary: the largest valid port parses, one past it does not.
    func testPortBoundary() {
        XCTAssertEqual(HostEndpoint.parse("h:65535")?.port, 65535)
        XCTAssertNil(HostEndpoint.parse("h:65536"))
    }
}
