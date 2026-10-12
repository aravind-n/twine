import Foundation

extension CoreClient {
    func terminalStatus(for terminalID: UInt64) -> CoreTerminalState.Status? {
        snapshot?.terminals.first { $0.terminalID == terminalID }?.status
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data, isUserInput: Bool = true) async throws {
        guard terminalStatus(for: terminalID) == .running else { throw CoreFailure.terminalNotRunning }
        if isUserInput {
            try await transport.writeTerminalInput(terminalID: terminalID, bytes: bytes)
        } else {
            try await transport.writeTerminalResponse(terminalID: terminalID, bytes: bytes)
        }
    }

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) async throws {
        guard terminalStatus(for: terminalID) == .running else { throw CoreFailure.terminalNotRunning }
        try await transport.resizeTerminal(terminalID: terminalID, size: size)
    }
    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async throws -> CoreTranscriptPage? {
        try await transport.terminalTranscript(terminalID: terminalID, offset: offset, limit: limit)
    }
    func startTerminal(
        workingDirectory: URL,
        size: CoreTerminalSize
    ) async throws -> UInt64 {
        let result = try await sendAndAwaitCompletion(
            .startTerminal(workingDirectory: workingDirectory.path, size: size)
        )
        guard case .terminalStarted(let terminalID) = result else {
            throw CoreFailure.unexpectedCommandResult
        }
        return terminalID
    }
    func closeTerminal(terminalID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.closeTerminal(terminalID: terminalID))
        guard case .terminalClosed(let closedID) = result, closedID == terminalID else {
            throw CoreFailure.unexpectedCommandResult
        }
        terminalChunkRouter.markClosed(terminalID)
    }
}
