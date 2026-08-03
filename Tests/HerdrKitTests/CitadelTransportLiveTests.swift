import XCTest
import Foundation
import Citadel
@testable import HerdrKit

/// End-to-end round-trip through the REAL deployed api-bridge over a REAL SSH
/// connection. Skips unless the environment can support it (an Ed25519 key, a
/// reachable sshd, and a running herdr), so the suite stays green on machines
/// without them — matching the SSHTransportTests live-skip discipline.
///
/// READ-ONLY BY CONTRACT (truncate-safety inventory): every request here is
/// `agent.list` / `ping` — never a mutating call — so running this against the
/// live fleet cannot disturb it.
final class CitadelTransportLiveTests: XCTestCase {

    private func credentials() throws -> SSHCredentials {
        let keyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/id_ed25519")
        guard let keyData = try? Data(contentsOf: keyURL),
              let keyText = String(data: keyData, encoding: .utf8) else {
            throw XCTSkip("no ~/.ssh/id_ed25519; CitadelTransport not exercisable here")
        }
        return SSHCredentials(
            host: "127.0.0.1",
            port: 22,
            username: NSUserName(),
            privateKeyPEM: keyText,
            remoteSocketPath: ""  // unused: the server-side api-bridge resolves the socket
        )
    }

    /// A real round-trip: connect over SSH, exec the deployed `herdr api-bridge`
    /// with a base64 agent.list, read the reply. Proves the whole path — key
    /// auth, channel exec, argument decode, single-shot reply — end to end.
    ///
    /// Connects through the SHIPPING DEFAULT: the pinning host-key policy, not
    /// `.acceptAnything()`. So it also proves first-contact trust connects and
    /// that the fingerprint is computed over a REAL presented host key (the pin
    /// is asserted below), which no unit test with a synthetic key can show.
    func testLiveAgentListRoundTrip() async throws {
        let credentials = try credentials()
        let policy = PinningHostKeyPolicy()
        let transport = CitadelTransport(credentials: credentials, hostKeyPolicy: policy)
        let reply: String
        do {
            reply = try await transport.roundTrip(#"{"id":"live-1","method":"agent.list","params":{}}"#)
        } catch {
            throw XCTSkip("could not reach herdr over SSH (\(error)); live path not exercisable here")
        }
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
        let credentials = try credentials()
        let transport = CitadelTransport(credentials: credentials, hostKeyPolicy: PinningHostKeyPolicy())

        let subscribe = #"{"id":"sub","method":"events.subscribe","params":{"subscriptions":[{"type":"layout.updated"}]}}"#
        var firstLine: String?
        do {
            for try await line in transport.stream(subscribe) {
                firstLine = line
                break   // stop consuming -> onTermination cancels -> channel close
            }
        } catch {
            throw XCTSkip("could not stream from herdr over SSH (\(error)); live path not exercisable here")
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
}
