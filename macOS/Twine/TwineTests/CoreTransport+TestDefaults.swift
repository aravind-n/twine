@testable import Twine

// Existing terminal-only doubles do not service trace reads. Trace tests supply their own reads.
extension CoreTransport {
    func workflowTrace(workflowID: UInt64, before: UInt64?, limit: UInt32) async throws -> CoreWorkflowTracePage {
        throw CoreFailure.unexpectedCommandResult
    }
    func traceEvents(spanID: UInt64, after: UInt64?, limit: UInt32) async throws -> CoreTraceEventsPage {
        throw CoreFailure.unexpectedCommandResult
    }
}
