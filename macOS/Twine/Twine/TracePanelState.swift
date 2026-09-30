import Foundation
import Observation

@MainActor
@Observable
final class TracePanelState {
    private(set) var workflowID: UInt64?
    private(set) var lanes: [CoreTraceLane] = []
    private(set) var spans: [CoreTraceSpan] = []
    private(set) var events: [CoreTraceEvent] = []
    private(set) var nextBefore: UInt64?
    private(set) var nextAfter: UInt64?
    private(set) var isLoading = false
    private(set) var isLoadingEvents = false
    private(set) var failureMessage: String?
    private(set) var logFailureMessage: String?
    var selectedSpanID: UInt64?
    private var readGeneration: UInt64 = 0
    private var logGeneration: UInt64 = 0

    var selectedSpan: CoreTraceSpan? { spans.first { $0.id == selectedSpanID } }
    var selectedLane: CoreTraceLane? { lanes.first { $0.id == selectedSpan?.laneID } }

    func reset(workflowID: UInt64?) {
        readGeneration &+= 1
        logGeneration &+= 1
        self.workflowID = workflowID
        lanes = []
        spans = []
        events = []
        nextBefore = nil
        nextAfter = nil
        selectedSpanID = nil
        failureMessage = nil
        logFailureMessage = nil
        isLoading = false
        isLoadingEvents = false
    }

    func refresh(workflowID: UInt64?, client: CoreClient) async {
        if self.workflowID != workflowID { reset(workflowID: workflowID) }
        guard let workflowID else { return }
        readGeneration &+= 1
        let generation = readGeneration
        let pageCount = max(1, (spans.count + 199) / 200)
        isLoading = true
        defer { if generation == readGeneration { isLoading = false } }
        do {
            var loaded: [CoreTraceSpan] = []
            var before: UInt64?
            var loadedLanes: [CoreTraceLane] = []
            for _ in 0..<pageCount {
                let page = try await client.workflowTrace(workflowID: workflowID, before: before)
                try Task.checkCancellation()
                guard generation == readGeneration, self.workflowID == workflowID else { return }
                loaded.append(contentsOf: page.spans)
                loadedLanes = page.lanes
                before = page.nextBefore
                if before == nil { break }
            }
            spans = loaded.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
            lanes = loadedLanes
            nextBefore = before
            failureMessage = nil
            if selectedSpan == nil { selectedSpanID = nil }
        } catch is CancellationError {
            return
        } catch {
            if generation == readGeneration { failureMessage = error.localizedDescription }
        }
    }

    func loadOlder(client: CoreClient) async {
        guard let workflowID, let before = nextBefore, !isLoading else { return }
        readGeneration &+= 1
        let generation = readGeneration
        isLoading = true
        defer { if generation == readGeneration { isLoading = false } }
        do {
            let page = try await client.workflowTrace(workflowID: workflowID, before: before)
            try Task.checkCancellation()
            guard generation == readGeneration, self.workflowID == workflowID else { return }
            let known = Set(spans.map(\.id))
            spans = (spans + page.spans.filter { !known.contains($0.id) }).sorted {
                $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
            }
            lanes = page.lanes
            nextBefore = page.nextBefore
            failureMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if generation == readGeneration { failureMessage = error.localizedDescription }
        }
    }

    func loadEvents(client: CoreClient, more: Bool = false) async {
        if more && (isLoadingEvents || nextAfter == nil) { return }
        logGeneration &+= 1
        let generation = logGeneration
        guard let span = selectedSpan else {
            events = []
            nextAfter = nil
            logFailureMessage = nil
            isLoadingEvents = false
            return
        }
        let after = more ? nextAfter : nil
        if !more {
            events = []
            nextAfter = nil
        }
        logFailureMessage = nil
        isLoadingEvents = true
        defer { if generation == logGeneration { isLoadingEvents = false } }
        do {
            let page = try await client.traceEvents(spanID: span.id, after: after)
            try Task.checkCancellation()
            guard generation == logGeneration, selectedSpanID == span.id,
                page.workflowID == workflowID
            else { return }
            let known = Set(events.map(\.id))
            events.append(contentsOf: page.events.filter { !known.contains($0.id) })
            nextAfter = page.nextAfter
        } catch is CancellationError {
            return
        } catch {
            if generation == logGeneration, selectedSpanID == span.id { logFailureMessage = error.localizedDescription }
        }
    }

    /// Copy reads the entire selected span, independently of the visible log's pagination.
    func completeLog(spanID: UInt64, client: CoreClient) async throws -> String {
        guard let span = spans.first(where: { $0.id == spanID }) else { throw CoreFailure.invalidArgument }
        let laneName = lanes.first { $0.id == span.laneID }?.name ?? "Activity"
        var lines = ["\(laneName) — \(span.title)"]
        var after: UInt64?
        var revision: UInt64?
        repeat {
            let page = try await client.traceEvents(spanID: spanID, after: after)
            try Task.checkCancellation()
            if revision == nil { revision = page.revision }
            for event in page.events where event.id <= (revision ?? page.revision) {
                lines.append("\(TraceFormatting.timestamp(event.timestamp)) [\(event.kind.label)] \(event.message)")
            }
            after = page.nextAfter
            if let after, after >= (revision ?? page.revision) { break }
        } while after != nil
        return lines.joined(separator: "\n")
    }
}
