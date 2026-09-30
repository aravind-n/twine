import Foundation

enum BridgeConnectionState: Equatable {
    case idle
    case starting
    case running
    case failed(String)
}

nonisolated enum BridgeFailure: Error, Equatable, LocalizedError, Sendable {
    case commandRejected(code: String, message: String)
    case connectionFailed(String)
    case cursorExpired
    case empty
    case internalError
    case invalidArgument
    case invalidUTF8
    case malformedCommand
    case nullPointer
    case notConnected
    case panic
    case requestIDOverflow
    case unexpectedCommandResult
    case unknownStatus(UInt32)

    var errorDescription: String? {
        switch self {
        case .commandRejected(let code, let message):
            "The core rejected the command (\(code)): \(message)"
        case .connectionFailed(let message):
            "Could not connect to the terminal core: \(message)"
        case .cursorExpired:
            "The bridge event cursor expired."
        case .empty:
            "The bridge has no value available."
        case .internalError:
            "The Rust core reported an internal error."
        case .invalidArgument:
            "The bridge received an invalid argument."
        case .invalidUTF8:
            "The bridge received invalid UTF-8."
        case .malformedCommand:
            "The bridge command was malformed."
        case .nullPointer:
            "The bridge received a null pointer."
        case .notConnected:
            "The Rust core is not connected."
        case .panic:
            "The bridge contained an internal Rust panic."
        case .requestIDOverflow:
            "The bridge request ID counter overflowed."
        case .unexpectedCommandResult:
            "The core returned an unexpected command result."
        case .unknownStatus(let status):
            "The bridge returned unknown status \(status)."
        }
    }
}

nonisolated protocol BridgeTransport: Sendable {
    func open() async throws -> BridgeSnapshot
    func close() async
    func send(_ command: BridgeCommand) async throws -> BridgeCommandReceipt
    func snapshot() async throws -> BridgeSnapshot
    func pollFiles(_ request: FileBrowserRequest) async throws -> FileBrowserSnapshot?
    func saveFile(_ request: FileSaveRequest) async throws -> FileSaveResult
    func events(after sequence: UInt64, limit: UInt32) async throws -> [BridgeEvent]
    func nextTerminalChunk() async throws -> BridgeTerminalChunk?
    func writeTerminalInput(terminalID: UInt64, bytes: Data) async throws
    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) async throws
}
