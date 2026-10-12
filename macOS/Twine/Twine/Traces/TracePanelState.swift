import Foundation
import Observation

@MainActor
@Observable
final class TracePanelState {
    var viewMode: TraceViewMode = .overview
    let activityDetails = TraceActivityState()
    var workflowID: UInt64? { workflowIDs.first }
    private(set) var workflowIDs: [UInt64] = []
    private var cursors: [UInt64: UInt64] = [:]
    private var oldestRequested: [UInt64: UInt64] = [:]
    private(set) var lanes: [CoreTraceLane] = []
    private(set) var spans: [CoreTraceSpan] = []
    private(set) var events: [CoreTraceEvent] = []
    private(set) var nextBefore: UInt64?
    private(set) var nextAfter: UInt64?
    private(set) var isLoading = false
    private(set) var isLoadingEvents = false
    private(set) var failureMessage: String?
    private(set) var logFailureMessage: String?
    var selectedSpanID: UInt64? {
        didSet {
            if selectedSpanID != oldValue {
                activityDetails.reset()
                logGeneration &+= 1
                logPageCount = 1
                events = []
                nextAfter = nil
                logFailureMessage = nil
                isLoadingEvents = false
            }
        }
    }
    private var readGeneration: UInt64 = 0
    private var logGeneration: UInt64 = 0
    private var logPageCount = 1

    var selectedSpan: CoreTraceSpan? { spans.first { $0.id == selectedSpanID } }
    var selectedLane: CoreTraceLane? { lanes.first { $0.id == selectedSpan?.laneID } }

    func reset(workflowID: UInt64?) {
        activityDetails.reset()
        readGeneration &+= 1
        logGeneration &+= 1
        workflowIDs = workflowID.map { [$0] } ?? []
        cursors = [:]
        oldestRequested = [:]
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
                let page = try await readPages(
                    workflowID: workflowID, through: oldestRequested[workflowID], client: client)
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
            retainLoadedBoundaries()
            if selectedSpan == nil { selectedSpanID = nil }
        } catch is CancellationError {
            return
        } catch {
            if generation == readGeneration { failureMessage = error.localizedDescription }
        }
    }

    private func retainLoadedBoundaries() {
        for workflowID in workflowIDs {
            let laneIDs = Set(lanes.filter { $0.workflowID == workflowID }.map(\.id))
            if let oldest = spans.filter({ laneIDs.contains($0.laneID) }).map(\.id).min() {
                oldestRequested[workflowID] = oldest
            }
        }
    }

    private struct Pages {
        let spans: [CoreTraceSpan]
        let lanes: [CoreTraceLane]
        let nextBefore: UInt64?
    }

    private func readPages(workflowID: UInt64, through oldest: UInt64?, client: CoreClient) async throws -> Pages {
        var spans: [CoreTraceSpan] = []
        var lanes: [CoreTraceLane] = []
        var before: UInt64?
        repeat {
            let page = try await client.workflowTrace(workflowID: workflowID, before: before)
            try Task.checkCancellation()
            guard page.summary.workflowID == workflowID else { throw CoreFailure.unexpectedCommandResult }
            spans.append(contentsOf: page.spans)
            lanes = page.lanes
            let previous = before
            before = page.nextBefore
            if before == nil { break }
            if let before, before == 0 || before >= (previous ?? UInt64.max) {
                throw CoreFailure.unexpectedCommandResult
            }
            if let oldest, !spans.contains(where: { $0.id <= oldest }) { continue }
            break
        } while before != nil
        return Pages(spans: spans, lanes: lanes, nextBefore: before)
    }

    func loadOlder(client: CoreClient) async {
        guard !cursors.isEmpty, !isLoading else { return }
        for (workflowID, before) in cursors {
            // Save the user's intent before awaiting; a live refresh can supersede this read.
            oldestRequested[workflowID] = before - 1
        }
        await refresh(workflowIDs: workflowIDs, client: client)
    }

    func loadEvents(client: CoreClient, more: Bool = false) async {
        if more && (isLoadingEvents || nextAfter == nil) { return }
        logPageCount += more ? 1 : 0
        let requestedPages = logPageCount
        logGeneration &+= 1
        let generation = logGeneration
        guard let span = selectedSpan else {
            events = []
            nextAfter = nil
            logFailureMessage = nil
            isLoadingEvents = false
            return
        }
        logFailureMessage = nil
        isLoadingEvents = true
        defer { if generation == logGeneration { isLoadingEvents = false } }
        do {
            let loaded = try await readEventPages(
                spanID: span.id, count: requestedPages, generation: generation, client: client)
            var known: Set<UInt64> = []
            events = loaded.events.filter { known.insert($0.id).inserted }
            nextAfter = loaded.nextAfter
            logPageCount = max(1, loaded.count)
        } catch is CancellationError {
            return
        } catch {
            if generation == logGeneration, selectedSpanID == span.id { logFailureMessage = error.localizedDescription }
        }
    }

    private struct EventPages {
        let events: [CoreTraceEvent]
        let nextAfter: UInt64?
        let count: Int
    }

    private func readEventPages(
        spanID: UInt64, count: Int, generation: UInt64, client: CoreClient
    ) async throws -> EventPages {
        var loaded: [CoreTraceEvent] = []
        var after: UInt64?
        var pageCount = 0
        for _ in 0..<count {
            let page = try await client.traceEvents(spanID: spanID, after: after)
            try Task.checkCancellation()
            guard generation == logGeneration, selectedSpanID == spanID else { throw CancellationError() }
            guard page.spanID == spanID, page.workflowID == selectedLane?.workflowID else {
                throw CoreFailure.unexpectedCommandResult
            }
            loaded.append(contentsOf: page.events)
            pageCount += 1
            let previous = after
            after = page.nextAfter
            if after == nil { break }
            if let after, after <= (previous ?? 0) { throw CoreFailure.unexpectedCommandResult }
        }
        return EventPages(events: loaded, nextAfter: after, count: pageCount)
    }

    /// Copy reads the entire selected span, independently of the visible log's pagination.
    func completeLog(spanID: UInt64, client: CoreClient) async throws -> String {
        guard let span = spans.first(where: { $0.id == spanID }) else { throw CoreFailure.invalidArgument }
        let laneName = lanes.first { $0.id == span.laneID }?.name ?? "Trace"
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
