import AppKit
import Foundation
import Testing

@testable import Twine

struct CoreClientTests {
    @Test(arguments: [CoreConfig.ColorScheme.system, .light, .dark])
    func configSnapshotDecodes(colorScheme: CoreConfig.ColorScheme) throws {
        let json = """
            {"sequence":1,"state":{"status":"ready"},
             "config":{"appearance":{"color_scheme":"\(colorScheme.rawValue)"},
                       "terminal":{"font_family":"Menlo","font_size":15.5}},
             "folders":{"openFolder":null,"recentFolders":[],"unavailableFolder":null},
             "terminals":[],"workflows":{"session":null,"sessions":[],"sessionsInitialized":false,"workflows":[]}}
            """
        let snapshot = try JSONDecoder().decode(CoreSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.config.appearance.colorScheme == colorScheme)
        #expect(snapshot.config.terminal.fontFamily == "Menlo")
        #expect(snapshot.config.terminal.fontSize == 15.5)
    }

    @Test func coreRoundTrip() async throws {
        let dataDirectory = TemporaryPath()
        let worker = CoreWorker(dataDirectory: dataDirectory.url)
        let snapshot = try await worker.open()
        let receipt = try await worker.send(.ping)
        let events = try await worker.events(after: snapshot.sequence, limit: 16)

        #expect(receipt.requestID == 1)
        #expect(receipt.status == .accepted)
        #expect(events.count == 1)
        #expect(events.first?.sequence == snapshot.sequence + 1)
        #expect(events.first?.event == .commandCompleted(requestID: 1, result: .pong))

        await worker.close()
    }

    @Test @MainActor func concurrentStartOpensOneTransport() async throws {
        let transport = SuspendedOpenCoreTransport()
        let client = CoreClient(transport: transport)

        client.start()
        client.start()
        // Wait for the first open to begin. It stays suspended until `stop()` cancels it, so the
        // client is still starting however slowly the test runs.
        try await waitUntil { await transport.openCount > 0 }

        #expect(await transport.openCount == 1)
        #expect(client.runState == .starting)

        await client.stop()
        #expect(client.runState == .idle)

        client.start()
        try await waitUntil { client.runState == .running }
        #expect(await transport.openCount == 2)
        await client.stop()
    }

    @Test @MainActor func heavyCoreTrafficYieldsMainActor() async throws {
        let dataDirectory = TemporaryPath()
        let client = CoreClient(transport: CoreWorker(dataDirectory: dataDirectory.url))
        client.start()
        var heartbeat = 0
        var heartbeatTask: Task<Void, Never>?
        var heartbeatAdvancedWithEvents = false

        do {
            try await waitUntil { client.runState == .running }

            let initialSequence = try #require(client.snapshot?.sequence)
            var observedSequence = initialSequence
            var heartbeatAtLastProgress = heartbeat
            heartbeatTask = Task { @MainActor in
                while !Task.isCancelled {
                    heartbeat += 1
                    await Task.yield()
                }
            }

            for _ in 0..<2_000 {
                _ = try await client.send(.ping)
                recordConcurrentProgress(
                    client: client,
                    heartbeat: heartbeat,
                    observedSequence: &observedSequence,
                    heartbeatAtLastProgress: &heartbeatAtLastProgress,
                    heartbeatAdvancedWithEvents: &heartbeatAdvancedWithEvents
                )
            }

            let targetSequence = initialSequence + 2_000
            for _ in 0..<1_000 where client.snapshot?.sequence != targetSequence {
                try await Task.sleep(for: .milliseconds(10))
                recordConcurrentProgress(
                    client: client,
                    heartbeat: heartbeat,
                    observedSequence: &observedSequence,
                    heartbeatAtLastProgress: &heartbeatAtLastProgress,
                    heartbeatAdvancedWithEvents: &heartbeatAdvancedWithEvents
                )
            }

            #expect(client.snapshot?.sequence == targetSequence)
        } catch {
            heartbeatTask?.cancel()
            await heartbeatTask?.value
            await client.stop()
            throw error
        }

        heartbeatTask?.cancel()
        await heartbeatTask?.value
        await client.stop()

        #expect(heartbeatAdvancedWithEvents)
    }

    @Test @MainActor func waitingForAFailedCoreThrowsItsMessage() async throws {
        let client = CoreClient(transport: FailingOpenTransport())
        client.start()

        await #expect(throws: CoreFailure.failed(CoreFailure.internalError.localizedDescription)) {
            try await client.waitUntilRunning()
        }
        let message = CoreFailure.failed("no database").localizedDescription
        #expect(message == "twine-core failed: no database")
    }

    @Test @MainActor func waitingWhileIdleEndsWhenCoreStartsOrIsCancelled() async throws {
        let client = CoreClient(transport: DelayedStartTransport())
        defer { Task { await client.stop() } }

        let cancelled = Task { try await client.waitUntilRunning() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        let waiting = Task { try await client.waitUntilRunning() }
        try await Task.sleep(for: .milliseconds(50))
        client.start()
        try await waiting.value
        #expect(client.runState == .running)
    }

    @Test @MainActor func appQuitWaitsForCoreTeardownAndStartsItOnce() async throws {
        let transport = SuspendedCloseTransport()
        let client = CoreClient(transport: transport)
        client.start()
        try await waitUntil { client.runState == .running }

        let delegate = AppTerminationDelegate()
        delegate.attach(to: client)
        var replies: [Bool] = []
        let first = delegate.beginTermination { replies.append($0) }
        let second = delegate.beginTermination { replies.append($0) }

        #expect(first == .terminateLater)
        #expect(second == .terminateLater)
        try await waitUntil { await transport.closeCount == 1 }
        #expect(replies.isEmpty)

        await transport.completeClose()
        try await waitUntil { replies == [true] }
        #expect(await transport.closeCount == 1)
        #expect(client.runState == .idle)

        client.start()
        #expect(client.runState == .idle)
    }

    @MainActor
    private func recordConcurrentProgress(
        client: CoreClient,
        heartbeat: Int,
        observedSequence: inout UInt64,
        heartbeatAtLastProgress: inout Int,
        heartbeatAdvancedWithEvents: inout Bool
    ) {
        guard let sequence = client.snapshot?.sequence, sequence > observedSequence else { return }
        if heartbeat > heartbeatAtLastProgress {
            heartbeatAdvancedWithEvents = true
        }
        observedSequence = sequence
        heartbeatAtLastProgress = heartbeat
    }
}

/// A transport whose first open never finishes on its own; only cancellation ends it. Later opens
/// finish at once.
private actor SuspendedOpenCoreTransport: CoreTransport {
    private(set) var openCount = 0

    func open() async throws -> CoreSnapshot {
        openCount += 1
        if openCount == 1 {
            try await Task.sleep(for: .seconds(3_600))
        }
        return snapshot()
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
        nil
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
}

/// A transport whose open always fails.
private actor FailingOpenTransport: CoreTransport {
    func open() throws -> CoreSnapshot {
        throw CoreFailure.internalError
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
        nil
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
}

private actor SuspendedCloseTransport: CoreTransport {
    private(set) var closeCount = 0
    private var closeContinuation: CheckedContinuation<Void, Never>?

    func open() -> CoreSnapshot {
        .testReady()
    }

    func close() async {
        closeCount += 1
        await withCheckedContinuation { continuation in
            closeContinuation = continuation
        }
    }

    func completeClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }

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
        nil
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
}
