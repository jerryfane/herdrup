import Foundation

/// A peer's aggregate reachability, taken worst-case across its agents. The home
/// box polls each remote agent's `reachability`; a machine is only as reachable as
/// its least-reachable agent, so any `unreachable` agent makes the whole peer
/// `.offline`, else any `degraded` makes it `.degraded`, else `.reachable`.
///
/// Unknown reachability strings (a newer server) read as reachable — the safe
/// default is "not offline", matching `AgentInfo.isUnreachable`.
public enum PeerReachability: Equatable, Sendable {
    case reachable, degraded, offline
}

/// A remote machine (federation peer) as summarized from the agent list: one entry
/// per distinct `machineID`, carrying how many of that peer's agents the home box
/// currently lists and the aggregate reachability across them.
///
/// This is a PURE derivation from `[AgentInfo]` (no SwiftUI, no server call), so the
/// grouping + aggregation rules are unit-tested on Linux like `AgentList`, and the
/// Settings Federation section only renders what this decides.
public struct PeerSummary: Equatable, Identifiable, Sendable {
    /// The peer's alias — the shared `machineID` its agents carry (also the
    /// `<alias>/…` prefix on their names/pane ids). Its identity here too.
    public let alias: String
    /// The peer's human label when the daemon reports one. Since SSH federation
    /// moved onto saved machines the alias is a 32-hex profile id, so a row that
    /// renders `alias` alone reads `2cc0ffe…` instead of `pi-burj`. Identity stays
    /// the alias; this is presentation only, and is nil on an older daemon or an
    /// explicit non-saved peer.
    public let label: String?
    /// How many of this peer's agents are in the current list.
    public let agentCount: Int
    /// The aggregate reachability across this peer's agents (worst case wins).
    public let reachability: PeerReachability

    public var id: String { alias }

    /// What a peer row should show: the label when there is one, else the alias.
    public var displayName: String { label ?? alias }

    public init(
        alias: String, label: String? = nil, agentCount: Int, reachability: PeerReachability
    ) {
        self.alias = alias
        self.label = label
        self.agentCount = agentCount
        self.reachability = reachability
    }

    /// Derive the remote-machine (peer) list from a flat agent list: keep only the
    /// agents that carry a `machineID` (a remote/federated agent — a local agent
    /// leaves it nil), group by that id, and aggregate reachability worst-case.
    /// Sorted by alias so the list is stable between refreshes regardless of the
    /// order the server answered in (the same churn `AgentList` guards against).
    public static func peerSummaries(from agents: [AgentInfo]) -> [PeerSummary] {
        let remote = agents.filter { $0.machineID != nil }
        let byMachine = Dictionary(grouping: remote) { $0.machineID! }
        return byMachine
            .map { alias, group in
                PeerSummary(
                    alias: alias,
                    label: group.compactMap(\.machineLabel).first(where: { !$0.isEmpty }),
                    agentCount: group.count,
                    reachability: aggregateReachability(group))
            }
            .sorted { $0.alias < $1.alias }
    }

    /// Worst-case reachability across a peer's agents. Reads the RAW `reachability`
    /// string (not the boolean `isUnreachable`, which only knows "unreachable"): any
    /// `unreachable` agent → `.offline`, else any `degraded` → `.degraded`, else
    /// `.reachable`. Unknown values read as reachable — the safe "not offline" default.
    static func aggregateReachability(_ agents: [AgentInfo]) -> PeerReachability {
        if agents.contains(where: { $0.reachability == "unreachable" }) { return .offline }
        if agents.contains(where: { $0.reachability == "degraded" }) { return .degraded }
        return .reachable
    }
}
