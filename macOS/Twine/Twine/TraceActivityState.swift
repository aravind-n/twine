import Foundation
import Observation

nonisolated enum TraceViewMode: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case inDepth = "In Depth"
    var id: Self { self }
    var expandedHeight: CGFloat { self == .overview ? TracesLayout.expandedHeight : 432 }
}

@MainActor
@Observable
final class TraceActivityState {
    private(set) var spanID: UInt64?
    private(set) var activities: [CoreTraceActivity] = []
    private(set) var nextAfter: UInt64?
    private(set) var isLoading = false
    private(set) var failureMessage: String?
    var selectedActivityID: UInt64?
    var collapsed: Set<UInt64> = []
    var search = ""
    var failuresOnly = false
    private var generation: UInt64 = 0
    private var pageCount = 1

    var selectedActivity: CoreTraceActivity? { activities.first { $0.id == selectedActivityID } }

    func reset() {
        generation &+= 1
        spanID = nil
        activities = []
        nextAfter = nil
        isLoading = false
        failureMessage = nil
        selectedActivityID = nil
        collapsed = []
        search = ""
        failuresOnly = false
        pageCount = 1
    }

    /// Refresh every loaded page: a tool's ending updates its existing identity.
    func refresh(spanID: UInt64?, workflowID: UInt64?, client: CoreClient, more: Bool = false) async {
        if self.spanID != spanID {
            reset()
            self.spanID = spanID
        }
        guard let spanID, let workflowID else { return }
        if more && (isLoading || nextAfter == nil) { return }
        // Keep a user's pagination request when a live refresh supersedes this read.
        pageCount += more ? 1 : 0
        generation &+= 1
        let generation = generation
        let requestedPages = pageCount
        isLoading = true
        defer { if self.generation == generation { isLoading = false } }
        do {
            let loaded = try await readPages(
                spanID: spanID, workflowID: workflowID, count: requestedPages,
                generation: generation, client: client)
            guard self.generation == generation else { return }
            var known: Set<UInt64> = []
            activities = loaded.activities.filter { known.insert($0.id).inserted }
            nextAfter = loaded.nextAfter
            pageCount = max(1, loaded.count)
            failureMessage = nil
            if selectedActivity == nil { selectedActivityID = nil }
        } catch is CancellationError {
            return
        } catch {
            if self.generation == generation { failureMessage = error.localizedDescription }
        }
    }

    private struct Pages {
        let activities: [CoreTraceActivity]
        let nextAfter: UInt64?
        let count: Int
    }

    private func readPages(
        spanID: UInt64, workflowID: UInt64, count: Int, generation: UInt64, client: CoreClient
    ) async throws -> Pages {
        var loaded: [CoreTraceActivity] = []
        var after: UInt64?
        var pages = 0
        for _ in 0..<count {
            let page = try await client.traceActivities(spanID: spanID, after: after)
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            guard page.spanID == spanID, page.workflowID == workflowID else {
                throw CoreFailure.unexpectedCommandResult
            }
            loaded.append(contentsOf: page.activities)
            pages += 1
            let previous = after
            after = page.nextAfter
            if after == nil { break }
            if let after, after <= (previous ?? 0) { throw CoreFailure.unexpectedCommandResult }
        }
        return Pages(activities: loaded, nextAfter: after, count: pages)
    }

}
