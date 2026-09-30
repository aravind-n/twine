import Foundation

extension BridgeClient {
    func workflowTrace(workflowID: UInt64, before: UInt64? = nil) async throws -> BridgeWorkflowTracePage {
        guard connectionState == .running, !isStopping, !isTerminating else { throw BridgeFailure.notConnected }
        return try await transport.workflowTrace(workflowID: workflowID, before: before, limit: 200)
    }

    func traceEvents(spanID: UInt64, after: UInt64? = nil) async throws -> BridgeTraceEventsPage {
        guard connectionState == .running, !isStopping, !isTerminating else { throw BridgeFailure.notConnected }
        return try await transport.traceEvents(spanID: spanID, after: after, limit: 200)
    }
}
