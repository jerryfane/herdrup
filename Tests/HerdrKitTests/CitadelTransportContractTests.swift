import XCTest
import Foundation
import Citadel
@testable import HerdrKit

/// The transport-agnostic live contract, ported from SSHTransportTests when the
/// libssh2 transport was removed. It ran SSH-vs-Unix; it now runs
/// CitadelTransport-vs-Unix.
///
/// THE AXIS is unchanged: the same herdr traffic must traverse the pure-Swift SSH
/// path IDENTICALLY to a plain unix socket, or the transport is not carrying the
/// protocol — a "connection opens" test would pass while the protocol was broken.
/// READ-ONLY: agent.list / read / ping only, so it is safe against a live server.
///
/// Skips when the local prerequisites (key, socket, reachable sshd+herdr) are
/// absent, so other environments stay honest about what they did not cover.
final class CitadelTransportContractTests: XCTestCase {

    func testTheLiveContractHoldsIdenticallyOverCitadelAndUnix() async throws {
        // Independent environment gate (key + sshd + socket). Once it passes,
        // neither transport's errors are swallowed as skips — a broken transport
        // fails, as the deleted SSH-vs-Unix test did (review finding #5).
        let credentials = try LiveEnvironment.requireLiveCredentials()
        let citadel = CitadelTransport(credentials: credentials, hostKeyPolicy: PinningHostKeyPolicy(store: PinningHostKeyPolicy.PinStore()))
        let unix = UnixSocketTransport(path: LiveEnvironment.socketPath)

        let overUnix = try await liveContract(HerdrClient(transport: unix), unix)
        let overCitadel = try await liveContract(HerdrClient(transport: citadel), citadel)
        await citadel.close()

        // Identical observable results, not merely both non-empty.
        XCTAssertEqual(overCitadel.paneCount, overUnix.paneCount, "agent.list must agree")
        XCTAssertEqual(overCitadel.firstPane, overUnix.firstPane, "same pane identity")
        XCTAssertEqual(overCitadel.styledHasCSI, overUnix.styledHasCSI, "styling parity")
        XCTAssertEqual(overCitadel.plainHasCSI, overUnix.plainHasCSI, "plain parity")
        XCTAssertEqual(overCitadel.unwrappedNonEmpty, overUnix.unwrappedNonEmpty,
                       "the DEFAULT read surface must work over Citadel too")
        XCTAssertEqual(overCitadel.pingOK, overUnix.pingOK, "ping parity")

        // Parity is necessary but NOT sufficient — both transports can agree on
        // a wrong value, and every boolean here can agree on false. So assert
        // absolute semantics too, over Citadel specifically.
        XCTAssertTrue(overCitadel.pingOK, "a real ping must round-trip over Citadel")
        XCTAssertTrue(overCitadel.styledHasCSI, "ansi must actually be styled")
        XCTAssertFalse(overCitadel.plainHasCSI, "text must actually be unstyled")
        XCTAssertTrue(overCitadel.unwrappedNonEmpty, "the default read surface must return content")
        XCTAssertTrue(overCitadel.unwrappedHasCSI, "the default surface must preserve styling")
        XCTAssertGreaterThan(overCitadel.paneCount, 0, "a live server must report panes")
    }

    struct ContractResult: Equatable {
        var paneCount: Int
        var firstPane: String
        var styledHasCSI: Bool
        var plainHasCSI: Bool
        var unwrappedNonEmpty: Bool
        var unwrappedHasCSI: Bool
        var pingOK: Bool
    }

    /// The contract itself, transport-agnostic. Anything added here is
    /// automatically required of every transport.
    ///
    /// Takes the transport as well as the client because a contract that only
    /// sees the client cannot send a raw request — which is how `pingOK` came
    /// to be hardcoded `true`, asserting a fact it never established.
    func liveContract(
        _ client: HerdrClient, _ transport: any HerdrTransport
    ) async throws -> ContractResult {
        let agents = try await client.agentList()
        let pane = try XCTUnwrap(agents.first).paneID
        let styled = try await client.read(pane: pane, source: .visible, format: .ansi, lines: 40)
        let plain = try await client.read(pane: pane, source: .visible, format: .text, lines: 40)
        // recent_unwrapped is the DEFAULT reading surface per the design panel.
        let unwrapped = try await client.read(pane: pane, lines: 40)
        // A real ping, DECODED rather than substring-matched: a substring check
        // passes on an error envelope that merely mentions the id.
        let requestID = "contract-ping"
        let pong = try await transport.roundTrip(
            "{\"id\":\"\(requestID)\",\"method\":\"ping\",\"params\":{}}"
        )
        struct Empty: Decodable {}
        let decoded = try? JSONDecoder().decode(
            ResultEnvelope<Empty>.self, from: Data(pong.utf8)
        )
        let pongOK = decoded?.id == requestID

        // Both reads must be non-empty: "no CSI" is trivially true of an empty
        // string, so an empty plain read would satisfy the styling assertions
        // while proving nothing.
        XCTAssertFalse(styled.text.isEmpty, "styled read must return content")
        XCTAssertFalse(plain.text.isEmpty, "plain read must return content")

        return ContractResult(
            paneCount: agents.count,
            firstPane: pane,
            styledHasCSI: styled.text.contains("\u{1B}["),
            plainHasCSI: plain.text.contains("\u{1B}["),
            unwrappedNonEmpty: !unwrapped.text.isEmpty,
            unwrappedHasCSI: unwrapped.text.contains("\u{1B}["),
            pingOK: pongOK
        )
    }
}
