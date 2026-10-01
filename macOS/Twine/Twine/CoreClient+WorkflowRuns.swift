import Foundation

extension CoreClient {
    func startWorkflowRun(
        workflowID: UInt64, workflowType: CoreWorkflowType.Reference, roles: [CoreRoleLaunch]
    ) async throws {
        try await sendRunCommand(
            .startWorkflowRun(
                workflowID: workflowID, workflowType: workflowType, roles: roles,
                size: .init(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)))
    }

    func completeWorkflowRole(
        workflowID: UInt64, agentID: UInt64, generation: UInt64, signal: CoreCompletionSignal
    ) async throws {
        try await sendRunCommand(
            .completeWorkflowRole(
                workflowID: workflowID, agentID: agentID, generation: generation, signal: signal))
    }

    func cancelWorkflowRun(workflowID: UInt64) async throws {
        try await sendRunCommand(.cancelWorkflowRun(workflowID: workflowID))
    }

    /// Typing to a first-stage agent after completion starts another automatic cycle.
    func continueWorkflowIfNeeded(workflowID: UInt64, agentID: UInt64) async throws {
        guard let run = snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.run,
            let role = run.agents.first(where: { $0.id == agentID })?.role,
            run.workflowType?.definition.stages.first?.roles.contains(role) == true
        else { return }
        try await sendRunCommand(
            .continueWorkflowRun(workflowID: workflowID, agentID: agentID, generation: run.generation))
    }

    private func sendRunCommand(_ command: CoreCommand) async throws {
        let receipt = try await send(command)
        if let error = receipt.error {
            throw CoreFailure.commandRejected(code: error.code, message: error.message)
        }
    }
}
