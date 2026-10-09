import Foundation

extension CoreClient {
    func traceStorage(spanID: UInt64?, operation: UInt32 = 0) async throws -> CoreTraceStorageStatus {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.traceStorage(spanID: spanID, operation: operation)
    }
    func traceDetail(activityID: UInt64, output: Bool, offset: UInt64 = 0) async throws -> CoreTraceDetailPage {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.traceDetail(activityID: activityID, output: output, offset: offset, limit: 64 * 1024)
    }
    func workflowTrace(workflowID: UInt64, before: UInt64? = nil) async throws -> CoreWorkflowTracePage {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.workflowTrace(workflowID: workflowID, before: before, limit: 200)
    }

    func traceEvents(spanID: UInt64, after: UInt64? = nil) async throws -> CoreTraceEventsPage {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.traceEvents(spanID: spanID, after: after, limit: 200)
    }

    func traceActivities(spanID: UInt64, after: UInt64? = nil) async throws -> CoreTraceActivitiesPage {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.traceActivities(spanID: spanID, after: after, limit: 200)
    }
}
