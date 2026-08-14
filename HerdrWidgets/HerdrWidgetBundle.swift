import SwiftUI
import WidgetKit

/// The widget extension's entry point. For now it holds only the agent-session
/// Live Activity (Dynamic Island + lock-screen banner) — no home-screen widgets
/// yet, so the bundle has a single member.
@main
struct HerdrWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
    }
}
