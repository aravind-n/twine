import Foundation
import OSLog
import Observation

private let bridgeLogger = Logger(subsystem: "com.twineproject.Twine", category: "bridge")

enum BridgeConnectionState: Equatable {
    case idle
    case starting
    case running
    case failed(String)
}

@MainActor
@Observable
final class BridgeClient {
    private(set) var connectionState = BridgeConnectionState.idle
    private(set) var snapshot: BridgeSnapshot?
    private(set) var lastCommandCompletion: BridgeCommandCompletion?

    private let transport: any BridgeTransport
    private var eventTask: Task<Void, Never>?
    private var isStopping = false

    init(transport: any BridgeTransport) {
        self.transport = transport
    }

    func start() {
        guard eventTask == nil, !isStopping else { return }

        connectionState = .starting
        eventTask = Task { [weak self] in
            await self?.openAndRun()
        }
    }

    func stop() async {
        guard !isStopping else { return }

        isStopping = true
        let task = eventTask
        task?.cancel()
        await task?.value
        await transport.close()
        eventTask = nil
        snapshot = nil
        lastCommandCompletion = nil
        connectionState = .idle
        isStopping = false
    }

    func send(_ command: BridgeCommand) async throws -> BridgeCommandReceipt {
        try await transport.send(command)
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

    func nextTerminalChunk() async throws -> BridgeTerminalChunk? {
        try await transport.nextTerminalChunk()
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

            switch event.event {
            case .applicationReady:
                current.state = BridgeApplicationState(status: .ready)
            case .commandCompleted(let requestID, let result):
                lastCommandCompletion = BridgeCommandCompletion(requestID: requestID, result: result)
            case .foldersChanged(let folders):
                current.folders = folders
            }
            current.sequence = event.sequence
        }

        snapshot = current
        return true
    }

    private func fail(_ error: any Error) {
        bridgeLogger.error("Bridge failed: \(error.localizedDescription, privacy: .public)")
        connectionState = .failed(error.localizedDescription)
        eventTask?.cancel()
        eventTask = nil
    }
}
