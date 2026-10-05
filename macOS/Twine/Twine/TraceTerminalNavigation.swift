import OSLog
import Observation
import SwiftUI

nonisolated struct TraceTerminalTarget: Equatable, Identifiable, Sendable {
    let id = UUID()
    let workflowID: UInt64
    let agentID: UInt64?
    let anchor: CoreTraceAnchor
    let timestamp: UInt64
    let message: String
    var outputStartAnchor: CoreTraceAnchor?
    var readToCurrentEnd = false
    var inputText: String?
    var scrollAnchor: CoreTraceAnchor { outputStartAnchor ?? anchor }
}

@MainActor
@Observable
final class TraceTerminalNavigation {
    /// Saved output, opened automatically when the live terminal cannot reveal a trace point.
    var target: TraceTerminalTarget? {
        didSet { if target != nil { scrollTarget = nil } }
    }
    var scrollTarget: TraceTerminalTarget?
    var destination: TraceTerminalTarget? { target ?? scrollTarget }
    let activity = TracePanelState()
    let minimap = TraceMinimapState()
    var requestedSpanID: UInt64?
    var selectionRevision = UUID()
    private(set) var laneColors: [UInt64: Color] = [:]
    private(set) var failureMessage: String?

    func updateLaneColors() {
        laneColors = TraceLaneStyle.colors(for: activity.lanes, retaining: laneColors)
    }

    func finishScroll(_ request: TraceTerminalTarget, found: Bool) {
        guard scrollTarget?.id == request.id else { return }
        if !found { target = request }
    }

    func selectSpan(_ id: UInt64) {
        failureMessage = nil
        activity.selectedSpanID = id
        requestedSpanID = id
        selectionRevision = UUID()
    }

    func jumpToSelectedSpan(client: CoreClient) async {
        guard let id = requestedSpanID, activity.selectedSpanID == id,
            let span = activity.selectedSpan, let lane = activity.selectedLane
        else { return }
        do {
            let events =
                activity.nextAfter != nil || activity.logFailureMessage != nil
                ? try await activity.completeEvents(spanID: id, client: client) : activity.events
            try Task.checkCancellation()
            guard requestedSpanID == id, activity.selectedSpanID == id else { return }
            if events.contains(where: { $0.message == "Command started." && $0.anchor != nil }) {
                jump(toCommand: span, events: events, lane: lane)
            } else if events.contains(where: { $0.anchor != nil }) {
                jump(toSpan: span, events: events, lane: lane)
            } else if let marker = minimap.markers.first(where: { $0.id == id }) {
                jump(to: marker.event, lane: lane)
            }
            requestedSpanID = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, requestedSpanID == id, activity.selectedSpanID == id else { return }
            terminalLogger.error("Trace events failed: \(error.localizedDescription, privacy: .public)")
            failureMessage = "Output for this step couldn't load."
        }
    }

    func jump(to event: CoreTraceEvent, lane: CoreTraceLane) {
        guard let anchor = event.anchor else { return }
        target = nil
        scrollTarget = TraceTerminalTarget(
            workflowID: event.workflowID, agentID: lane.agentID, anchor: anchor,
            timestamp: event.timestamp, message: event.message)
    }

    func jump(to activity: CoreTraceActivity, lane: CoreTraceLane, fallbackTime: UInt64) {
        guard let anchor = activity.anchor else { return }
        target = nil
        scrollTarget = TraceTerminalTarget(
            workflowID: lane.workflowID, agentID: lane.agentID, anchor: anchor,
            timestamp: activity.endedAt ?? activity.startedAt ?? fallbackTime, message: activity.title)
    }

    func jump(toCommand span: CoreTraceSpan, events: [CoreTraceEvent], lane: CoreTraceLane) {
        guard let start = events.first(where: { $0.spanID == span.id && $0.message == "Command started." }),
            let startAnchor = start.anchor
        else { return }
        let ending = events.last(where: {
            $0.spanID == span.id && $0.id != start.id && $0.anchor?.terminalID == startAnchor.terminalID
        })
        target = nil
        scrollTarget = TraceTerminalTarget(
            workflowID: start.workflowID, agentID: lane.agentID, anchor: ending?.anchor ?? startAnchor,
            timestamp: start.timestamp, message: span.title,
            outputStartAnchor: startAnchor, readToCurrentEnd: ending == nil)
    }

    func jump(toSpan span: CoreTraceSpan, events: [CoreTraceEvent], lane: CoreTraceLane) {
        let anchored = events.filter { $0.spanID == span.id && $0.anchor != nil }
        // The first prompt can inherit a process-start event at byte zero. A TUI usually
        // clears that launch screen; reveal the prompt's own boundary instead.
        guard let start = anchored.first(where: { $0.kind == .workflowEvent }) ?? anchored.first,
            let startAnchor = start.anchor
        else { return }
        let latest = anchored.last { $0.anchor?.terminalID == startAnchor.terminalID }
        let ending = latest.flatMap { event -> CoreTraceEvent? in
            event.kind == .processExited || event.kind == .processStopped || event.kind == .processFailed
                || event.message.split(separator: "\n").first == "Finished responding"
                || event.message == "Response interrupted by the next prompt." ? event : nil
        }
        // A Stop hook can request continuation. Later tool work reopens that same prompt.
        let resumed = anchored.contains {
            $0.message.split(separator: "\n").first == "Finished responding" && $0.id < (latest?.id ?? 0)
        }
        target = nil
        scrollTarget = TraceTerminalTarget(
            workflowID: start.workflowID, agentID: lane.agentID,
            anchor: ending?.anchor ?? latest?.anchor ?? startAnchor,
            timestamp: start.timestamp, message: span.title, outputStartAnchor: startAnchor,
            readToCurrentEnd: (span.isLive || resumed) && ending == nil,
            inputText: lane.isAgent ? span.title : nil)
    }
}
