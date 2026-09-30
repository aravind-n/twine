import Foundation
import Observation

nonisolated struct TraceTerminalTarget: Equatable, Identifiable, Sendable {
    let id = UUID()
    let workflowID: UInt64
    let agentID: UInt64?
    let anchor: CoreTraceAnchor
    let timestamp: UInt64
    let message: String
}

@MainActor
@Observable
final class TraceTerminalNavigation {
    var target: TraceTerminalTarget?

    func jump(to event: CoreTraceEvent, lane: CoreTraceLane) {
        guard let anchor = event.anchor else { return }
        target = TraceTerminalTarget(
            workflowID: event.workflowID, agentID: lane.agentID, anchor: anchor,
            timestamp: event.timestamp, message: event.message)
    }
}
