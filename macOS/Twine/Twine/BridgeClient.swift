import Foundation
import OSLog
import Observation

private let bridgeLogger = Logger(subsystem: "com.twineproject.Twine", category: "bridge")
private let commandResultCacheLimit = 256

@MainActor
@Observable
final class BridgeClient {
    private(set) var connectionState = BridgeConnectionState.idle
    private(set) var snapshot: BridgeSnapshot?
    private(set) var lastCommandCompletion: BridgeCommandCompletion?

    private let transport: any BridgeTransport
    private var eventTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var isStopping = false
    private var isTerminating = false
    private var commandResults: [UInt64: BridgeCommandResult] = [:]
    private var ignoredCommandResults: Set<UInt64> = []
    private var commandWaiters: [UInt64: CheckedContinuation<BridgeCommandResult, any Error>] = [:]
    private var terminalChunkRouter = TerminalChunkRouter(capacityBytes: 1024 * 1024)
    private var isFetchingTerminalChunk = false

    init(transport: any BridgeTransport) {
        self.transport = transport
    }

    func start() {
        guard eventTask == nil, !isStopping, !isTerminating else { return }

        connectionState = .starting
        eventTask = Task { [weak self] in
            await self?.openAndRun()
        }
    }

    func send(_ command: BridgeCommand) async throws -> BridgeCommandReceipt {
        guard !isStopping, !isTerminating else { throw BridgeFailure.notConnected }
        let receipt = try await transport.send(command)
        if receipt.status == .accepted {
            switch command {
            case .ping, .startTerminal, .closeTerminal, .createWorkflow, .activateWorkflow, .closeWorkflow,
                .createSession, .renameSession, .selectSession, .deleteSession:
                if commandResults.removeValue(forKey: receipt.requestID) == nil {
                    ignoredCommandResults.insert(receipt.requestID)
                }
            case .openFolder, .closeFolder, .closeFolderIfOpen, .removeRecentFolder, .nameDraftWorkflow,
                .refreshGitBranch:
                break
            }
        }
        return receipt
    }

    func nextTerminalChunk(for terminalID: UInt64) async throws -> BridgeTerminalChunk? {
        guard connectionState == .running else { throw BridgeFailure.notConnected }
        if let chunk = terminalChunkRouter.dequeue(for: terminalID) {
            return chunk
        }
        guard terminalChunkRouter.hasCapacity, !isFetchingTerminalChunk else { return nil }
        isFetchingTerminalChunk = true
        defer { isFetchingTerminalChunk = false }
        guard let chunk = try await transport.nextTerminalChunk() else { return nil }
        guard connectionState == .running, !isStopping else { throw BridgeFailure.notConnected }
        terminalChunkRouter.enqueue(chunk)
        try Task.checkCancellation()
        return terminalChunkRouter.dequeue(for: terminalID)
    }

    func startTerminal(
        workingDirectory: URL,
        size: BridgeTerminalSize
    ) async throws -> UInt64 {
        let result = try await sendAndAwaitCompletion(
            .startTerminal(workingDirectory: workingDirectory.path, size: size)
        )
        guard case .terminalStarted(let terminalID) = result else {
            throw BridgeFailure.unexpectedCommandResult
        }
        return terminalID
    }

    func closeTerminal(terminalID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.closeTerminal(terminalID: terminalID))
        guard case .terminalClosed(let closedID) = result, closedID == terminalID else {
            throw BridgeFailure.unexpectedCommandResult
        }
        terminalChunkRouter.markClosed(terminalID)
    }

    func sendAndAwaitCompletion(_ command: BridgeCommand) async throws -> BridgeCommandResult {
        guard connectionState == .running, !isStopping, !isTerminating else {
            throw BridgeFailure.notConnected
        }
        let receipt = try await transport.send(command)
        guard connectionState == .running else { throw BridgeFailure.notConnected }
        guard receipt.status == .accepted else {
            throw BridgeFailure.commandRejected(
                code: receipt.error?.code ?? "unknown",
                message: receipt.error?.message ?? "The command was rejected."
            )
        }
        if let result = commandResults.removeValue(forKey: receipt.requestID) {
            return result
        }
        return try await withCheckedThrowingContinuation { continuation in
            commandWaiters[receipt.requestID] = continuation
        }
    }

    private func openAndRun() async {
        do {
            let initialSnapshot = try await transport.open()
            guard !Task.isCancelled else { return }
            apply(initialSnapshot)
            connectionState = .running
            await runEventPump()
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    private func runEventPump() async {
        while !Task.isCancelled {
            guard let sequence = snapshot?.sequence else { return }

            do {
                let events = try await transport.events(after: sequence, limit: 128)
                if events.isEmpty {
                    try await Task.sleep(for: .milliseconds(10))
                } else if apply(events) {
                    await Task.yield()
                } else {
                    apply(try await transport.snapshot())
                }
            } catch BridgeFailure.cursorExpired {
                do {
                    apply(try await transport.snapshot())
                } catch {
                    fail(error)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                fail(error)
                return
            }
        }
    }

    private func apply(_ snapshot: BridgeSnapshot) {
        for terminal in self.snapshot?.terminals ?? []
        where !snapshot.terminals.contains(where: { $0.terminalID == terminal.terminalID }) {
            terminalChunkRouter.markClosed(terminal.terminalID)
        }
        self.snapshot = snapshot
    }

    private func apply(_ events: [BridgeEvent]) -> Bool {
        guard var current = snapshot else { return false }

        for event in events {
            if event.sequence <= current.sequence {
                continue
            }
            guard event.sequence == current.sequence + 1 else {
                bridgeLogger.warning(
                    "Event sequence gap: expected \(current.sequence + 1), received \(event.sequence)"
                )
                return false
            }

            apply(event.event, to: &current)
            current.sequence = event.sequence
        }

        snapshot = current
        return true
    }

    private func apply(_ event: BridgeEvent.Kind, to snapshot: inout BridgeSnapshot) {
        switch event {
        case .applicationReady:
            snapshot.state = BridgeApplicationState(status: .ready)
        case .commandCompleted(let requestID, let result):
            applyCommandCompletion(requestID: requestID, result: result, to: &snapshot)
        case .workflowsChanged(let state):
            applyWorkflowState(state, to: &snapshot)
        case .workflowChanged(let workflow):
            applyWorkflow(workflow, to: &snapshot)
        case .foldersChanged(let folders):
            snapshot.folders = folders
        case .terminalClosed(let terminalID):
            terminalChunkRouter.markClosed(terminalID)
            snapshot.terminals.removeAll { $0.terminalID == terminalID }
        case .terminalExited(let terminalID, let exit):
            updateTerminal(
                BridgeTerminalState(terminalID: terminalID, status: .exited(exit)),
                in: &snapshot
            )
        case .terminalFailed(let terminalID, let message):
            updateTerminal(
                BridgeTerminalState(terminalID: terminalID, status: .failed(message: message)),
                in: &snapshot
            )
        }
    }

    private func applyCommandCompletion(
        requestID: UInt64,
        result: BridgeCommandResult,
        to snapshot: inout BridgeSnapshot
    ) {
        lastCommandCompletion = BridgeCommandCompletion(requestID: requestID, result: result)
        switch result {
        case .terminalStarted(let terminalID):
            terminalChunkRouter.markStarted(terminalID)
            updateTerminal(
                BridgeTerminalState(terminalID: terminalID, status: .running),
                in: &snapshot
            )
        case .terminalClosed(let terminalID):
            terminalChunkRouter.markClosed(terminalID)
            snapshot.terminals.removeAll { $0.terminalID == terminalID }
        case .pong, .workflowCreated, .workflowActivated, .workflowClosed,
            .sessionCreated, .sessionRenamed, .sessionSelected, .sessionDeleted:
            break
        }
        if let waiter = commandWaiters.removeValue(forKey: requestID) {
            waiter.resume(returning: result)
        } else if ignoredCommandResults.remove(requestID) != nil {
            return
        } else {
            cacheCommandResult(result, requestID: requestID)
        }
    }

    private func cacheCommandResult(_ result: BridgeCommandResult, requestID: UInt64) {
        commandResults[requestID] = result
        if commandResults.count > commandResultCacheLimit {
            if let oldestRequestID = commandResults.keys.min() {
                commandResults.removeValue(forKey: oldestRequestID)
            }
        }
    }

    private func fail(_ error: any Error) {
        bridgeLogger.error("Bridge failed: \(error.localizedDescription, privacy: .public)")
        connectionState = .failed(error.localizedDescription)
        eventTask?.cancel()
        eventTask = nil
        commandResults.removeAll()
        ignoredCommandResults.removeAll()
        terminalChunkRouter.removeAll()
        failCommandWaiters(with: error)
    }

    private func updateTerminal(_ terminal: BridgeTerminalState, in snapshot: inout BridgeSnapshot) {
        if let index = snapshot.terminals.firstIndex(where: { $0.terminalID == terminal.terminalID }) {
            snapshot.terminals[index] = terminal
        } else {
            snapshot.terminals.append(terminal)
        }
    }

    private func failCommandWaiters(with error: any Error) {
        let waiters = commandWaiters.values
        commandWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}

extension BridgeClient {
    private func applyWorkflowState(_ state: BridgeWorkflowState, to snapshot: inout BridgeSnapshot) {
        for workflow in snapshot.workflows.workflows
        where !state.workflows.contains(where: { $0.id == workflow.id }) {
            terminalChunkRouter.markClosed(workflow.terminalID)
            snapshot.terminals.removeAll { $0.terminalID == workflow.terminalID }
        }
        for workflow in state.workflows
        where !snapshot.workflows.workflows.contains(where: { $0.id == workflow.id }) {
            if workflow.terminalID != 0 {
                terminalChunkRouter.markStarted(workflow.terminalID)
                updateTerminal(
                    BridgeTerminalState(terminalID: workflow.terminalID, status: .running), in: &snapshot)
            }
        }
        snapshot.workflows = state
    }

    private func applyWorkflow(_ workflow: BridgeWorkflow, to snapshot: inout BridgeSnapshot) {
        if workflow.status == .closed {
            snapshot.workflows.workflows.removeAll { $0.id == workflow.id }
            snapshot.terminals.removeAll { $0.terminalID == workflow.terminalID }
            terminalChunkRouter.markClosed(workflow.terminalID)
        } else if let index = snapshot.workflows.workflows.firstIndex(where: { $0.id == workflow.id }) {
            snapshot.workflows.workflows[index] = workflow
        } else {
            snapshot.workflows.workflows.append(workflow)
            terminalChunkRouter.markStarted(workflow.terminalID)
            updateTerminal(BridgeTerminalState(terminalID: workflow.terminalID, status: .running), in: &snapshot)
        }
    }
}

extension BridgeClient {
    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        isStopping = true
        let stopTask = Task { [self] in
            await performStop()
            isStopping = false
            self.stopTask = nil
        }
        self.stopTask = stopTask
        await stopTask.value
    }

    /// Permanently closes the app's bridge connection before AppKit finishes quitting.
    func stopForQuit() async {
        isTerminating = true
        await stop()
    }

    private func performStop() async {
        let task = eventTask
        task?.cancel()
        await task?.value
        await transport.close()
        eventTask = nil
        snapshot = nil
        lastCommandCompletion = nil
        commandResults.removeAll()
        ignoredCommandResults.removeAll()
        terminalChunkRouter.removeAll()
        failCommandWaiters(with: BridgeFailure.notConnected)
        connectionState = .idle
    }
}

extension BridgeClient {
    func pollFiles(_ request: FileBrowserRequest) async throws -> FileBrowserSnapshot? {
        guard connectionState == .running, !isStopping, !isTerminating else { throw BridgeFailure.notConnected }
        return try await transport.pollFiles(request)
    }

    func saveFile(_ request: FileSaveRequest) async throws -> FileSaveResult {
        guard connectionState == .running, !isStopping, !isTerminating else { throw BridgeFailure.notConnected }
        return try await transport.saveFile(request)
    }

    /// Waits until the connection is running. Throws if it fails or the waiting task is cancelled.
    func waitUntilRunning() async throws {
        while true {
            try Task.checkCancellation()
            switch connectionState {
            case .running:
                return
            case .failed(let message):
                throw BridgeFailure.connectionFailed(message)
            case .idle, .starting:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Sends a command whose outcome arrives as state events, logging a rejection or failure.
    func perform(_ command: BridgeCommand) async {
        do {
            let receipt = try await send(command)
            if let rejection = receipt.error {
                bridgeLogger.notice("Command rejected: \(rejection.code, privacy: .public)")
            }
        } catch {
            bridgeLogger.error("Command failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func terminalStatus(for terminalID: UInt64) -> BridgeTerminalState.Status? {
        snapshot?.terminals.first { $0.terminalID == terminalID }?.status
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) async throws {
        try await transport.writeTerminalInput(terminalID: terminalID, bytes: bytes)
    }

    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) async throws {
        try await transport.resizeTerminal(terminalID: terminalID, size: size)
    }
}
