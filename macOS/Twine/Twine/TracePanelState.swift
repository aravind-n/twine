import Foundation
import Observation

@MainActor
@Observable
final class TracePanelState {
    var workflowID: UInt64? { workflowIDs.first }
    private(set) var workflowIDs: [UInt64] = []
    private var cursors: [UInt64: UInt64] = [:]
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
        workflowIDs = workflowID.map { [$0] } ?? []
        cursors = [:]
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
        await refresh(workflowIDs: workflowID.map { [$0] } ?? [], client: client)
    }

    func refresh(workflowIDs: [UInt64], client: CoreClient) async {
        if self.workflowIDs != workflowIDs {
            reset(workflowID: workflowIDs.first)
            self.workflowIDs = workflowIDs
        }
        guard !workflowIDs.isEmpty else { return }
        readGeneration &+= 1
        let generation = readGeneration
        isLoading = true
        defer { if generation == readGeneration { isLoading = false } }
        do {
            var loaded: [CoreTraceSpan] = []
            var loadedCursors: [UInt64: UInt64] = [:]
            var loadedLanes: [CoreTraceLane] = []
            for workflowID in workflowIDs {
                let laneIDs = Set(lanes.filter { $0.workflowID == workflowID }.map(\.id))
                let count = spans.filter { laneIDs.contains($0.laneID) }.count
                let pageCount = max(1, (count + 199) / 200)
                let page = try await readPages(workflowID: workflowID, count: pageCount, client: client)
                guard generation == readGeneration, self.workflowIDs == workflowIDs else { return }
                loaded.append(contentsOf: page.spans)
                loadedLanes.append(contentsOf: page.lanes)
                loadedCursors[workflowID] = page.nextBefore
            }
            spans = loaded.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
            lanes = loadedLanes
            cursors = loadedCursors
            nextBefore = cursors.values.min()
            failureMessage = nil
            if selectedSpan == nil { selectedSpanID = nil }
        } catch is CancellationError {
            return
        } catch {
            if generation == readGeneration { failureMessage = error.localizedDescription }
        }
    }

    private struct Pages {
        let spans: [CoreTraceSpan]
        let lanes: [CoreTraceLane]
        let nextBefore: UInt64?
    }

    private func readPages(workflowID: UInt64, count: Int, client: CoreClient) async throws -> Pages {
        var spans: [CoreTraceSpan] = []
        var lanes: [CoreTraceLane] = []
        var before: UInt64?
        for _ in 0..<count {
            let page = try await client.workflowTrace(workflowID: workflowID, before: before)
            try Task.checkCancellation()
            spans.append(contentsOf: page.spans)
            lanes = page.lanes
            before = page.nextBefore
            if before == nil { break }
        }
        return Pages(spans: spans, lanes: lanes, nextBefore: before)
    }

    func loadOlder(client: CoreClient) async {
        guard !cursors.isEmpty, !isLoading else { return }
        let workflowIDs = self.workflowIDs
        readGeneration &+= 1
        let generation = readGeneration
        isLoading = true
        defer { if generation == readGeneration { isLoading = false } }
        do {
            var loaded: [CoreTraceSpan] = []
            var loadedLanes = lanes
            var loadedCursors = cursors
            for workflowID in workflowIDs {
                guard let before = cursors[workflowID] else { continue }
                let page = try await client.workflowTrace(workflowID: workflowID, before: before)
                try Task.checkCancellation()
                guard generation == readGeneration, self.workflowIDs == workflowIDs else { return }
                loaded.append(contentsOf: page.spans)
                loadedLanes.removeAll { $0.workflowID == workflowID }
                loadedLanes.append(contentsOf: page.lanes)
                loadedCursors[workflowID] = page.nextBefore
            }
            let known = Set(spans.map(\.id))
            spans = (spans + loaded.filter { !known.contains($0.id) }).sorted {
                $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
            }
            lanes = loadedLanes
            cursors = loadedCursors
            nextBefore = cursors.values.min()
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
                page.workflowID == selectedLane?.workflowID
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
        let events = try await completeEvents(spanID: spanID, client: client)
        let lines =
            ["\(laneName) — \(span.title)"]
            + events.map {
                "\(TraceFormatting.timestamp($0.timestamp)) [\($0.kind.label)] \($0.message)"
            }
        return lines.joined(separator: "\n")
    }

    /// Freeze one event snapshot so navigation includes the ending without chasing ongoing work.
    func completeEvents(spanID: UInt64, client: CoreClient) async throws -> [CoreTraceEvent] {
        var events: [CoreTraceEvent] = []
        var after: UInt64?
        var revision: UInt64?
        repeat {
            let page = try await client.traceEvents(spanID: spanID, after: after)
            try Task.checkCancellation()
            if revision == nil { revision = page.revision }
            events.append(contentsOf: page.events.filter { $0.id <= (revision ?? page.revision) })
            after = page.nextAfter
            if let after, after >= (revision ?? page.revision) { break }
        } while after != nil
        return events
    }
}
