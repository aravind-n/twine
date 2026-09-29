//
//  TwineTests.swift
//  TwineTests
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

import AppKit
import MetalKit
import SwiftTerm
import Testing

@testable import Twine

struct TwineTests {
    @Test(arguments: [BridgeConfig.ColorScheme.system, .light, .dark])
    func configSnapshotDecodes(colorScheme: BridgeConfig.ColorScheme) throws {
        let json = """
            {"sequence":1,"state":{"status":"ready"},
             "config":{"appearance":{"color_scheme":"\(colorScheme.rawValue)"}}}
            """
        let snapshot = try JSONDecoder().decode(BridgeSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.config.appearance.colorScheme == colorScheme)
    }

    @Test func bridgeRoundTrip() async throws {
        let worker = BridgeWorker()
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
        let client = BridgeClient()
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

    @Test @MainActor func terminalEnablesMetalWhenAvailable() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MetalTerminalView(frame: frame)
        window.contentView = terminal

        #expect(terminal.isUsingMetalRenderer)
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
            config: BridgeConfig(appearance: .init(colorScheme: .system))
        )
    }

    func events(after sequence: UInt64, limit: UInt32) -> [BridgeEvent] {
        []
    }

    func nextTerminalChunk() -> BridgeTerminalChunk? {
        nil
    }
}
