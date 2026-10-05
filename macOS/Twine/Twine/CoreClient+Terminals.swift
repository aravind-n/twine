import Foundation

extension CoreClient {
    func applyTerminalEvent(_ event: CoreEvent.Kind, to snapshot: inout CoreSnapshot) {
        switch event {
        case .terminalClosed(let terminalID):
            markTerminalClosed(terminalID, in: &snapshot)
        case .terminalExited(let terminalID, let exit):
            updateTerminal(
                CoreTerminalState(terminalID: terminalID, status: .exited(exit)),
                in: &snapshot
            )
        case .terminalFailed(let terminalID, let message):
            updateTerminal(
                CoreTerminalState(terminalID: terminalID, status: .failed(message: message)),
                in: &snapshot
            )
        default:
            break
        }
    }

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
}
