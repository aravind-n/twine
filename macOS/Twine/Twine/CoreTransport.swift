import Foundation

enum CoreRunState: Equatable {
    case idle
    case starting
    case running
    case failed(String)
}

nonisolated enum CoreFailure: Error, Equatable, LocalizedError, Sendable {
    case commandRejected(code: String, message: String)
    case failed(String)
    case cursorExpired
    case empty
    case internalError
    case invalidArgument
    case invalidUTF8
    case malformedCommand
    case nullPointer
    case notRunning
    case terminalNotRunning
    case panic
    case requestIDOverflow
    case unexpectedCommandResult
    case unknownStatus(UInt32)

    var errorDescription: String? {
        switch self {
        case .commandRejected(let code, let message):
            "twine-core rejected the command (\(code)): \(message)"
        case .failed(let message):
            "twine-core failed: \(message)"
        case .cursorExpired:
            "The twine-core event cursor expired."
        case .empty:
            "twine-core has no value available."
        case .internalError:
            "twine-core reported an internal error."
        case .invalidArgument:
            "twine-core received an invalid argument."
        case .invalidUTF8:
            "twine-core received invalid UTF-8."
        case .malformedCommand:
            "The twine-core command was malformed."
        case .nullPointer:
            "twine-core received a null pointer."
        case .notRunning:
            "twine-core isn't running."
        case .terminalNotRunning:
            "The terminal process has ended."
        case .panic:
            "twine-core panicked."
        case .requestIDOverflow:
            "The twine-core request ID counter overflowed."
        case .unexpectedCommandResult:
            "twine-core returned an unexpected command result."
        case .unknownStatus(let status):
            "twine-core returned unknown status \(status)."
        }
    }
}

nonisolated protocol CoreTransport: Sendable {
    func open() async throws -> CoreSnapshot
    func close() async
    func send(_ command: CoreCommand) async throws -> CoreCommandReceipt
    func snapshot() async throws -> CoreSnapshot
    func pollFiles(_ request: FileBrowserRequest) async throws -> FileBrowserSnapshot?
    func saveFile(_ request: FileSaveRequest) async throws -> FileSaveResult
    func harnessModels(_ request: HarnessModelsRequest) async throws -> CoreHarnessModelsResult
    func events(after sequence: UInt64, limit: UInt32) async throws -> [CoreEvent]
    func workflowTrace(workflowID: UInt64, before: UInt64?, limit: UInt32) async throws -> CoreWorkflowTracePage
    func traceEvents(spanID: UInt64, after: UInt64?, limit: UInt32) async throws -> CoreTraceEventsPage
    func traceActivities(spanID: UInt64, after: UInt64?, limit: UInt32) async throws -> CoreTraceActivitiesPage
    func nextTerminalChunk() async throws -> CoreTerminalChunk?
    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async throws -> CoreTranscriptPage?
    func writeTerminalInput(terminalID: UInt64, bytes: Data) async throws
    func writeTerminalResponse(terminalID: UInt64, bytes: Data) async throws
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) async throws
}

extension CoreTransport {
    func writeTerminalResponse(terminalID: UInt64, bytes: Data) async throws {
        try await writeTerminalInput(terminalID: terminalID, bytes: bytes)
    }

    /// Test transports without harnesses report that none are installed.
    func harnessModels(_ request: HarnessModelsRequest) async throws -> CoreHarnessModelsResult {
        .failed("\(request.harness.displayName) isn't available.")
    }

    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async throws -> CoreTranscriptPage? {
        throw CoreFailure.unexpectedCommandResult
    }
}
