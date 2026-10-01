import Foundation
import Observation

/// One point per Activity step, with the same identity, ordering, lane, and recorded anchor.
nonisolated struct TraceMinimapMarker: Identifiable, Equatable {
    let step: TraceSequenceLayout.Step
    let lane: CoreTraceLane
    let event: CoreTraceEvent
    var id: UInt64 { step.id }
    var anchor: CoreTraceAnchor? { event.anchor }
    var title: String { "\(step.number) · \(step.span.title)" }
}

@MainActor
@Observable
final class TraceMinimapState {
    private(set) var markers: [TraceMinimapMarker] = []
    private(set) var failureMessage: String?
    private var workflowIDs: [UInt64] = []
    private var anchors: [UInt64: CoreTraceEvent] = [:]
    private var generation = 0

    func refresh(activity: TracePanelState, client: CoreClient) async {
        generation += 1
        let readGeneration = generation
        if workflowIDs != activity.workflowIDs {
            workflowIDs = activity.workflowIDs
            anchors = [:]
            markers = []
        }
        let steps = TraceSequenceLayout(spans: activity.spans).steps
        let lanes = activity.lanes
        anchors = anchors.filter { id, _ in steps.contains { $0.id == id } }
        do {
            for step in steps where anchors[step.id] == nil {
                var after: UInt64?
                repeat {
                    let page = try await client.traceEvents(spanID: step.id, after: after)
                    try Task.checkCancellation()
                    guard readGeneration == generation,
                        page.workflowID == lanes.first(where: { $0.id == step.span.laneID })?.workflowID
                    else { return }
                    let event =
                        page.events.first(where: { $0.kind == .workflowEvent && $0.anchor != nil })
                        ?? page.events.first(where: { $0.anchor != nil })
                    if let event {
                        anchors[step.id] = event
                        break
                    }
                    after = page.nextAfter
                } while after != nil
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
            if readGeneration == generation { failureMessage = "Activity markers couldn't load." }
        }
    }
}
