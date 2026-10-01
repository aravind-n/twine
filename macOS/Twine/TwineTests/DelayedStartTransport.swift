import Foundation

@testable import Twine

/// A transport that holds back the Start Terminal completion until the test calls `completeStart`,
/// completes Close Terminal at once, and records the input and resizes it receives.
actor DelayedStartTransport {
    private let initialSnapshot: CoreSnapshot
    private(set) var input = Data()
    private(set) var closedTerminalIDs: Set<UInt64> = []
    private(set) var lastResize: CoreTerminalSize?
    private(set) var inputAttempts = 0
    private var inputFailure: CoreFailure?
    private var output: [CoreTerminalChunk] = []
    private var transcript = Data()
    private var holdsTranscript = false
    private var transcriptWaiter: CheckedContinuation<Void, Never>?
    var hasTranscriptRequest: Bool { transcriptWaiter != nil }
    private var holdsResize = false
    private var resizeWaiter: CheckedContinuation<Void, Never>?
    private(set) var resizeAttempts: [CoreTerminalSize] = []
    var hasPendingResize: Bool { resizeWaiter != nil }
    private var startRequestID: UInt64?
    private var nextRequestID: UInt64 = 1
    private var eventsToDeliver: [CoreEvent] = []
    /// The harnesses whose models were requested, in order.
    private(set) var modelRequests: [CoreHarness] = []
    private var modelFailures: [CoreHarness: CoreFailure] = [:]

    init(snapshot: CoreSnapshot = .testReady()) {
        initialSnapshot = snapshot
    }

    var hasStartRequest: Bool {
        startRequestID != nil
    }

    /// Completes the pending Start Terminal command with `terminalID`.
    func completeStart(terminalID: UInt64) {
        guard let startRequestID else { return }
        deliver(.commandCompleted(requestID: startRequestID, result: .terminalStarted(terminalID: terminalID)))
    }

    func open() -> CoreSnapshot {
        initialSnapshot
    }

    func close() {}

    func send(_ command: CoreCommand) -> CoreCommandReceipt {
        let requestID = nextRequestID
        nextRequestID += 1
        switch command {
        case .startTerminal:
            startRequestID = requestID
        case .closeTerminal(let terminalID):
            closedTerminalIDs.insert(terminalID)
            deliver(.commandCompleted(requestID: requestID, result: .terminalClosed(terminalID: terminalID)))
        case .validateWorkflowType, .saveWorkflowType, .ping, .openFolder, .closeFolder, .closeFolderIfOpen,
            .removeRecentFolder, .createWorkflow,
            .activateWorkflow, .closeWorkflow, .startAgent, .cancelAgent, .nameDraftWorkflow, .refreshGitBranch,
            .createSession, .renameSession, .selectSession, .deleteSession,
            .startWorkflowRun, .completeWorkflowRole, .cancelWorkflowRun:
            break
        }
        return CoreCommandReceipt(requestID: requestID, status: .accepted, error: nil)
    }

    /// Makes listing `harness`'s models throw, or succeed again when `failure` is nil.
    func failModels(_ harness: CoreHarness, with failure: CoreFailure?) {
        modelFailures[harness] = failure
    }

    func harnessModels(_ request: HarnessModelsRequest) throws -> CoreHarnessModelsResult {
        modelRequests.append(request.harness)
        if let failure = modelFailures[request.harness] { throw failure }
        return .listed(.init(models: [], allowsCustom: false, efforts: [], supportsYolo: true))
    }

    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult {
        throw CoreFailure.invalidArgument
    }

    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        throw CoreFailure.invalidArgument
    }

    func snapshot() -> CoreSnapshot {
        initialSnapshot
    }

    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] {
        eventsToDeliver.filter { $0.sequence > sequence }.prefix(Int(limit)).map(\.self)
    }

    func nextTerminalChunk() -> CoreTerminalChunk? {
        output.isEmpty ? nil : output.removeFirst()
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) throws {
        inputAttempts += 1
        if let inputFailure { throw inputFailure }
        input.append(bytes)
    }

    func failInput(with failure: CoreFailure) {
        inputFailure = failure
    }

    func enqueueOutput(_ chunk: CoreTerminalChunk) {
        output.append(chunk)
    }

    func exitTerminal(_ terminalID: UInt64) {
        deliver(.terminalExited(terminalID: terminalID, exit: .init(exitCode: 0, signal: nil)))
    }

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) async {
        resizeAttempts.append(size)
        if holdsResize { await withCheckedContinuation { resizeWaiter = $0 } }
        lastResize = size
    }

    func holdResizes() { holdsResize = true }

    func releaseResize() {
        holdsResize = false
        resizeWaiter?.resume()
        resizeWaiter = nil
    }

    func holdTranscript(_ bytes: Data) {
        transcript = bytes
        holdsTranscript = true
    }

    func releaseTranscript() {
        holdsTranscript = false
        transcriptWaiter?.resume()
        transcriptWaiter = nil
    }

    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async -> CoreTranscriptPage? {
        if holdsTranscript { await withCheckedContinuation { transcriptWaiter = $0 } }
        let end = min(transcript.count, Int(offset) + Int(limit))
        return .init(
            offset: offset, nextOffset: UInt64(end), endOffset: UInt64(transcript.count),
            sizes: offset == 0 && end > 0 ? [.init(offset: 0, rows: 24, columns: 80)] : [],
            bytes: transcript.subdata(in: Int(offset)..<end), replayAvailable: true)
    }

    /// Queues an event after the snapshot's sequence and every event queued before it.
    private func deliver(_ event: CoreEvent.Kind) {
        eventsToDeliver.append(CoreEvent(sequence: UInt64(eventsToDeliver.count) + 2, event: event))
    }
}

// Declaring this conformance on the actor fails to compile in batch mode in Xcode 27.0.
extension DelayedStartTransport: CoreTransport {}
