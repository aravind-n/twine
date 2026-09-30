import Foundation

extension BridgeClient {
    func nameDraftWorkflow(workflowID: UInt64, name: String) async throws {
        let receipt = try await send(.nameDraftWorkflow(workflowID: workflowID, name: name))
        if let error = receipt.error {
            throw BridgeFailure.commandRejected(code: error.code, message: error.message)
        }
    }

    func createWorkflow(
        folder: String,
        sessionID: UInt64? = nil,
        kind: BridgeWorkflow.Kind = .terminal,
        size: BridgeTerminalSize = .init(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)
    ) async throws -> UInt64 {
        let result = try await sendAndAwaitCompletion(
            .createWorkflow(folder: folder, sessionID: sessionID, kind: kind, size: size))
        guard case .workflowCreated(let workflowID) = result else {
            throw BridgeFailure.unexpectedCommandResult
        }
        return workflowID
    }

    func activateWorkflow(workflowID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.activateWorkflow(workflowID: workflowID))
        guard case .workflowActivated(let activatedID) = result, activatedID == workflowID else {
            throw BridgeFailure.unexpectedCommandResult
        }
    }

    func startAgent(
        workflowID: UInt64,
        harness: BridgeHarness,
        prompt: String,
        size: BridgeTerminalSize = .init(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)
    ) async throws {
        let result = try await sendAndAwaitCompletion(
            .startAgent(workflowID: workflowID, harness: harness, prompt: prompt, size: size))
        guard case .agentStarted(let startedID) = result, startedID == workflowID else {
            throw BridgeFailure.unexpectedCommandResult
        }
    }

    func cancelAgent(workflowID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.cancelAgent(workflowID: workflowID))
        guard case .agentCancelled(let cancelledID) = result, cancelledID == workflowID else {
            throw BridgeFailure.unexpectedCommandResult
        }
    }

    func closeWorkflow(workflowID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.closeWorkflow(workflowID: workflowID))
        guard case .workflowClosed(let closedID) = result, closedID == workflowID else {
            throw BridgeFailure.unexpectedCommandResult
        }
    }
}

extension BridgeFailure {
    /// The agent ended on its own just as it was cancelled, so there is nothing left to cancel.
    var isAgentNotRunning: Bool {
        if case .commandRejected(let code, _) = self { code == "agentNotRunning" } else { false }
    }
}

extension BridgeClient {
    func markTerminalRunning(_ terminalID: UInt64, in snapshot: inout BridgeSnapshot) {
        terminalChunkRouter.markStarted(terminalID)
        updateTerminal(BridgeTerminalState(terminalID: terminalID, status: .running), in: &snapshot)
    }

    func markTerminalClosed(_ terminalID: UInt64, in snapshot: inout BridgeSnapshot) {
        terminalChunkRouter.markClosed(terminalID)
        snapshot.terminals.removeAll { $0.terminalID == terminalID }
    }
}
