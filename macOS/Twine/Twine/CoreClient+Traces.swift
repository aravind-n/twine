import Foundation

extension CoreClient {
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
