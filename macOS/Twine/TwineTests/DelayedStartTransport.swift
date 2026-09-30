import Foundation

@testable import Twine

/// A transport that holds back the Start Terminal completion until the test calls `completeStart`,
/// completes Close Terminal at once, and records the input and resizes it receives.
actor DelayedStartTransport {
    private(set) var input = Data()
    private(set) var closedTerminalIDs: Set<UInt64> = []
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
            closedTerminalIDs.insert(terminalID)
            deliver(.commandCompleted(requestID: requestID, result: .terminalClosed(terminalID: terminalID)))
        case .ping, .openFolder, .closeFolder, .closeFolderIfOpen, .removeRecentFolder, .createWorkflow,
            .activateWorkflow, .closeWorkflow, .nameDraftWorkflow, .refreshGitBranch,
            .createSession, .renameSession, .selectSession, .deleteSession:
            break
        }
        return BridgeCommandReceipt(requestID: requestID, status: .accepted, error: nil)
    }

    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        throw BridgeFailure.invalidArgument
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

// Declaring this conformance on the actor fails to compile in batch mode in Xcode 27.0.
extension DelayedStartTransport: BridgeTransport {}
