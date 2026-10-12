import Foundation
import Observation

/// One point per trace step, with the same identity, ordering, lane, and recorded anchor.
nonisolated struct TraceMinimapMarker: Identifiable, Equatable {
    let step: TraceSequenceLayout.Step
    let lane: CoreTraceLane
    let event: CoreTraceEvent
    var id: UInt64 { step.id }
    var anchor: CoreTraceAnchor? { event.anchor }
    var title: String { "\(step.number) · \(step.span.title)" }
    var inputText: String? { lane.isAgent && event.kind == .workflowEvent ? step.span.title : nil }
}

@MainActor
@Observable
final class TraceMinimapState {
    private(set) var markers: [TraceMinimapMarker] = []
    private(set) var failureMessage: String?
    private var workflowIDs: [UInt64] = []
    private var anchors: [UInt64: CoreTraceEvent] = [:]
    private var anchorSpans: [UInt64: CoreTraceSpan] = [:]
    private var generation = 0

    func refresh(activity: TracePanelState, client: CoreClient) async {
        generation += 1
        let readGeneration = generation
        if workflowIDs != activity.workflowIDs {
            workflowIDs = activity.workflowIDs
            anchors = [:]
            anchorSpans = [:]
            markers = []
        }
        let steps = TraceSequenceLayout(spans: activity.spans).steps
        let lanes = activity.lanes
        anchors = anchors.filter { id, _ in steps.contains { $0.id == id } }
        anchorSpans = anchorSpans.filter { id, _ in steps.contains { $0.id == id } }
        do {
            for step in steps where needsAnchor(for: step.span) {
                guard let lane = lanes.first(where: { $0.id == step.span.laneID }) else { continue }
                let event = try await loadAnchor(spanID: step.id, workflowID: lane.workflowID, client: client)
                guard readGeneration == generation else { return }
                anchors[step.id] = event
                anchorSpans[step.id] = step.span
            }
            markers = steps.compactMap { step in
                guard let event = anchors[step.id], let lane = lanes.first(where: { $0.id == step.span.laneID })
                else { return nil }
                return TraceMinimapMarker(step: step, lane: lane, event: event)
            }
            failureMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if readGeneration == generation { failureMessage = "Trace markers couldn't load." }
        }
    }

    private func needsAnchor(for span: CoreTraceSpan) -> Bool {
        guard let event = anchors[span.id] else { return true }
        guard event.kind != .workflowEvent else { return false }
        return span.isLive || anchorSpans[span.id] != span
    }

    private func loadAnchor(spanID: UInt64, workflowID: UInt64, client: CoreClient) async throws -> CoreTraceEvent? {
        var after: UInt64?
        var fallback: CoreTraceEvent?
        repeat {
            let page = try await client.traceEvents(spanID: spanID, after: after)
            try Task.checkCancellation()
            guard page.workflowID == workflowID else { throw CoreFailure.unexpectedCommandResult }
            if let event = page.events.first(where: { $0.kind == .workflowEvent && $0.anchor != nil }) { return event }
            if fallback == nil { fallback = page.events.first(where: { $0.anchor != nil }) }
            after = page.nextAfter
        } while after != nil
        return fallback
    }
}
