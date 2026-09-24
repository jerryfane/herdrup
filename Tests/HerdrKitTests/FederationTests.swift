import XCTest
@testable import HerdrKit

/// The pure peer-grouping derivation behind Settings' Federation section:
/// `PeerSummary.peerSummaries(from:)` groups remote agents by machine and
/// aggregates their reachability worst-case. Mirrors `AgentListTests`' honest
/// fixture path — build the JSON, decode it — so a wrong CodingKey (machine_id /
/// reachability) fails here rather than passing on an in-memory struct.
final class FederationTests: XCTestCase {

    /// Builds an AgentInfo through the decoder, so these tests exercise the same
    /// wire path the app does. A remote agent carries `machine_id`; a local one
    /// leaves it nil.
    private func agent(
        pane: String, machineID: String? = nil, reachability: String? = nil, status: String? = nil,
        name: String? = nil, machineLabel: String? = nil
    ) throws -> AgentInfo {
        var obj: [String: Any] = ["pane_id": pane]
        if let machineID { obj["machine_id"] = machineID }
        if let reachability { obj["reachability"] = reachability }
        if let status { obj["agent_status"] = status }
        if let name { obj["name"] = name }
        if let machineLabel { obj["machine_label"] = machineLabel }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(AgentInfo.self, from: data)
    }

    /// Local agents (no machine_id) are not peers — only remote agents form the list.
    func testLocalAgentsAreExcludedFromPeers() throws {
        let peers = PeerSummary.peerSummaries(from: [
            try agent(pane: "p1", status: "working"),                       // local
            try agent(pane: "p2", status: "idle"),                          // local
            try agent(pane: "mcb/p1", machineID: "mcb", reachability: "reachable"),
        ])
        XCTAssertEqual(peers.map(\.alias), ["mcb"],
                       "a local agent (no machine_id) leaked into the peer list")
        XCTAssertEqual(peers.first?.agentCount, 1, "only the one remote agent should be counted")
    }

    /// A peer with any "unreachable" agent aggregates to offline (worst case wins),
    /// even alongside a reachable one — and both agents are still counted.
    func testAnyUnreachableAgentMakesThePeerOffline() throws {
        let peers = PeerSummary.peerSummaries(from: [
            try agent(pane: "mcb/p1", machineID: "mcb", reachability: "reachable"),
            try agent(pane: "mcb/p2", machineID: "mcb", reachability: "unreachable"),
        ])
        let peer = try XCTUnwrap(peers.first { $0.alias == "mcb" })
        XCTAssertEqual(peer.agentCount, 2, "both of the peer's agents must be counted")
        XCTAssertEqual(peer.reachability, .offline,
                       "one unreachable agent must make the whole peer offline")
    }

    /// A peer with a "degraded" + a "reachable" agent (and no unreachable) aggregates
    /// to degraded — not offline, and not reachable.
    func testDegradedPlusReachableAggregatesToDegraded() throws {
        let peers = PeerSummary.peerSummaries(from: [
            try agent(pane: "air/p1", machineID: "air", reachability: "degraded"),
            try agent(pane: "air/p2", machineID: "air", reachability: "reachable"),
        ])
        let peer = try XCTUnwrap(peers.first { $0.alias == "air" })
        XCTAssertEqual(peer.agentCount, 2)
        XCTAssertEqual(peer.reachability, .degraded,
                       "a degraded agent (no unreachable) must make the peer degraded, not reachable")
    }

    /// All-reachable agents leave the peer reachable, and an unknown reachability
    /// string (a newer server) reads as reachable — the safe "not offline" default.
    func testAllReachableStaysReachable() throws {
        let peers = PeerSummary.peerSummaries(from: [
            try agent(pane: "box/p1", machineID: "box", reachability: "reachable"),
            try agent(pane: "box/p2", machineID: "box", reachability: nil),
            try agent(pane: "box/p3", machineID: "box", reachability: "some_future_state"),
        ])
        let peer = try XCTUnwrap(peers.first { $0.alias == "box" })
        XCTAssertEqual(peer.agentCount, 3)
        XCTAssertEqual(peer.reachability, .reachable,
                       "no unreachable/degraded agent means the peer is reachable; an unknown "
                       + "reachability string must read as reachable (the safe default)")
    }

    /// Multiple peers are grouped by machine_id, counted correctly, and returned in a
    /// stable alias order regardless of the order the server answered in.
    func testPeersAreGroupedCountedAndAliasSorted() throws {
        let peers = PeerSummary.peerSummaries(from: [
            try agent(pane: "zed/p1", machineID: "zed", reachability: "reachable"),
            try agent(pane: "air/p1", machineID: "air", reachability: "reachable"),
            try agent(pane: "air/p2", machineID: "air", reachability: "reachable"),
            try agent(pane: "local", status: "idle"),   // excluded — no machine_id
        ])
        XCTAssertEqual(peers.map(\.alias), ["air", "zed"],
                       "peers must be alias-sorted so the list is stable between refreshes")
        XCTAssertEqual(peers.map(\.agentCount), [2, 1], "per-peer agent counts are wrong")
    }

    /// No remote agents → no peers, which is what drives the section's empty state.
    func testNoRemoteAgentsYieldsNoPeers() throws {
        let peers = PeerSummary.peerSummaries(from: [
            try agent(pane: "p1", status: "working"),
            try agent(pane: "p2", status: "idle"),
        ])
        XCTAssertTrue(peers.isEmpty, "with no machine_id anywhere there are no federation peers")
    }

    /// A federated agent's name arrives prefixed with its peer's ALIAS. Since the
    /// daemon moved SSH federation onto saved machines that alias is the profile's
    /// 32-hex id, so the roster read `2cc0ffe…/voice` on every remote row. The
    /// daemon also sends `machine_label`, and the display name must use it.
    func testRemoteAgentDisplayNameUsesTheMachineLabel() throws {
        let hex = "2cc0ffe3a0753cafcf28f46a7bb29351"
        let remote = try agent(
            pane: "\(hex)/p1", machineID: hex, name: "\(hex)/voice", machineLabel: "pi-burj")
        XCTAssertEqual(remote.displayName, "pi-burj/voice",
                       "the peer's label must replace the alias prefix the daemon bakes into name")
    }

    /// Only the exact alias prefix is swapped: remote ids may contain further
    /// slashes, and losing them would break the name shown for pane-style agents.
    func testLabelSwapPreservesTheRestOfTheRemoteName() throws {
        let hex = "2cc0ffe3a0753cafcf28f46a7bb29351"
        let remote = try agent(
            pane: "\(hex)/p1", machineID: hex, name: "\(hex)/w1:pB", machineLabel: "pi-burj")
        XCTAssertEqual(remote.displayName, "pi-burj/w1:pB")
    }

    /// An unlabelled peer (older daemon, or an explicit non-saved peer) keeps the
    /// raw name. Inventing a label would hide which machine a row belongs to.
    func testUnlabelledPeerKeepsTheRawName() throws {
        let remote = try agent(pane: "mcb/p1", machineID: "mcb", name: "mcb/shell")
        XCTAssertEqual(remote.displayName, "mcb/shell")
    }


    /// The Settings peer row renders `displayName`; with saved-machine aliases
    /// being 32-hex profile ids, showing the alias there read as `2cc0ffe…`.
    func testPeerSummaryPrefersTheMachineLabel() throws {
        let hex = "2cc0ffe3a0753cafcf28f46a7bb29351"
        let peers = PeerSummary.peerSummaries(from: [
            try agent(pane: "\(hex)/p1", machineID: hex, machineLabel: "pi-burj"),
            try agent(pane: "\(hex)/p2", machineID: hex, machineLabel: "pi-burj"),
        ])
        XCTAssertEqual(peers.map(\.displayName), ["pi-burj"])
        XCTAssertEqual(peers.map(\.alias), [hex], "identity must stay the alias")
    }

    /// An unlabelled peer still shows its alias rather than nothing.
    func testPeerSummaryFallsBackToTheAlias() throws {
        let peers = PeerSummary.peerSummaries(from: [try agent(pane: "mcb/p1", machineID: "mcb")])
        XCTAssertEqual(peers.map(\.displayName), ["mcb"])
    }
    func testDisabledProfileStillExposesItsFederationPolicy() throws {
        let configured = try JSONDecoder().decode(SavedMachineStatus.self, from: Data("""
        {"profile_id":"2cc0ffe3a0753cafcf28f46a7bb29351",
         "display_label":"pi-burj","saved_state":"disabled",
         "federation_configured":true,"stale":false}
        """.utf8))
        XCTAssertTrue(configured.hasFederationPolicy)

        let unconfigured = try JSONDecoder().decode(SavedMachineStatus.self, from: Data("""
        {"profile_id":"2cc0ffe3a0753cafcf28f46a7bb29351",
         "display_label":"pi-burj","saved_state":"disabled",
         "federation_configured":false,"stale":false}
        """.utf8))
        XCTAssertFalse(unconfigured.hasFederationPolicy)
    }

    /// A local agent has no alias prefix and must be left completely alone.
    func testLocalAgentNameIsUntouched() throws {
        let local = try agent(pane: "p1", name: "jarvis")
        XCTAssertEqual(local.displayName, "jarvis")
    }
}
