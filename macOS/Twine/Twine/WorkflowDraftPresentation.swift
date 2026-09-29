import Observation

/// Shares an activation request between choosing Terminal and the ordered terminal input queue.
@Observable
final class WorkflowDraftPresentation {
    private var activation: Task<Void, any Error>?

    func activate(client: BridgeClient, workflowID: UInt64) async throws {
        if let activation {
            try await activation.value
            return
        }
        guard client.snapshot?.workflows.workflows.contains(where: { $0.id == workflowID && $0.kind == .draft }) == true
        else { return }
        let activation = Task { try await client.activateWorkflow(workflowID: workflowID) }
        self.activation = activation
        defer { self.activation = nil }
        try await activation.value
    }
}
