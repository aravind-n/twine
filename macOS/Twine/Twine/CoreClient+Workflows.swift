import Foundation

extension CoreClient {
    func nameDraftWorkflow(workflowID: UInt64, name: String) async throws {
        let receipt = try await send(.nameDraftWorkflow(workflowID: workflowID, name: name))
        if let error = receipt.error {
            throw CoreFailure.commandRejected(code: error.code, message: error.message)
        }
    }

    /// Opens a workflow tab. An `agents` workflow starts one agent per role, in order.
    func createWorkflow(
        folder: String,
        sessionID: UInt64? = nil,
        kind: CoreWorkflow.Kind = .terminal,
        roles: [String] = [],
        size: CoreTerminalSize = .init(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)
    ) async throws -> UInt64 {
        let result = try await sendAndAwaitCompletion(
            .createWorkflow(folder: folder, sessionID: sessionID, kind: kind, roles: roles, size: size))
        guard case .workflowCreated(let workflowID) = result else {
            throw CoreFailure.unexpectedCommandResult
        }
        return workflowID
    }

    func activateWorkflow(workflowID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.activateWorkflow(workflowID: workflowID))
        guard case .workflowActivated(let activatedID) = result, activatedID == workflowID else {
            throw CoreFailure.unexpectedCommandResult
        }
    }

    func startAgent(
        workflowID: UInt64,
        harness: CoreHarness,
        size: CoreTerminalSize = .init(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)
    ) async throws {
        let result = try await sendAndAwaitCompletion(
            .startAgent(workflowID: workflowID, harness: harness, size: size))
        guard case .agentStarted(let startedID) = result, startedID == workflowID else {
            throw CoreFailure.unexpectedCommandResult
        }
    }

    func cancelAgent(workflowID: UInt64) async throws {
        if snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.run != nil {
            try await cancelWorkflowRun(workflowID: workflowID)
            return
        }
        let result = try await sendAndAwaitCompletion(.cancelAgent(workflowID: workflowID))
        guard case .agentCancelled(let cancelledID) = result, cancelledID == workflowID else {
            throw CoreFailure.unexpectedCommandResult
        }
    }

    func closeWorkflow(workflowID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.closeWorkflow(workflowID: workflowID))
        guard case .workflowClosed(let closedID) = result, closedID == workflowID else {
            throw CoreFailure.unexpectedCommandResult
        }
    }
}

extension CoreFailure {
    /// The agent ended on its own just as it was cancelled, so there is nothing left to cancel.
    var isAgentNotRunning: Bool {
        if case .commandRejected(let code, _) = self { code == "agentNotRunning" } else { false }
    }
}

extension CoreClient {
    func markTerminalRunning(_ terminalID: UInt64, in snapshot: inout CoreSnapshot) {
        terminalChunkRouter.markStarted(terminalID)
        updateTerminal(CoreTerminalState(terminalID: terminalID, status: .running), in: &snapshot)
    }

    func markTerminalClosed(_ terminalID: UInt64, in snapshot: inout CoreSnapshot) {
        terminalChunkRouter.markClosed(terminalID)
        snapshot.terminals.removeAll { $0.terminalID == terminalID }
    }
}
