import Foundation

@testable import Twine

actor DeferredMemoryTransport: CoreTransport {
    private var catalogs: [CheckedContinuation<CoreMemoryCatalog, any Error>] = []
    private var reads: [CheckedContinuation<CoreMemoryRead, any Error>] = []

    func memoryCatalog(_ request: CoreMemoryRequest) async throws -> CoreMemoryCatalog {
        try await withCheckedThrowingContinuation { catalogs.append($0) }
    }
    func memoryRead(_ request: CoreMemoryRequest) async throws -> CoreMemoryRead {
        try await withCheckedThrowingContinuation { reads.append($0) }
    }
    func completeCatalog(_ index: Int, result: Result<CoreMemoryCatalog, any Error>) {
        catalogs[index].resume(with: result)
    }
    func completeRead(_ index: Int, result: Result<CoreMemoryRead, any Error>) {
        reads[index].resume(with: result)
    }
    func waitForCatalogs(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while catalogs.count < count {
            guard ContinuousClock.now < deadline else { throw CoreFailure.failed("No memory catalog request arrived.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func waitForReads(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reads.count < count {
            guard ContinuousClock.now < deadline else { throw CoreFailure.failed("No memory read request arrived.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func open() throws -> CoreSnapshot { throw CoreFailure.unexpectedCommandResult }
    func close() {}
    func send(_ command: CoreCommand) throws -> CoreCommandReceipt { throw CoreFailure.unexpectedCommandResult }
    func snapshot() throws -> CoreSnapshot { throw CoreFailure.unexpectedCommandResult }
    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        throw CoreFailure.unexpectedCommandResult
    }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] { [] }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) throws { throw CoreFailure.unexpectedCommandResult }
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) throws { throw CoreFailure.unexpectedCommandResult }
}
