import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import Twine

struct TerminalRoutingTests {
    @Test @MainActor func terminalOutputIsDemultiplexedByTerminalID() async throws {
        let transport = InterleavedTerminalCoreTransport()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        var firstOutput = Data()
        var secondOutput = Data()
        var firstOffset: UInt64 = 0
        var secondOffset: UInt64 = 0

        for _ in 0..<4 {
            if let chunk = try await client.nextTerminalChunk(for: 1) {
                #expect(chunk.offset == firstOffset)
                firstOffset += UInt64(chunk.bytes.count)
                firstOutput.append(chunk.bytes)
            }
            if let chunk = try await client.nextTerminalChunk(for: 2) {
                #expect(chunk.offset == secondOffset)
                secondOffset += UInt64(chunk.bytes.count)
                secondOutput.append(chunk.bytes)
            }
        }

        #expect(firstOutput == Data("a0a1".utf8))
        #expect(secondOutput == Data("b0b1".utf8))
    }

    @Test @MainActor func terminalOutputUsesOneDestructiveReadAtATime() async throws {
        let transport = SuspendedTerminalOutputTransport()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }

        let firstRead = Task { try await client.nextTerminalChunk(for: 2) }
        try await waitUntil { await transport.readCount > 0 }
        #expect(await transport.readCount == 1)
        let competingRead = Task { try await client.nextTerminalChunk(for: 1) }
        try await Task.sleep(for: .milliseconds(20))
        await transport.completePendingReads()

        #expect(try await competingRead.value == nil)
        #expect(await transport.readCount == 1)
        #expect(try await firstRead.value == nil)
        let routed = try #require(try await client.nextTerminalChunk(for: 1))
        #expect(routed.offset == 0)
        #expect(routed.bytes == Data("first".utf8))
    }

    @Test @MainActor func terminalOutputRoutesForeignChunkBeforeCallerCancellation() async throws {
        let transport = SuspendedTerminalOutputTransport()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }

        let cancelledRead = Task { try await client.nextTerminalChunk(for: 1) }
        try await waitUntil { await transport.readCount > 0 }
        #expect(await transport.readCount == 1)
        cancelledRead.cancel()
        await transport.completeFirstRead(
            with: CoreTerminalChunk(terminalID: 2, offset: 0, bytes: Data("preserved".utf8))
        )

        await #expect(throws: CancellationError.self) {
            try await cancelledRead.value
        }
        let routed = try #require(try await client.nextTerminalChunk(for: 2))
        #expect(routed.offset == 0)
        #expect(routed.bytes == Data("preserved".utf8))
    }

    @Test @MainActor func terminalOutputDiscardsChunkThatArrivesAfterClose() async throws {
        let transport = SuspendedTerminalOutputTransport()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }

        let pendingRead = Task { try await client.nextTerminalChunk(for: 1) }
        try await waitUntil { await transport.readCount > 0 }
        #expect(await transport.readCount == 1)
        try await client.closeTerminal(terminalID: 1)
        await transport.completeFirstRead(
            with: CoreTerminalChunk(terminalID: 1, offset: 0, bytes: Data("late".utf8))
        )

        #expect(try await pendingRead.value == nil)
    }

    @Test @MainActor func terminalCoreRunsShellInRequestedDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            component: "twine-terminal-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let client = CoreClient(
            transport: CoreWorker(dataDirectory: directory.appending(component: ".twine-data"))
        )
        client.start()
        var terminalID: UInt64?
        do {
            try await waitUntil { client.runState == .running }
            terminalID = try await client.startTerminal(
                workingDirectory: directory,
                size: CoreTerminalSize(
                    rows: 24,
                    columns: 80,
                    pixelWidth: 800,
                    pixelHeight: 480
                )
            )
            let startedTerminalID = try #require(terminalID)
            try await client.writeTerminalInput(
                terminalID: startedTerminalID,
                bytes: Data("pwd\nprintf '__TWINE_SWIFT__\\n'\nexit 9\n".utf8)
            )
            let (output, exit) = try await collectTerminalOutput(
                from: client,
                terminalID: startedTerminalID
            )
            let text = String(data: output, encoding: .utf8) ?? ""
            #expect(text.contains(directory.path))
            #expect(text.contains("__TWINE_SWIFT__"))
            #expect(exit.exitCode == 9)

            try await client.closeTerminal(terminalID: startedTerminalID)
            terminalID = nil
            await client.stop()
            try FileManager.default.removeItem(at: directory)
        } catch {
            if let terminalID {
                try? await client.closeTerminal(terminalID: terminalID)
            }
            await client.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @MainActor
    private func collectTerminalOutput(
        from client: CoreClient,
        terminalID: UInt64
    ) async throws -> (Data, CoreTerminalExit) {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let responder = TerminalTestResponder(client: client, terminalID: terminalID)
        terminal.terminalDelegate = responder
        defer { withExtendedLifetime(responder) {} }
        var output = Data()
        var expectedOffset: UInt64 = 0
        for _ in 0..<500 {
            if let chunk = try await client.nextTerminalChunk(for: terminalID) {
                #expect(chunk.terminalID == terminalID)
                #expect(chunk.offset == expectedOffset)
                expectedOffset += UInt64(chunk.bytes.count)
                output.append(chunk.bytes)
                terminal.feed(byteArray: Array(chunk.bytes)[...])
            } else {
                let text = String(data: output, encoding: .utf8) ?? ""
                if text.contains("__TWINE_SWIFT__") {
                    if case .exited(let exit) = client.terminalStatus(for: terminalID) {
                        return (output, exit)
                    }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("shell output and exit were not reported before the timeout")
        throw CoreFailure.internalError
    }

}

@MainActor
final class TerminalTestResponder: NSObject, TerminalViewDelegate {
    private let client: CoreClient
    private let terminalID: UInt64

    init(client: CoreClient, terminalID: UInt64) {
        self.client = client
        self.terminalID = terminalID
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        Task {
            try? await client.writeTerminalInput(terminalID: terminalID, bytes: bytes)
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private actor InterleavedTerminalCoreTransport: CoreTransport {
    private var chunks = [
        CoreTerminalChunk(terminalID: 2, offset: 0, bytes: Data("b0".utf8)),
        CoreTerminalChunk(terminalID: 1, offset: 0, bytes: Data("a0".utf8)),
        CoreTerminalChunk(terminalID: 2, offset: 2, bytes: Data("b1".utf8)),
        CoreTerminalChunk(terminalID: 1, offset: 2, bytes: Data("a1".utf8)),
    ]

    func open() -> CoreSnapshot {
        .testReady()
    }

    func close() {}

    func send(_ command: CoreCommand) -> CoreCommandReceipt {
        CoreCommandReceipt(requestID: 1, status: .accepted, error: nil)
    }

    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult {
        throw CoreFailure.invalidArgument
    }

    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        throw CoreFailure.invalidArgument
    }

    func snapshot() -> CoreSnapshot {
        .testReady()
    }

    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] {
        []
    }

    func nextTerminalChunk() -> CoreTerminalChunk? {
        chunks.isEmpty ? nil : chunks.removeFirst()
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
}

private actor SuspendedTerminalOutputTransport: CoreTransport {
    private(set) var readCount = 0
    private var readContinuations: [CheckedContinuation<CoreTerminalChunk?, Never>] = []
    private var eventsToDeliver: [CoreEvent] = []
    private var nextRequestID: UInt64 = 1

    func open() -> CoreSnapshot {
        .testReady()
    }

    func close() {
        for continuation in readContinuations {
            continuation.resume(returning: nil)
        }
        readContinuations.removeAll()
    }

    func send(_ command: CoreCommand) -> CoreCommandReceipt {
        let requestID = nextRequestID
        nextRequestID += 1
        if case .closeTerminal(let terminalID) = command {
            eventsToDeliver.append(
                CoreEvent(
                    sequence: UInt64(eventsToDeliver.count) + 2,
                    event: .commandCompleted(
                        requestID: requestID,
                        result: .terminalClosed(terminalID: terminalID)
                    )
                )
            )
        }
        return CoreCommandReceipt(requestID: requestID, status: .accepted, error: nil)
    }

    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult {
        throw CoreFailure.invalidArgument
    }

    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        throw CoreFailure.invalidArgument
    }

    func snapshot() -> CoreSnapshot {
        .testReady()
    }

    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] {
        eventsToDeliver.filter { $0.sequence > sequence }.prefix(Int(limit)).map(\.self)
    }

    func nextTerminalChunk() async -> CoreTerminalChunk? {
        readCount += 1
        return await withCheckedContinuation { continuation in
            readContinuations.append(continuation)
        }
    }

    func completePendingReads() async {
        if readContinuations.count > 1 {
            let laterRead = readContinuations.removeLast()
            laterRead.resume(
                returning: CoreTerminalChunk(
                    terminalID: 1,
                    offset: 5,
                    bytes: Data("later".utf8)
                )
            )
            await Task.yield()
        }
        guard !readContinuations.isEmpty else { return }
        let firstRead = readContinuations.removeFirst()
        firstRead.resume(
            returning: CoreTerminalChunk(
                terminalID: 1,
                offset: 0,
                bytes: Data("first".utf8)
            )
        )
    }

    func completeFirstRead(with chunk: CoreTerminalChunk?) {
        guard !readContinuations.isEmpty else { return }
        readContinuations.removeFirst().resume(returning: chunk)
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
}
