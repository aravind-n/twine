import Foundation
import Testing

@testable import Twine

extension BridgeSnapshot {
    /// A ready snapshot with the default config and no folders or terminals.
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

/// Checks `condition` every 10 ms for up to two seconds, and fails the test if it never holds.
@MainActor
func waitUntil(
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    let holds = await condition()
    try #require(holds, sourceLocation: sourceLocation)
}

/// A transport that holds back the Start Terminal completion until the test calls `completeStart`,
/// completes Close Terminal at once, and records the input and resizes it receives.
actor DelayedStartTransport: BridgeTransport {
    private(set) var input = Data()
    private(set) var lastResize: BridgeTerminalSize?
    private var startRequestID: UInt64?
    private var nextRequestID: UInt64 = 1
    private var eventsToDeliver: [BridgeEvent] = []

    var hasStartRequest: Bool {
        startRequestID != nil
    }

    /// Completes the pending Start Terminal command with `terminalID`.
    func completeStart(terminalID: UInt64) {
        guard let startRequestID else { return }
        deliver(.commandCompleted(requestID: startRequestID, result: .terminalStarted(terminalID: terminalID)))
    }

    func open() -> BridgeSnapshot {
        .testReady()
    }

    func close() {}

    func send(_ command: BridgeCommand) -> BridgeCommandReceipt {
        let requestID = nextRequestID
        nextRequestID += 1
        switch command {
        case .startTerminal:
            startRequestID = requestID
        case .closeTerminal(let terminalID):
            deliver(.commandCompleted(requestID: requestID, result: .terminalClosed(terminalID: terminalID)))
        case .ping, .openFolder, .closeFolder, .removeRecentFolder:
            break
        }
        return BridgeCommandReceipt(requestID: requestID, status: .accepted, error: nil)
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

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {
        input.append(bytes)
    }

    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) {
        lastResize = size
    }

    /// Queues an event after the snapshot's sequence and every event queued before it.
    private func deliver(_ event: BridgeEvent.Kind) {
        eventsToDeliver.append(BridgeEvent(sequence: UInt64(eventsToDeliver.count) + 2, event: event))
    }
}
