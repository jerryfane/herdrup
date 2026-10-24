import SwiftUI
import HerdrKit


/// What the app last saw of each herdr session on the connected machine (#386), kept
/// above the Agents screen so it survives the remount a session switch causes. The
/// screen for the new session starts from it — the pills stay put and the agents show
/// at once — and its first load replaces the copy a moment later.
@MainActor
final class SessionSwitchCache {
    /// A roster older than this is not shown on a switch; the screen loads instead.
    static let rosterFreshFor: TimeInterval = 60

    private(set) var runningSessions: [HerdrSession] = []
    private var rosters: [String: (agents: [AgentInfo], at: Date)] = [:]

    func setRunningSessions(_ sessions: [HerdrSession]) { runningSessions = sessions }

    /// `session` nil is the default session.
    func store(_ agents: [AgentInfo], session: String?, at now: Date = Date()) {
        rosters[Self.key(session)] = (agents, now)
    }

    func roster(for session: String?, now: Date = Date()) -> [AgentInfo]? {
        guard let entry = rosters[Self.key(session)],
              now.timeIntervalSince(entry.at) <= Self.rosterFreshFor else { return nil }
        return entry.agents
    }

    private static func key(_ session: String?) -> String {
        guard let session, session != "default" else { return "default" }
        return session
    }
}

/// Session pills under the Agents search (#353 variant 2, without "All"): one pill per
/// running herdr session, the amber count of agents that need you in it, and a tap
/// switches the app to that session. The caller shows this only with two or more
/// running sessions.
struct SessionPills: View {
    let sessions: [HerdrSession]
    /// The session the app is connected to; nil is the default session.
    let current: String?
    /// Agents that need you, per session name.
    let needsYou: [String: Int]
    let onSelect: (HerdrSession) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions) { session in
                    pill(session)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func isCurrent(_ session: HerdrSession) -> Bool {
        session.default ? (current == nil || current == "default") : session.name == current
    }

    private func pill(_ session: HerdrSession) -> some View {
        let selected = isCurrent(session)
        let count = needsYou[session.name] ?? 0
        return Button {
            guard !selected else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(session)
        } label: {
            HStack(spacing: 7) {
                Text(session.name)
                    .font(Typography.app(15, .medium))
                    .foregroundStyle(selected ? Palette.ground : Palette.text)
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(Typography.app(12, .bold))
                        .foregroundStyle(Color(hex: 0x231603))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Palette.waiting))
                }
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(Capsule().fill(selected ? Palette.text : Palette.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(count > 0 ? "\(session.name), \(count) need you" : session.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "" : "Switches to this herdr session")
    }
}
