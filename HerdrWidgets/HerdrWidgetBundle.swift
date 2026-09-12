import SwiftUI
import WidgetKit

/// The widget extension's entry point. It contains the fleet Live Activity
/// (Dynamic Island + Lock Screen banner); no Home Screen widgets.
@main
struct HerdrWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
    }
}
