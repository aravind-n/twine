import Foundation
import Observation

nonisolated struct TraceTerminalTarget: Equatable, Identifiable, Sendable {
    let id = UUID()
    let workflowID: UInt64
    let agentID: UInt64?
    let anchor: CoreTraceAnchor
    let timestamp: UInt64
    let message: String
    var outputStartAnchor: CoreTraceAnchor?
    var readToCurrentEnd = false
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

    func jump(toCommand span: CoreTraceSpan, events: [CoreTraceEvent], lane: CoreTraceLane) {
        guard let start = events.first(where: { $0.spanID == span.id && $0.message == "Command started." }),
            let startAnchor = start.anchor
        else { return }
        let ending = events.last(where: {
            $0.spanID == span.id && $0.id != start.id && $0.anchor?.terminalID == startAnchor.terminalID
        })
        target = TraceTerminalTarget(
            workflowID: start.workflowID, agentID: lane.agentID, anchor: ending?.anchor ?? startAnchor,
            timestamp: start.timestamp, message: span.title,
            outputStartAnchor: startAnchor, readToCurrentEnd: ending == nil)
    }
}
