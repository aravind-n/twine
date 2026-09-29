import Foundation
import SwiftUI
import Testing

@testable import Twine

struct TerminalInputTests {
    @Test @MainActor func inputTypedBeforeTheShellStartsIsSentOnceItHas() async throws {
        let transport = DelayedTerminalStartTransport()
        let client = BridgeClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        let coordinator = TerminalViewRepresentable.Coordinator(
            bridgeClient: client,
            workingDirectory: URL(filePath: "/"),
            terminalID: .constant(nil),
            failureMessage: .constant(nil)
        )
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { coordinator.stop() }

        coordinator.start(view: view)
        for _ in 0..<200 where await !transport.hasStartRequest {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transport.hasStartRequest)

        coordinator.send(source: view, data: Array("ls\r".utf8)[...])
        await transport.completeStart()

        for _ in 0..<200 where await transport.input != Data("ls\r".utf8) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.input == Data("ls\r".utf8))
    }
}

/// A transport that completes Start Terminal only when the test says so.
private actor DelayedTerminalStartTransport: BridgeTransport {
    private(set) var input = Data()
    private var startRequestID: UInt64?
    private var nextRequestID: UInt64 = 1
    private var events: [BridgeEvent] = []

    var hasStartRequest: Bool {
        startRequestID != nil
    }

    func completeStart() {
        guard let startRequestID else { return }
        events.append(
            BridgeEvent(
                sequence: UInt64(events.count) + 2,
                event: .commandCompleted(requestID: startRequestID, result: .terminalStarted(terminalID: 1))
            )
        )
    }

    func open() -> BridgeSnapshot {
        .testReady()
    }

    func close() {}

    func send(_ command: BridgeCommand) -> BridgeCommandReceipt {
        let requestID = nextRequestID
        nextRequestID += 1
        if case .startTerminal = command {
            startRequestID = requestID
        }
        return BridgeCommandReceipt(requestID: requestID, status: .accepted, error: nil)
    }

    func snapshot() -> BridgeSnapshot {
        .testReady()
    }

    func events(after sequence: UInt64, limit: UInt32) -> [BridgeEvent] {
        events.filter { $0.sequence > sequence }.prefix(Int(limit)).map(\.self)
    }

    func nextTerminalChunk() -> BridgeTerminalChunk? {
        nil
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {
        input.append(bytes)
    }

    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) {}
}
