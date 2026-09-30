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
    let activity = TracePanelState()
    let minimap = TraceMinimapState()
    var requestedSpanID: UInt64?
    var selectionRevision = UUID()

    func selectSpan(_ id: UInt64) {
        activity.selectedSpanID = id
        requestedSpanID = id
        selectionRevision = UUID()
    }

    func jumpToSelectedSpan() {
        guard let id = requestedSpanID, activity.selectedSpanID == id,
            let span = activity.selectedSpan, let lane = activity.selectedLane
        else { return }
        if activity.events.contains(where: { $0.message == "Command started." && $0.anchor != nil }) {
            jump(toCommand: span, events: activity.events, lane: lane)
        } else if let event = activity.events.first(where: { $0.anchor != nil }) {
            jump(to: event, lane: lane)
        } else if let marker = minimap.markers.first(where: { $0.id == id }) {
            jump(to: marker.event, lane: lane)
        }
        requestedSpanID = nil
    }

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
