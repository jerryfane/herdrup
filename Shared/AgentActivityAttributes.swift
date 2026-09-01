import Foundation
import ActivityKit

/// The shape of the Herdr agent-session Live Activity — shared verbatim by the app
/// (which starts / updates / ends it) and the widget extension (which renders it).
///
/// Deliberately free of SwiftUI and HerdrKit so it compiles into BOTH targets with no
/// extra dependencies. `State` and `Status` are TYPEALIASES to types declared in
/// AgentActivityState.swift, which avoids ActivityKit so SwiftPM can test them on Linux. The app maps HerdrKit's `AgentGroup` onto
/// `Status` when it builds a state (see `LiveActivityController`); the widget only
/// ever reads these plain values.
///
/// One Live Activity represents ONE SSH session (one machine). Its dynamic
/// `ContentState` summarises the session's agents: a representative *headline* agent
/// (the highest-priority one — something that needs you outranks something merely
/// working, which outranks idle) plus counts, so the surface can say "2 need you".
struct AgentActivityAttributes: ActivityAttributes {
    typealias ContentState = State

    /// Fixed for the life of the activity: which machine this session is on
    /// (the saved host's nickname if it has one, else the host itself).
    var hostLabel: String

    /// Re-exposed under the names they had while nested here, so `ContentState`,
    /// `AgentActivityAttributes.State` and `AgentActivityAttributes.Status` all keep
    /// resolving for the app and the widget.
    typealias State = AgentActivityState
    typealias Status = AgentActivityStatus
}
