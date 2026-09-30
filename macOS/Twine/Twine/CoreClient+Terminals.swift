import Foundation

extension CoreClient {
    func terminalStatus(for terminalID: UInt64) -> CoreTerminalState.Status? {
        snapshot?.terminals.first { $0.terminalID == terminalID }?.status
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) async throws {
        try await transport.writeTerminalInput(terminalID: terminalID, bytes: bytes)
    }

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) async throws {
        try await transport.resizeTerminal(terminalID: terminalID, size: size)
    }
}
