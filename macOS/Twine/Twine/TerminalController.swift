import AppKit
import OSLog
import SwiftTerm
import SwiftUI

let terminalLogger = Logger(subsystem: "com.twineproject.Twine", category: "terminal")

/// Feeds a retained terminal view and forwards input and size changes. Workflow shells are owned
/// by Rust; standalone terminals used by bridge clients retain the start/close behavior.
@MainActor
final class TerminalController: NSObject, TerminalViewDelegate {
    private let bridgeClient: BridgeClient
    private let workingDirectory: URL?
    private var terminalID: UInt64?
    private var expectedOffset: UInt64 = 0
    private var lastSize: BridgeTerminalSize?
    private var pendingSize: BridgeTerminalSize?
    private var pendingInput = Data()
    private var task: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var isStopping = false
    private let terminalIDBinding: Binding<UInt64?>
    private let failureMessage: Binding<String?>

    init(
        bridgeClient: BridgeClient,
        workingDirectory: URL,
        terminalID: Binding<UInt64?>,
        failureMessage: Binding<String?>
    ) {
        self.bridgeClient = bridgeClient
        self.workingDirectory = workingDirectory
        terminalIDBinding = terminalID
        self.failureMessage = failureMessage
    }

    init(bridgeClient: BridgeClient, terminalID: UInt64, failureMessage: Binding<String?>) {
        self.bridgeClient = bridgeClient
        workingDirectory = nil
        self.terminalID = terminalID
        terminalIDBinding = .constant(terminalID)
        self.failureMessage = failureMessage
    }

    func start(view: MetalTerminalView) {
        guard task == nil else { return }
        task = Task { [weak self, weak view] in
            guard let self, let view else { return }
            do {
                try await bridgeClient.waitUntilRunning()
                try Task.checkCancellation()

                let size = terminalSize(for: view)
                let terminalID: UInt64
                if let workingDirectory {
                    terminalID = try await bridgeClient.startTerminal(workingDirectory: workingDirectory, size: size)
                } else if let existingID = self.terminalID {
                    terminalID = existingID
                } else {
                    return
                }
                guard !Task.isCancelled, !isStopping else {
                    if workingDirectory != nil {
                        try await bridgeClient.closeTerminal(terminalID: terminalID)
                    }
                    return
                }
                self.terminalID = terminalID
                terminalIDBinding.wrappedValue = terminalID
                lastSize = workingDirectory == nil ? nil : size
                let latestSize = pendingSize ?? terminalSize(for: view)
                pendingSize = nil
                enqueueResize(latestSize, terminalID: terminalID)
                if !pendingInput.isEmpty {
                    enqueueInput(pendingInput, terminalID: terminalID)
                    pendingInput = Data()
                }
                try await pumpOutput(for: terminalID, into: view)
            } catch is CancellationError {
                return
            } catch {
                report(error)
            }
        }
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        task?.cancel()
        task = nil
        inputTask?.cancel()
        inputTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        guard let terminalID else { return }
        self.terminalID = nil
        guard workingDirectory != nil else { return }
        Task {
            do {
                try await bridgeClient.closeTerminal(terminalID: terminalID)
            } catch BridgeFailure.commandRejected {
                // A shell that has already been closed needs no further cleanup.
            } catch BridgeFailure.notConnected {
                // Bridge teardown also terminates all owned shells.
            } catch {
                terminalLogger.error(
                    "Could not close terminal: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !data.isEmpty, !isStopping else { return }
        guard let terminalID else {
            // The terminal takes focus before its shell starts, so hold typing until it has.
            pendingInput.append(contentsOf: data)
            return
        }
        enqueueInput(Data(data), terminalID: terminalID)
    }

    private func enqueueInput(_ bytes: Data, terminalID: UInt64) {
        let precedingWrite = inputTask
        inputTask = Task {
            await precedingWrite?.value
            guard !Task.isCancelled else { return }
            do {
                var lowerBound = bytes.startIndex
                while lowerBound < bytes.endIndex {
                    let upperBound = bytes.index(
                        lowerBound,
                        offsetBy: min(64 * 1024, bytes.distance(from: lowerBound, to: bytes.endIndex))
                    )
                    try Task.checkCancellation()
                    try await bridgeClient.writeTerminalInput(
                        terminalID: terminalID,
                        bytes: bytes.subdata(in: lowerBound..<upperBound)
                    )
                    lowerBound = upperBound
                }
            } catch {
                report(error)
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let size = terminalSize(for: source, columns: newCols, rows: newRows)
        pendingSize = size
        guard let terminalID else { return }
        pendingSize = nil
        enqueueResize(size, terminalID: terminalID)
    }

    private func enqueueResize(_ size: BridgeTerminalSize, terminalID: UInt64) {
        guard size != lastSize else { return }
        lastSize = size
        let precedingResize = resizeTask
        resizeTask = Task {
            await precedingResize?.value
            guard !Task.isCancelled else { return }
            do {
                try await bridgeClient.resizeTerminal(terminalID: terminalID, size: size)
            } catch {
                report(error)
            }
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    private func pumpOutput(for terminalID: UInt64, into view: TerminalView) async throws {
        while !Task.isCancelled {
            if let chunk = try await bridgeClient.nextTerminalChunk(for: terminalID) {
                guard chunk.offset == expectedOffset else {
                    throw TerminalControllerError.offset(
                        expected: expectedOffset,
                        received: chunk.offset
                    )
                }
                expectedOffset += UInt64(chunk.bytes.count)
                view.feed(byteArray: Array(chunk.bytes)[...])
                await Task.yield()
                continue
            }

            // The process-exit event and the PTY reader are supervised independently. Keep
            // polling after exit so bytes already in the PTY cannot be mistaken for EOF.
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func terminalSize(
        for view: TerminalView,
        columns: Int? = nil,
        rows: Int? = nil
    ) -> BridgeTerminalSize {
        let terminal = view.getTerminal()
        let backingSize = view.convertToBacking(view.bounds).size
        return BridgeTerminalSize(
            rows: UInt16(clamping: max(rows ?? terminal.rows, 1)),
            columns: UInt16(clamping: max(columns ?? terminal.cols, 1)),
            pixelWidth: UInt16(clamping: max(Int(backingSize.width.rounded()), 1)),
            pixelHeight: UInt16(clamping: max(Int(backingSize.height.rounded()), 1))
        )
    }

    private func report(_ error: any Error) {
        guard !isStopping else { return }
        terminalLogger.error("Terminal failed: \(error.localizedDescription, privacy: .public)")
        failureMessage.wrappedValue = error.localizedDescription
    }
}

private enum TerminalControllerError: LocalizedError {
    case offset(expected: UInt64, received: UInt64)

    var errorDescription: String? {
        switch self {
        case .offset(let expected, let received):
            "Terminal output was out of order (expected byte \(expected), received \(received))."
        }
    }
}
