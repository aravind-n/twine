@testable import Twine

// Existing terminal-only doubles do not service trace reads. Trace tests supply their own reads.
extension CoreTransport {
    func traceStorage(spanID: UInt64?, operation: UInt32) async throws -> CoreTraceStorageStatus {
        throw CoreFailure.unexpectedCommandResult
    }
    func traceDetail(
        activityID: UInt64, output: Bool, offset: UInt64, limit: UInt32
    ) async throws -> CoreTraceDetailPage {
        throw CoreFailure.unexpectedCommandResult
    }
    func workflowTrace(workflowID: UInt64, before: UInt64?, limit: UInt32) async throws -> CoreWorkflowTracePage {
        throw CoreFailure.unexpectedCommandResult
    }
    func traceActivities(spanID: UInt64, after: UInt64?, limit: UInt32) async throws -> CoreTraceActivitiesPage {
        throw CoreFailure.unexpectedCommandResult
    }
    func traceEvents(spanID: UInt64, after: UInt64?, limit: UInt32) async throws -> CoreTraceEventsPage {
        throw CoreFailure.unexpectedCommandResult
    }
}
