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

    func closeWorkflow(workflowID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.closeWorkflow(workflowID: workflowID))
        guard case .workflowClosed(let closedID) = result, closedID == workflowID else {
            throw BridgeFailure.unexpectedCommandResult
        }
    }
}
