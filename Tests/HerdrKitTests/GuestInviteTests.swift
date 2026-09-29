import Crypto
import Foundation
import XCTest
@testable import HerdrKit

final class GuestInviteTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func fields(overriding changes: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "v": 1,
            "relay": "https://guest.herdrup.themartian.app",
            "host_id": Base64URL.encode(Data(repeating: 0x11, count: 16)),
            "host_pub": Base64URL.encode(Data(repeating: 0x22, count: 32)),
            "invite_id": Base64URL.encode(Data(repeating: 0x33, count: 16)),
            "secret": Base64URL.encode(Data(repeating: 0x44, count: 32)),
            "machine_label": "Jerry's Mac Studio",
            "owner_name": "Jerry",
            "agent_name": "llm-opt",
            "guest_name": "plotarmordev",
            "expires_unix": Int(now.timeIntervalSince1970) + 86_400,
        ]
        for (key, value) in changes { fields[key] = value }
        return fields
    }

    static func payload(_ fields: [String: Any]) -> String {
        Base64URL.encode(try! JSONSerialization.data(withJSONObject: fields))
    }

    func testAllLinkFormsParseAndRoundTrip() throws {
        let payload = Self.payload(Self.fields())
        let app = try GuestInvite.parse("herdrup://guest-invite#\(payload)", now: Self.now)
        let path = try GuestInvite.parse("https://guest.herdrup.themartian.app/i/\(payload)", now: Self.now)
        let fragment = try GuestInvite.parse("https://guest.herdrup.themartian.app/i#\(payload)", now: Self.now)
        XCTAssertEqual(app, path)
        XCTAssertEqual(app, fragment)
        XCTAssertEqual(app.guestName, "plotarmordev")
        XCTAssertEqual(app.machineLabel, "Jerry's Mac Studio")
        XCTAssertEqual(app.hostPublicKey, Data(repeating: 0x22, count: 32))
        XCTAssertEqual(app.expires, Self.now.addingTimeInterval(86_400))

        XCTAssertEqual(try GuestInvite.parse(app.appLink.absoluteString, now: Self.now), app)
        XCTAssertEqual(try GuestInvite.parse(app.webLink.absoluteString, now: Self.now), app)
        XCTAssertEqual(app.webLink.absoluteString, "https://guest.herdrup.themartian.app/i/\(app.payload)")
    }

    /// A relay mounted below the root serves its links below that path, and only there.
    func testWebLinkOnARelayWithAPath() throws {
        let payload = Self.payload(Self.fields(overriding: ["relay": "https://example.org/herdr/"]))
        for link in ["https://example.org/herdr/i/\(payload)", "https://example.org/herdr/i#\(payload)",
                     "https://EXAMPLE.org/herdr/i/\(payload)"] {
            XCTAssertEqual(try GuestInvite.parse(link, now: Self.now).relay.absoluteString,
                           "https://example.org/herdr/", link)
        }
        for link in ["https://example.org/i/\(payload)", "https://example.org/other/i/\(payload)",
                     "https://example.org/herdr/x/i/\(payload)"] {
            XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now), link) {
                XCTAssertEqual($0 as? GuestInvite.Failure, .notAnInvite, link)
            }
        }
    }

    /// A web link is only an invite on its own relay: a valid payload lifted onto another
    /// host, path or port, or with anything around `/i/<payload>`, is rejected.
    func testRejectsWebLinksOffTheExactRelayPath() {
        let payload = Self.payload(Self.fields())
        let links = [
            "https://evil.example/i/\(payload)",
            "https://evil.example/i#\(payload)",
            "https://guest.herdrup.themartian.app.evil.example/i/\(payload)",
            "https://guest.herdrup.themartian.app:8443/i/\(payload)",
            "https://user@guest.herdrup.themartian.app/i/\(payload)",
            "http://guest.herdrup.themartian.app/i/\(payload)",
            "https://guest.herdrup.themartian.app/x/i/\(payload)",
            "https://guest.herdrup.themartian.app/i/i/\(payload)",
            "https://guest.herdrup.themartian.app/i/\(payload)/",
            "https://guest.herdrup.themartian.app/i/\(payload)/extra",
            "https://guest.herdrup.themartian.app/i/\(payload)?x=1",
            "https://guest.herdrup.themartian.app/i/\(payload)#\(payload)",
            "https://guest.herdrup.themartian.app/i?x=1#\(payload)",
            "https://guest.herdrup.themartian.app/in#\(payload)",
            "https://guest.herdrup.themartian.app/i/",
            "https://guest.herdrup.themartian.app/i#",
            "herdrup://guest-invite#",
        ]
        for link in links {
            XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now), link) {
                XCTAssertEqual($0 as? GuestInvite.Failure, .notAnInvite, link)
            }
        }
    }

    /// Characters outside base64url in the payload mean a damaged link in every form.
    func testRejectsBadPayloadCharacters() {
        let payload = Self.payload(Self.fields())
        let damaged = [String(payload.dropLast(3)) + "!!!", String(payload.dropLast(3)) + "%2F",
                       String(payload.dropLast(4)) + "abc=", "+" + String(payload.dropFirst())]
        for bad in damaged {
            for link in ["herdrup://guest-invite#\(bad)", "https://guest.herdrup.themartian.app/i/\(bad)",
                         "https://guest.herdrup.themartian.app/i#\(bad)"] {
                XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now), link) {
                    XCTAssertEqual($0 as? GuestInvite.Failure, .malformed("encoding"), link)
                }
            }
        }
    }

    func testRecognisesInviteLinkShapes() {
        XCTAssertTrue(GuestInvite.isInviteLink("herdrup://guest-invite#abc"))
        XCTAssertTrue(GuestInvite.isInviteLink("https://guest.herdrup.themartian.app/i/abc"))
        XCTAssertTrue(GuestInvite.isInviteLink("https://guest.herdrup.themartian.app/i#abc"))
        for text in ["herdrup://agent/w1-3", "https://guest.herdrup.themartian.app/i",
                     "https://guest.herdrup.themartian.app/i/abc/def", "https://example.org/about"] {
            XCTAssertFalse(GuestInvite.isInviteLink(text), text)
        }
    }

    /// An older daemon's `…/i#<payload>` goes out as `…/i/<payload>`, which Messages
    /// keeps whole, and still opens the same invite.
    func testShareableWebURLConvertsTheFragmentForm() throws {
        let payload = Self.payload(Self.fields())
        func created(_ webURL: String) -> GuestInviteCreated {
            GuestInviteCreated(invite: GuestInviteRecord(inviteID: "inv", name: "plotarmordev", grant: nil),
                               url: "herdrup://guest-invite#\(payload)", webURL: webURL)
        }
        let old = created("https://guest.herdrup.themartian.app/i#\(payload)")
        XCTAssertEqual(old.shareableWebURL, "https://guest.herdrup.themartian.app/i/\(payload)")
        XCTAssertFalse(old.shareableWebURL.contains("#"))
        XCTAssertEqual(try GuestInvite.parse(old.shareableWebURL, now: Self.now),
                       try GuestInvite.parse(old.webURL, now: Self.now))

        let mounted = created("https://example.org/herdr/i#\(payload)")
        XCTAssertEqual(mounted.shareableWebURL, "https://example.org/herdr/i/\(payload)")

        let current = created("https://guest.herdrup.themartian.app/i/\(payload)")
        XCTAssertEqual(current.shareableWebURL, current.webURL)
    }

    /// A link pasted with the owner's message around it, as Messages delivers it.
    func testFindsTheLinkInsidePastedText() throws {
        let payload = Self.payload(Self.fields())
        for link in ["https://guest.herdrup.themartian.app/i/\(payload)",
                     "https://guest.herdrup.themartian.app/i#\(payload)"] {
            let text = "hey! here's llm-opt:\n \(link)  \nhave fun"
            XCTAssertEqual(try GuestInvite.parse(text, now: Self.now).agentName, "llm-opt", link)
        }
    }

    func testExpiryBoundary() throws {
        let expires = Int(Self.now.timeIntervalSince1970) + 10
        let link = "herdrup://guest-invite#" + Self.payload(Self.fields(overriding: ["expires_unix": expires]))
        XCTAssertNoThrow(try GuestInvite.parse(link, now: Self.now.addingTimeInterval(9)))
        XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now.addingTimeInterval(10))) { error in
            XCTAssertEqual(error as? GuestInvite.Failure, .expired)
        }
    }

    func testRejectsLinksThatAreNotInvites() {
        for text in ["", "hello", "https://guest.herdrup.themartian.app/x#abc",
                     "http://guest.herdrup.themartian.app/i#abc", "herdrup://agent/w1-3"] {
            XCTAssertThrowsError(try GuestInvite.parse(text, now: Self.now), text) { error in
                XCTAssertEqual(error as? GuestInvite.Failure, .notAnInvite, text)
            }
        }
    }

    func testRejectsDamagedFields() {
        let cases: [(String, Any, String)] = [
            ("host_pub", Base64URL.encode(Data(count: 31)), "host_pub"),
            ("host_id", "not b64url!", "host_id"),
            ("secret", Base64URL.encode(Data(count: 16)), "secret"),
            ("invite_id", Base64URL.encode(Data(count: 32)), "invite_id"),
            ("guest_name", "-bad", "guest_name"),
            ("guest_name", String(repeating: "a", count: 33), "guest_name"),
            ("machine_label", "  ", "machine_label"),
            ("agent_name", "llm\nopt", "agent_name"),
            ("relay", "ftp://guest.herdrup.themartian.app", "relay"),
            // A cleartext relay is only accepted for a local development relay.
            ("relay", "http://evil.example", "relay"),
            ("expires_unix", "tomorrow", "expires_unix"),
        ]
        for (key, value, field) in cases {
            let link = "herdrup://guest-invite#" + Self.payload(Self.fields(overriding: [key: value]))
            XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now), "\(key)=\(value)") { error in
                XCTAssertEqual(error as? GuestInvite.Failure, .malformed(field), "\(key)=\(value)")
            }
        }
        var missing = Self.fields()
        missing.removeValue(forKey: "secret")
        XCTAssertThrowsError(try GuestInvite.parse("herdrup://guest-invite#" + Self.payload(missing), now: Self.now)) {
            XCTAssertEqual($0 as? GuestInvite.Failure, .malformed("secret"))
        }
        XCTAssertThrowsError(try GuestInvite.parse("herdrup://guest-invite#!!!", now: Self.now)) {
            XCTAssertEqual($0 as? GuestInvite.Failure, .malformed("encoding"))
        }
    }

    func testLocalDevelopmentRelayIsAllowed() throws {
        let link = "herdrup://guest-invite#" + Self.payload(Self.fields(overriding: ["relay": "http://localhost:8787"]))
        let invite = try GuestInvite.parse(link, now: Self.now)
        let endpoint = RelayEndpoint(relay: invite.relay, hostID: invite.hostID, hostPublicKey: invite.hostPublicKey)
        XCTAssertEqual(endpoint.socketURL.absoluteString, "ws://localhost:8787/v1/guest/\(invite.hostID)")
    }

    func testNewerInviteVersionAsksForAnUpdate() {
        let link = "herdrup://guest-invite#" + Self.payload(Self.fields(overriding: ["v": 2]))
        XCTAssertThrowsError(try GuestInvite.parse(link, now: Self.now)) { error in
            XCTAssertEqual(error as? GuestInvite.Failure, .unsupportedVersion(2))
        }
    }

    func testBase64URLIsStrict() {
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff])), "-_8")
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xfb, 0xff]))
        XCTAssertNil(Base64URL.decode("-_8="), "padding")
        XCTAssertNil(Base64URL.decode("+/8"), "standard alphabet")
        XCTAssertNil(Base64URL.decode("abcde"), "impossible length")
    }

    func testRelaySocketURL() {
        let endpoint = RelayEndpoint(
            relay: URL(string: "https://guest.herdrup.themartian.app/")!, hostID: "AAAAAAAAAAAAAAAAAAAAAA",
            hostPublicKey: Data(count: 32))
        XCTAssertEqual(endpoint.socketURL.absoluteString,
                       "wss://guest.herdrup.themartian.app/v1/guest/AAAAAAAAAAAAAAAAAAAAAA")
    }
}

final class GuestNameTests: XCTestCase {
    func testNameRule() {
        for valid in ["plotarmordev", "a", "A.b_c-9", String(repeating: "x", count: 32)] {
            XCTAssertTrue(GuestName.isValid(valid), valid)
        }
        for invalid in ["", ".a", "_a", "-a", "a b", "é", "a/b", String(repeating: "x", count: 33)] {
            XCTAssertFalse(GuestName.isValid(invalid), invalid)
        }
    }
}

final class GuestIdentityTests: XCTestCase {
    func testFingerprintFormat() {
        XCTAssertEqual(GuestIdentity.fingerprint(of: Data(0..<32)), "SHA256:630d·cd29·66c4·3366")
    }

    func testKeyIsCreatedOnceAndReused() throws {
        let store = InMemoryGuestKeyStore()
        let first = try GuestIdentity.loadOrCreate(store: store)
        XCTAssertEqual(try store.loadGuestKey()?.count, 32)
        let second = try GuestIdentity.loadOrCreate(store: store)
        XCTAssertEqual(first.publicKey, second.publicKey)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    /// Losing the key severs every share; a store that returns garbage must be
    /// surfaced, never silently replaced with a fresh key.
    func testCorruptStoredKeyIsNotOverwritten() {
        let store = InMemoryGuestKeyStore(key: Data(count: 7))
        XCTAssertThrowsError(try GuestIdentity.loadOrCreate(store: store)) { error in
            XCTAssertEqual(error as? GuestIdentity.Failure, .corruptKey)
        }
        XCTAssertEqual(try store.loadGuestKey(), Data(count: 7))
    }
}
