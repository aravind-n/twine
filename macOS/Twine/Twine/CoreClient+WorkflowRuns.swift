import Foundation

extension CoreClient {
    func startWorkflowRun(
        workflowID: UInt64, workflowType: CoreWorkflowType.Reference,
        prompt: String, roles: [CoreRoleLaunch]
    ) async throws {
        try await sendRunCommand(
            .startWorkflowRun(
                workflowID: workflowID, workflowType: workflowType, prompt: prompt, roles: roles,
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

    private func sendRunCommand(_ command: CoreCommand) async throws {
        let receipt = try await send(command)
        if let error = receipt.error {
            throw CoreFailure.commandRejected(code: error.code, message: error.message)
        }
    }
}
