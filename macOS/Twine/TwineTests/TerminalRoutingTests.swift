import Foundation
import SwiftTerm
import Testing

@testable import Twine

extension BridgeSnapshot {
    static func testReady(sequence: UInt64 = 1) -> Self {
        Self(
            sequence: sequence,
            state: BridgeApplicationState(status: .ready),
            config: BridgeConfig(appearance: .init(colorScheme: .system)),
            folders: BridgeFolderState(
                openFolder: nil,
                recentFolders: [],
                unavailableFolder: nil
            )
        )
    }
}

struct TerminalRoutingTests {
    @Test @MainActor func terminalOutputIsDemultiplexedByTerminalID() async throws {
        let transport = InterleavedTerminalBridgeTransport()
        let client = BridgeClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        for _ in 0..<100 where client.connectionState != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(client.connectionState == .running)
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
        let client = BridgeClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        for _ in 0..<100 where client.connectionState != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(client.connectionState == .running)

        let firstRead = Task { try await client.nextTerminalChunk(for: 2) }
        for _ in 0..<100 where await transport.readCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transport.readCount == 1)
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
        let client = BridgeClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        for _ in 0..<100 where client.connectionState != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(client.connectionState == .running)

        let cancelledRead = Task { try await client.nextTerminalChunk(for: 1) }
        for _ in 0..<100 where await transport.readCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transport.readCount == 1)
        cancelledRead.cancel()
        await transport.completeFirstRead(
            with: BridgeTerminalChunk(terminalID: 2, offset: 0, bytes: Data("preserved".utf8))
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
        let client = BridgeClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        for _ in 0..<100 where client.connectionState != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(client.connectionState == .running)

        let pendingRead = Task { try await client.nextTerminalChunk(for: 1) }
        for _ in 0..<100 where await transport.readCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transport.readCount == 1)
        try await client.closeTerminal(terminalID: 1)
        await transport.completeFirstRead(
            with: BridgeTerminalChunk(terminalID: 1, offset: 0, bytes: Data("late".utf8))
        )

        #expect(try await pendingRead.value == nil)
    }
}

@MainActor
final class TerminalTestResponder: NSObject, TerminalViewDelegate {
    private let client: BridgeClient
    private let terminalID: UInt64

    init(client: BridgeClient, terminalID: UInt64) {
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

private actor InterleavedTerminalBridgeTransport: BridgeTransport {
    private var chunks = [
        BridgeTerminalChunk(terminalID: 2, offset: 0, bytes: Data("b0".utf8)),
        BridgeTerminalChunk(terminalID: 1, offset: 0, bytes: Data("a0".utf8)),
        BridgeTerminalChunk(terminalID: 2, offset: 2, bytes: Data("b1".utf8)),
        BridgeTerminalChunk(terminalID: 1, offset: 2, bytes: Data("a1".utf8)),
    ]

    func open() -> BridgeSnapshot {
        .testReady()
    }

    func close() {}

    func send(_ command: BridgeCommand) -> BridgeCommandReceipt {
        BridgeCommandReceipt(requestID: 1, status: .accepted, error: nil)
    }

    func snapshot() -> BridgeSnapshot {
        .testReady()
    }

    func events(after sequence: UInt64, limit: UInt32) -> [BridgeEvent] {
        []
    }

    func nextTerminalChunk() -> BridgeTerminalChunk? {
        chunks.isEmpty ? nil : chunks.removeFirst()
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) {}
}

private actor SuspendedTerminalOutputTransport: BridgeTransport {
    private(set) var readCount = 0
    private var readContinuations: [CheckedContinuation<BridgeTerminalChunk?, Never>] = []
    private var eventsToDeliver: [BridgeEvent] = []
    private var nextRequestID: UInt64 = 1

    func open() -> BridgeSnapshot {
        .testReady()
    }

    func close() {
        for continuation in readContinuations {
            continuation.resume(returning: nil)
        }
        readContinuations.removeAll()
    }

    func send(_ command: BridgeCommand) -> BridgeCommandReceipt {
        let requestID = nextRequestID
        nextRequestID += 1
        if case .closeTerminal(let terminalID) = command {
            eventsToDeliver.append(
                BridgeEvent(
                    sequence: UInt64(eventsToDeliver.count) + 2,
                    event: .commandCompleted(
                        requestID: requestID,
                        result: .terminalClosed(terminalID: terminalID)
                    )
                )
            )
        }
        return BridgeCommandReceipt(requestID: requestID, status: .accepted, error: nil)
    }

    func snapshot() -> BridgeSnapshot {
        .testReady()
    }

    func events(after sequence: UInt64, limit: UInt32) -> [BridgeEvent] {
        eventsToDeliver.filter { $0.sequence > sequence }.prefix(Int(limit)).map(\.self)
    }

    func nextTerminalChunk() async -> BridgeTerminalChunk? {
        readCount += 1
        return await withCheckedContinuation { continuation in
            readContinuations.append(continuation)
        }
    }

    func completePendingReads() async {
        if readContinuations.count > 1 {
            let laterRead = readContinuations.removeLast()
            laterRead.resume(
                returning: BridgeTerminalChunk(
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
            returning: BridgeTerminalChunk(
                terminalID: 1,
                offset: 0,
                bytes: Data("first".utf8)
            )
        )
    }

    func completeFirstRead(with chunk: BridgeTerminalChunk?) {
        guard !readContinuations.isEmpty else { return }
        readContinuations.removeFirst().resume(returning: chunk)
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) {}
}
