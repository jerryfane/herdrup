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
        pane: String, machineID: String? = nil, reachability: String? = nil, status: String? = nil
    ) throws -> AgentInfo {
        var obj: [String: Any] = ["pane_id": pane]
        if let machineID { obj["machine_id"] = machineID }
        if let reachability { obj["reachability"] = reachability }
        if let status { obj["agent_status"] = status }
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
}
