//
//  TwineTests.swift
//  TwineTests
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

import AppKit
import MetalKit
import SwiftTerm
import SwiftUI
import Testing

@testable import Twine

struct TwineTests {
    @Test(arguments: [BridgeConfig.ColorScheme.system, .light, .dark])
    func configSnapshotDecodes(colorScheme: BridgeConfig.ColorScheme) throws {
        let json = """
            {"sequence":1,"state":{"status":"ready"},
             "config":{"appearance":{"color_scheme":"\(colorScheme.rawValue)"}},
             "folders":{"openFolder":null,"recentFolders":[],"unavailableFolder":null},
             "terminals":[]}
            """
        let snapshot = try JSONDecoder().decode(BridgeSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.config.appearance.colorScheme == colorScheme)
    }

    @Test func bridgeRoundTrip() async throws {
        let dataDirectory = TemporaryPath()
        let worker = BridgeWorker(dataDirectory: dataDirectory.url)
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
        let transport = SuspendedOpenBridgeTransport()
        let client = BridgeClient(transport: transport)

        client.start()
        client.start()
        // Wait for the first open to begin. It stays suspended until `stop()` cancels it, so the
        // client is still starting however slowly the test runs.
        for _ in 0..<200 {
            if await transport.openCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await transport.openCount == 1)
        #expect(client.connectionState == .starting)

        await client.stop()
        #expect(client.connectionState == .idle)

        client.start()
        try await waitUntilRunning(client)
        #expect(await transport.openCount == 2)
        await client.stop()
    }

    @Test @MainActor func heavyBridgeTrafficYieldsMainActor() async throws {
        let dataDirectory = TemporaryPath()
        let client = BridgeClient(transport: BridgeWorker(dataDirectory: dataDirectory.url))
        client.start()
        var heartbeat = 0
        var heartbeatTask: Task<Void, Never>?
        var heartbeatAdvancedWithEvents = false

        do {
            try await waitUntilRunning(client)

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

    @Test @MainActor func terminalBridgeRunsShellInRequestedDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            component: "twine-terminal-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let client = BridgeClient(
            transport: BridgeWorker(dataDirectory: directory.appending(component: ".twine-data"))
        )
        client.start()
        var terminalID: UInt64?
        do {
            try await waitUntilRunning(client)
            terminalID = try await client.startTerminal(
                workingDirectory: directory,
                size: BridgeTerminalSize(
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
        from client: BridgeClient,
        terminalID: UInt64
    ) async throws -> (Data, BridgeTerminalExit) {
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
        throw BridgeFailure.internalError
    }

    @Test @MainActor func terminalEnablesMetalWhenAvailable() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MetalTerminalView(frame: frame)
        window.contentView = terminal

        #expect(terminal.isUsingMetalRenderer)
    }

    @Test @MainActor func terminalAppliesResizeReceivedDuringStartup() async throws {
        let transport = DelayedTerminalBridgeTransport()
        let client = BridgeClient(transport: transport)
        client.start()
        try await waitUntilRunning(client)

        var boundTerminalID: UInt64?
        var failureMessage: String?
        let coordinator = TerminalViewRepresentable.Coordinator(
            bridgeClient: client,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            terminalID: Binding(
                get: { boundTerminalID },
                set: { boundTerminalID = $0 }
            ),
            failureMessage: Binding(
                get: { failureMessage },
                set: { failureMessage = $0 }
            )
        )
        let terminal = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        coordinator.start(view: terminal)
        for _ in 0..<100 where !(await transport.didReceiveStart) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transport.didReceiveStart)

        coordinator.sizeChanged(source: terminal, newCols: 120, newRows: 40)
        await transport.completeStart()
        for _ in 0..<100 where await transport.lastResize == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let resize = try #require(await transport.lastResize)
        #expect(resize.columns == 120)
        #expect(resize.rows == 40)
        #expect(boundTerminalID == 41)
        #expect(failureMessage == nil)

        coordinator.stop()
        try await Task.sleep(for: .milliseconds(20))
        await client.stop()
    }

    @MainActor
    private func waitUntilRunning(_ client: BridgeClient) async throws {
        for _ in 0..<100 where client.connectionState != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(client.connectionState == .running)
    }

    @MainActor
    private func recordConcurrentProgress(
        client: BridgeClient,
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
private actor SuspendedOpenBridgeTransport: BridgeTransport {
    private(set) var openCount = 0

    func open() async throws -> BridgeSnapshot {
        openCount += 1
        if openCount == 1 {
            try await Task.sleep(for: .seconds(3_600))
        }
        return snapshot()
    }

    func close() {}

    func send(_ command: BridgeCommand) -> BridgeCommandReceipt {
        BridgeCommandReceipt(requestID: 1, status: .accepted, error: nil)
    }

    func snapshot() -> BridgeSnapshot {
        BridgeSnapshot(
            sequence: 1,
            state: BridgeApplicationState(status: .ready),
            config: BridgeConfig(appearance: .init(colorScheme: .system)),
            folders: BridgeFolderState(openFolder: nil, recentFolders: [], unavailableFolder: nil)
        )
    }

    func events(after sequence: UInt64, limit: UInt32) -> [BridgeEvent] {
        []
    }

    func nextTerminalChunk() -> BridgeTerminalChunk? {
        nil
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) {}
}

private actor DelayedTerminalBridgeTransport: BridgeTransport {
    private(set) var didReceiveStart = false
    private(set) var lastResize: BridgeTerminalSize?
    private var eventsToDeliver: [BridgeEvent] = []
    private var nextRequestID: UInt64 = 1

    func open() -> BridgeSnapshot {
        .testReady()
    }

    func close() {}

    func send(_ command: BridgeCommand) -> BridgeCommandReceipt {
        let requestID = nextRequestID
        nextRequestID += 1
        switch command {
        case .startTerminal:
            didReceiveStart = true
        case .closeTerminal(let terminalID):
            eventsToDeliver.append(
                BridgeEvent(
                    sequence: UInt64(eventsToDeliver.count) + 3,
                    event: .commandCompleted(
                        requestID: requestID,
                        result: .terminalClosed(terminalID: terminalID)
                    )
                )
            )
        case .ping, .openFolder, .closeFolder, .removeRecentFolder:
            break
        }
        return BridgeCommandReceipt(requestID: requestID, status: .accepted, error: nil)
    }

    func completeStart() {
        eventsToDeliver.append(
            BridgeEvent(
                sequence: 2,
                event: .commandCompleted(requestID: 1, result: .terminalStarted(terminalID: 41))
            )
        )
    }

    func snapshot() -> BridgeSnapshot {
        .testReady()
    }

    func events(after sequence: UInt64, limit: UInt32) -> [BridgeEvent] {
        eventsToDeliver.filter { $0.sequence > sequence }.prefix(Int(limit)).map(\.self)
    }

    func nextTerminalChunk() -> BridgeTerminalChunk? {
        nil
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) {
        lastResize = size
    }
}
