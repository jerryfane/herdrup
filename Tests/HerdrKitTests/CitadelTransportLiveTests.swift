import XCTest
import Foundation
import Citadel
@testable import HerdrKit

/// End-to-end round-trip through the REAL deployed api-bridge over a REAL SSH
/// connection. Skips unless the environment can support it — decided by
/// `LiveEnvironment` from signals INDEPENDENT of the transport (key on disk, sshd
/// on :22, herdr socket present). Once those hold, the transport's errors are NOT
/// swallowed as skips: a real regression fails here (review findings #5/#6).
///
/// READ-ONLY BY CONTRACT (truncate-safety inventory): every request here is
/// `agent.list` / `ping` / a read-only subscription — never a mutating call — so
/// running this against the live fleet cannot disturb it.
final class CitadelTransportLiveTests: XCTestCase {

    /// A real round-trip: connect over SSH, exec the deployed `herdr api-bridge`
    /// with a base64 agent.list, read the reply. Proves the whole path — key
    /// auth, channel exec, argument decode, single-shot reply — end to end.
    ///
    /// Connects through the SHIPPING DEFAULT: the pinning host-key policy, not
    /// `.acceptAnything()`. So it also proves first-contact trust connects and
    /// that the fingerprint is computed over a REAL presented host key (the pin
    /// is asserted below), which no unit test with a synthetic key can show.
    func testLiveAgentListRoundTrip() async throws {
        let credentials = try LiveEnvironment.requireLiveCredentials()
        let policy = PinningHostKeyPolicy(store: PinningHostKeyPolicy.PinStore())
        let transport = CitadelTransport(credentials: credentials, hostKeyPolicy: policy)
        // No catch here: the environment is proven present, so a thrown error is
        // a transport regression to surface, not a reason to skip.
        let reply = try await transport.roundTrip(#"{"id":"live-1","method":"agent.list","params":{}}"#)
        await transport.close()

        XCTAssertTrue(reply.contains(#""id":"live-1""#),
                      "the reply is not correlated to the request id: \(reply.prefix(160))")
        XCTAssertTrue(reply.contains("agent_list") || reply.contains("\"result\""),
                      "the reply is not an agent.list result: \(reply.prefix(160))")
        // The handshake completed, so the pinning validator ran and pinned the
        // server's real host key — the default trust path is exercised, not bypassed.
        XCTAssertNotNil(policy.pinnedFingerprint(for: credentials.host, port: credentials.port),
                        "connected but the host key was never pinned — pinning path not exercised")
    }

    /// The OTHER transport method: `stream`. Opens a real `events.subscribe`
    /// (layout.updated — the one non-pane-scoped kind, read-only), reads the
    /// `subscription_started` ack, then stops. Breaking the loop cancels the
    /// stream, which closes the channel.
    ///
    /// Then it round-trips on the SAME transport. That second call is the point:
    /// it is the negative of the herdr-ios#1 hang, where a cancelled idle
    /// subscription wedged the connection. If cancellation left the held client
    /// broken, the round-trip here would hang or throw.
    func testLiveStreamCancellationLeavesConnectionReusable() async throws {
        let credentials = try LiveEnvironment.requireLiveCredentials()
        let transport = CitadelTransport(credentials: credentials, hostKeyPolicy: PinningHostKeyPolicy(store: PinningHostKeyPolicy.PinStore()))

        let subscribe = #"{"id":"sub","method":"events.subscribe","params":{"subscriptions":[{"type":"layout.updated"}]}}"#
        // No catch: the environment is proven present, so a stream error is a
        // regression to fail on, not a skip.
        var firstLine: String?
        for try await line in transport.stream(subscribe) {
            firstLine = line
            break   // stop consuming -> onTermination cancels -> channel close
        }

        let line = try XCTUnwrap(firstLine, "the subscription delivered no line")
        XCTAssertTrue(line.contains("subscription_started"),
                      "the first stream line is not the subscription ack: \(line.prefix(160))")

        // The connection survived the stream's cancellation.
        let reply = try await transport.roundTrip(#"{"id":"after","method":"agent.list","params":{}}"#)
        await transport.close()
        XCTAssertTrue(reply.contains(#""id":"after""#),
                      "a round-trip after stream cancellation did not complete: \(reply.prefix(160))")
    }

    /// Guards the transport's DEFAULT host-key wiring (review finding: the policy
    /// test alone doesn't prove `CitadelTransport`'s default uses the shared
    /// store). A pure-default transport — no `hostKeyPolicy` argument — must pin
    /// the server key into the PROCESS-WIDE `PinStore.shared`; if the default is
    /// changed to a fresh/isolated store, the shared store stays empty here and
    /// this fails. Every OTHER live/contract test uses a fresh store, so only this
    /// default transport writes 127.0.0.1 into `.shared`.
    func testDefaultTransportPinsIntoTheSharedStore() async throws {
        let credentials = try LiveEnvironment.requireLiveCredentials()
        let transport = CitadelTransport(credentials: credentials)   // pure default wiring
        _ = try await transport.roundTrip(#"{"id":"wiring","method":"agent.list","params":{}}"#)
        await transport.close()

        XCTAssertNotNil(
            PinningHostKeyPolicy.PinStore.shared.pinned(key: "\(credentials.host):\(credentials.port)"),
            "the default transport did not pin into PinStore.shared — its default wiring is not the shared store")
    }

}
