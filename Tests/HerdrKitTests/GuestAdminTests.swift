import XCTest
@testable import HerdrKit

/// The owner-side guest RPCs: what goes on the wire (including routing a federated agent to
/// the daemon that runs it) and how leniently the answers decode.
final class GuestAdminTests: XCTestCase {

    private final class CapturingTransport: HerdrTransport, @unchecked Sendable {
        var requests: [String] = []
        let reply: String
        init(reply: String) { self.reply = reply }
        func roundTrip(_ requestLine: String) async throws -> String {
            requests.append(requestLine)
            return reply
        }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        /// The last request's method and params, parsed rather than substring-matched so a
        /// stray key or a wrong value type cannot hide.
        func last() throws -> (method: String, params: [String: Any]) {
            let line = try XCTUnwrap(requests.last)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return (try XCTUnwrap(object["method"] as? String),
                    try XCTUnwrap(object["params"] as? [String: Any]))
        }
    }

    private static let inviteReply = #"""
    {"id":"x","result":{"type":"guest_invite","invite":{"invite_id":"inv1","name":"plotarmordev",
    "grant":{"terminal_id":"t7","agent_name":"llm-opt","agent_session":{"source":"hook","agent":"omp","kind":"session_id","value":"s1"}},"owner_name":"Jerry",
    "machine_label":"Jerry's Mac Studio","created_ms":1000,"expires_ms":86401000,"used_by":null,
    "secret_sha256":"ignored"},"url":"herdrup://guest-invite#eyJ2IjoxfQ",
    "web_url":"https://guest.herdrup.themartian.app/i#eyJ2IjoxfQ"}}
    """#

    private func federatedAgent() throws -> AgentInfo {
        try JSONDecoder().decode(AgentInfo.self, from: Data(#"""
        {"pane_id":"2cc0ffe3/w1:p3","name":"2cc0ffe3/llm-opt","terminal_id":"2cc0ffe3/t7",
         "machine_id":"2cc0ffe3","machine_label":"Jerry's Mac Studio","agent":"omp"}
        """#.utf8))
    }

    // MARK: guest.invite.create

    func testInviteCreateForALocalAgentSendsNoMachine() async throws {
        let t = CapturingTransport(reply: Self.inviteReply)
        let created = try await HerdrClient(transport: t).guestInviteCreate(
            target: "w1:p1", name: "plotarmordev", ownerName: "Jerry", machineLabel: "Jerry's Mac Studio")

        let (method, params) = try t.last()
        XCTAssertEqual(method, "guest.invite.create")
        XCTAssertEqual(params["target"] as? String, "w1:p1")
        XCTAssertEqual(params["name"] as? String, "plotarmordev")
        XCTAssertEqual(params["owner_name"] as? String, "Jerry")
        XCTAssertEqual(params["machine_label"] as? String, "Jerry's Mac Studio")
        // A local call must not carry a machine (not even null): the coordinator would try to
        // route it to a peer.
        XCTAssertNil(params["machine"], "local invite must not name a machine")
        XCTAssertNil(params["ttl_secs"], "no ttl means the daemon's 24 h default")

        XCTAssertEqual(created.url, "herdrup://guest-invite#eyJ2IjoxfQ")
        XCTAssertEqual(created.webURL, "https://guest.herdrup.themartian.app/i#eyJ2IjoxfQ")
        XCTAssertEqual(created.invite.inviteID, "inv1")
        XCTAssertEqual(created.invite.grant, GuestGrant(terminalID: "t7", agentName: "llm-opt"))
        XCTAssertEqual(created.invite.expiresMs, 86_401_000)
        XCTAssertNil(created.invite.usedBy)
    }

    /// A federated agent is shared by the daemon that runs it: the coordinator gets the peer
    /// alias as `machine` and the pane id that peer knows, never the prefixed id.
    func testInviteCreateForAFederatedAgentRoutesToItsMachineWithTheLocalPane() async throws {
        let route = GuestRoute(agent: try federatedAgent())
        XCTAssertEqual(route.target, "w1:p3")
        XCTAssertEqual(route.machine, "2cc0ffe3")
        XCTAssertEqual(route.local("2cc0ffe3/t7"), "t7", "the grant is matched by the peer's own terminal id")

        let t = CapturingTransport(reply: Self.inviteReply)
        _ = try await HerdrClient(transport: t).guestInviteCreate(
            target: route.target, name: "plotarmordev", ownerName: "Jerry",
            machineLabel: "Jerry's Mac Studio", ttlSecs: 3600, machine: route.machine)

        let (_, params) = try t.last()
        XCTAssertEqual(params["machine"] as? String, "2cc0ffe3")
        XCTAssertEqual(params["target"] as? String, "w1:p3")
        XCTAssertEqual(params["ttl_secs"] as? Int, 3600)
    }

    func testRouteStripsOnlyTheExactMachinePrefix() {
        // The local remainder may itself contain slashes.
        let nested = GuestRoute(paneID: "peer/a/b:p1", machineID: "peer")
        XCTAssertEqual(nested.target, "a/b:p1")
        XCTAssertEqual(nested.machine, "peer")
        // A pane that does not carry its machine's prefix is not rewritten or routed.
        let mismatch = GuestRoute(paneID: "other/w1:p1", machineID: "peer")
        XCTAssertEqual(mismatch.target, "other/w1:p1")
        XCTAssertNil(mismatch.machine)
        // A local agent with a slash in its id stays local.
        let local = GuestRoute(paneID: "w1/p1", machineID: nil)
        XCTAssertEqual(local.target, "w1/p1")
        XCTAssertNil(local.machine)
        XCTAssertEqual(nested.local("peer/t9"), "t9")
        XCTAssertEqual(local.local("peer/t9"), "peer/t9")
    }

    // MARK: guest.list

    func testListDecodesLenientlyAndSeparatesActiveFromRevokedAndSpentInvites() async throws {
        let reply = #"""
        {"id":"x","result":{"type":"guest_list","future_field":{"a":1},
         "guests":[
          {"guest_id":"g1","name":"plotarmordev","fingerprint":"SHA256:9f3a·e71c·04bd·c21e","device":"iPhone",
           "grant":{"terminal_id":"t7","agent_name":"llm-opt"},"created_ms":10,"last_seen_ms":20,"revoked":false,"extra":true},
          {"guest_id":"g2","name":"old","grant":{"terminal_id":"t7","agent_name":"llm-opt"},"revoked":true},
          {"guest_id":"g3","name":"other","grant":{"terminal_id":"t8","agent_name":"voice"}}],
         "invites":[
          {"invite_id":"i1","name":"fresh","grant":{"terminal_id":"t7"},"expires_ms":5000},
          {"invite_id":"i2","name":"used","grant":{"terminal_id":"t7"},"expires_ms":5000,"used_by":"g1"},
          {"invite_id":"i3","name":"stale","grant":{"terminal_id":"t7"},"expires_ms":1000}],
         "link":{"state":"hibernating","last_error":"dns"}}}
        """#
        let t = CapturingTransport(reply: reply)
        let listing = try await HerdrClient(transport: t).guestList()

        let (method, params) = try t.last()
        XCTAssertEqual(method, "guest.list")
        XCTAssertTrue(params.isEmpty, "a local list sends no params, got \(params)")

        XCTAssertEqual(listing.guests.count, 3)
        XCTAssertFalse(listing.guests[2].revoked, "an absent revoked flag means not revoked")
        XCTAssertEqual(listing.activeGuests.map(\.guestID), ["g1", "g3"])
        XCTAssertEqual(listing.activeGuests(terminalID: "t7", agentName: "llm-opt").map(\.guestID), ["g1"],
                       "the chip must name neither a revoked guest nor another agent's guest")
        XCTAssertEqual(listing.pendingInvites(nowMs: 2000).map(\.inviteID), ["i1"],
                       "used and expired invites are not pending")
        XCTAssertEqual(listing.pendingInvites(nowMs: 5000).map(\.inviteID), [],
                       "an invite expires at expires_ms")
        XCTAssertEqual(listing.link, GuestLinkStatus(state: .other("hibernating"), lastError: "dns"),
                       "an unknown link state must not fail the whole list")
    }

    func testListOnAPeerCarriesTheMachineAndToleratesMissingArrays() async throws {
        let t = CapturingTransport(reply: #"{"id":"x","result":{"type":"guest_list","link":{"state":"up"}}}"#)
        let listing = try await HerdrClient(transport: t).guestList(machine: "2cc0ffe3")
        XCTAssertEqual(try t.last().params["machine"] as? String, "2cc0ffe3")
        XCTAssertEqual(listing, GuestListing(link: GuestLinkStatus(state: .up)))
    }

    func testGrantMatchPrefersTerminalIDAndFallsBackToName() {
        let grant = GuestGrant(terminalID: "t7", agentName: "llm-opt")
        XCTAssertTrue(grant.matches(terminalID: "t7", agentName: "renamed"))
        XCTAssertFalse(grant.matches(terminalID: "t8", agentName: "llm-opt"),
                       "a different terminal with the same name is a different agent")
        XCTAssertTrue(GuestGrant(terminalID: nil, agentName: "llm-opt").matches(terminalID: "t7", agentName: "llm-opt"))
        XCTAssertFalse(GuestGrant(terminalID: nil, agentName: nil).matches(terminalID: nil, agentName: nil))
    }

    // MARK: guest.revoke

    func testRevokeNamesExactlyOneKind() async throws {
        let t = CapturingTransport(reply: #"{"id":"x","result":{"type":"guest_revoked","guest_id":"g1","closed_streams":1}}"#)
        let client = HerdrClient(transport: t)

        try await client.guestRevoke(.guest("g1"))
        var params = try t.last().params
        XCTAssertEqual(try t.last().method, "guest.revoke")
        XCTAssertEqual(params["guest_id"] as? String, "g1")
        XCTAssertNil(params["invite_id"])
        XCTAssertNil(params["machine"])

        try await client.guestRevoke(.invite("i1"), machine: "peer")
        params = try t.last().params
        XCTAssertEqual(params["invite_id"] as? String, "i1")
        XCTAssertNil(params["guest_id"])
        XCTAssertEqual(params["machine"] as? String, "peer")
    }

    func testRevokeFailureSurfacesTheDaemonError() async throws {
        let t = CapturingTransport(reply: #"{"id":"x","error":{"code":"unsupported","message":"guest access is unix only"}}"#)
        do {
            try await HerdrClient(transport: t).guestRevoke(.guest("g1"))
            XCTFail("an error envelope must throw")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "unsupported")
        }
    }

    // MARK: guest.audit

    func testAuditClampsTheLimitAndOmitsUnsetFilters() async throws {
        let t = CapturingTransport(reply: #"{"id":"x","result":{"type":"guest_audit","entries":[]}}"#)
        let client = HerdrClient(transport: t)

        _ = try await client.guestAudit(limit: 10_000)
        var params = try t.last().params
        XCTAssertEqual(try t.last().method, "guest.audit")
        XCTAssertEqual(params["limit"] as? Int, 500, "the daemon rejects a page above 500")
        XCTAssertNil(params["guest_id"])
        XCTAssertNil(params["before_ms"])
        XCTAssertNil(params["machine"])

        _ = try await client.guestAudit(guestID: "g1", limit: 0, beforeMs: 1234, machine: "peer")
        params = try t.last().params
        XCTAssertEqual(params["limit"] as? Int, 1)
        XCTAssertEqual(params["guest_id"] as? String, "g1")
        XCTAssertEqual(params["before_ms"] as? Int, 1234)
        XCTAssertEqual(params["machine"] as? String, "peer")
    }

    func testAuditDecodesEveryEventShapeAndKeepsUnknownEvents() async throws {
        let reply = #"""
        {"id":"x","result":{"type":"guest_audit","entries":[
         {"ts_ms":3,"guest_id":"g1","name":"plotarmordev","fingerprint":"SHA256:9f3a·e71c·04bd·c21e","event":"upload",
          "pane":"w1:p1","file":{"name":"prompt-set-v2.jsonl","size":49152,"sha256":"ab"}},
         {"ts_ms":2,"guest_id":"g1","name":"plotarmordev","event":"prompt","pane":"w1:p1","text":"rerun the bench"},
         {"ts_ms":1,"guest_id":"g1","name":"plotarmordev","event":"denied","method":"pane.send_keys"},
         {"ts_ms":0,"event":"quarantined","new":1}]}}
        """#
        let entries = try await HerdrClient(transport: CapturingTransport(reply: reply)).guestAudit()
        XCTAssertEqual(entries.map(\.event), [.upload, .prompt, .denied, .other("quarantined")])
        XCTAssertEqual(entries[0].file, GuestAuditFile(name: "prompt-set-v2.jsonl", size: 49152, sha256: "ab"))
        XCTAssertEqual(entries[1].text, "rerun the bench")
        XCTAssertEqual(entries[2].method, "pane.send_keys")
        XCTAssertNil(entries[3].guestID)
    }
}
