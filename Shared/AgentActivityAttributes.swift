import Foundation
import ActivityKit

/// The shape of Herdrup's fleet Live Activity — shared verbatim by the app
/// (which starts, updates, and ends it) and the widget extension (which renders it).
///
/// Deliberately free of SwiftUI and HerdrKit so it compiles into BOTH targets with no
/// extra dependencies. `State` and `Status` are TYPEALIASES to types declared in
/// AgentActivityState.swift, which avoids ActivityKit so SwiftPM can test them on Linux. The app maps HerdrKit's `AgentGroup` onto
/// `Status` when it builds a state (see `LiveActivityController`); the widget only
/// ever reads these plain values.
///
/// One Live Activity represents the fleet visible through the connected home.
/// Its dynamic state carries the highest-priority agent plus fleet-wide counts;
/// the static host label is only secondary context for that connection.
struct AgentActivityAttributes: ActivityAttributes {
    typealias ContentState = State

    /// Fixed secondary context: the connected home's nickname, or its host name.
    var hostLabel: String

    /// Re-exposed under the names they had while nested here, so `ContentState`,
    /// `AgentActivityAttributes.State` and `AgentActivityAttributes.Status` all keep
    /// resolving for the app and the widget.
    typealias State = AgentActivityState
    typealias Status = AgentActivityStatus
}
