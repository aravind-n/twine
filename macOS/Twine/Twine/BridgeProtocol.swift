import Foundation

nonisolated enum BridgeCommand: Sendable {
    case ping
    case openFolder(path: String)
    /// Closes the open folder, so the window shows the start page.
    case closeFolder
    case removeRecentFolder(path: String)
    case startTerminal(workingDirectory: String, size: BridgeTerminalSize)
    case closeTerminal(terminalID: UInt64)
}

nonisolated struct BridgeTerminalSize: Codable, Equatable, Sendable {
    let rows: UInt16
    let columns: UInt16
    let pixelWidth: UInt16
    let pixelHeight: UInt16
}

nonisolated struct BridgeCommandReceipt: Decodable, Equatable, Sendable {
    let requestID: UInt64
    let status: Status
    let error: Rejection?

    enum Status: String, Decodable, Sendable {
        case accepted
        case rejected
    }

    struct Rejection: Decodable, Equatable, Sendable {
        let code: String
        let message: String
    }

    private enum CodingKeys: String, CodingKey {
        case error
        case requestID = "requestId"
        case status
    }
}

nonisolated struct BridgeSnapshot: Decodable, Equatable, Sendable {
    var sequence: UInt64
    var state: BridgeApplicationState
    let config: BridgeConfig
    var folders: BridgeFolderState
    var terminals: [BridgeTerminalState] = []
}

nonisolated struct BridgeConfig: Decodable, Equatable, Sendable {
    let appearance: BridgeAppearance

    enum ColorScheme: String, Decodable, Sendable {
        case system
        case light
        case dark
    }
}

nonisolated struct BridgeAppearance: Decodable, Equatable, Sendable {
    let colorScheme: BridgeConfig.ColorScheme

    private enum CodingKeys: String, CodingKey {
        case colorScheme = "color_scheme"
    }
}

nonisolated struct BridgeApplicationState: Decodable, Equatable, Sendable {
    var status: Status

    enum Status: String, Decodable, Sendable {
        case ready
    }
}

/// The open folder and the recent folders the start page lists.
nonisolated struct BridgeFolderState: Decodable, Equatable, Sendable {
    /// The folder the window shows, or `nil` while it shows the start page.
    var openFolder: String?
    /// Recently opened folders, most recent first.
    var recentFolders: [BridgeRecentFolder]
    /// A folder that just failed to open, so the start page can say why it's showing.
    var unavailableFolder: BridgeUnavailableFolder?
}

nonisolated struct BridgeRecentFolder: Decodable, Equatable, Identifiable, Sendable {
    let path: String
    /// Whether nothing, or something other than a folder, is at `path` now. Missing folders stay
    /// listed until removed.
    let isMissing: Bool

    var id: String { path }
}

nonisolated struct BridgeUnavailableFolder: Decodable, Equatable, Sendable {
    let path: String
    let reason: Reason

    enum Reason: String, Decodable, Sendable {
        /// Nothing is at the path, or something other than a folder is.
        case missing
        /// The folder can't be read, for example because Twine doesn't have permission.
        case inaccessible
    }
}

nonisolated struct BridgeEventBatch: Decodable, Sendable {
    let events: [BridgeEvent]
}

nonisolated struct BridgeEvent: Decodable, Equatable, Sendable {
    let sequence: UInt64
    let event: Kind

    enum Kind: Equatable, Sendable {
        case applicationReady
        case commandCompleted(requestID: UInt64, result: BridgeCommandResult)
        case foldersChanged(BridgeFolderState)
        case terminalExited(terminalID: UInt64, exit: BridgeTerminalExit)
        case terminalFailed(terminalID: UInt64, message: String)
    }

    private enum CodingKeys: CodingKey {
        case sequence
        case event
    }

    init(sequence: UInt64, event: Kind) {
        self.sequence = sequence
        self.event = event
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        event = try container.decode(EventPayload.self, forKey: .event).kind
    }
}

nonisolated enum BridgeCommandResult: Equatable, Sendable {
    case pong
    case terminalStarted(terminalID: UInt64)
    case terminalClosed(terminalID: UInt64)
}

nonisolated struct BridgeCommandCompletion: Equatable, Sendable {
    let requestID: UInt64
    let result: BridgeCommandResult
}

nonisolated struct BridgeTerminalChunk: Equatable, Sendable {
    let terminalID: UInt64
    let offset: UInt64
    let bytes: Data
}

nonisolated struct BridgeTerminalExit: Decodable, Equatable, Sendable {
    let exitCode: UInt32
    let signal: String?
}

nonisolated struct BridgeTerminalState: Decodable, Equatable, Sendable {
    let terminalID: UInt64
    let status: Status

    enum Status: Equatable, Sendable {
        case running
        case exited(BridgeTerminalExit)
        case failed(message: String)
    }

    private enum CodingKeys: String, CodingKey {
        case exitCode
        case message
        case signal
        case status
        case terminalID = "terminalId"
    }

    private enum WireStatus: String, Decodable {
        case exited
        case failed
        case running
    }

    init(terminalID: UInt64, status: Status) {
        self.terminalID = terminalID
        self.status = status
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalID = try container.decode(UInt64.self, forKey: .terminalID)
        switch try container.decode(WireStatus.self, forKey: .status) {
        case .running:
            status = .running
        case .exited:
            status = .exited(
                BridgeTerminalExit(
                    exitCode: try container.decode(UInt32.self, forKey: .exitCode),
                    signal: try container.decodeIfPresent(String.self, forKey: .signal)
                )
            )
        case .failed:
            status = .failed(message: try container.decode(String.self, forKey: .message))
        }
    }
}

nonisolated enum BridgeFailure: Error, Equatable, LocalizedError, Sendable {
    case commandRejected(code: String, message: String)
    case cursorExpired
    case empty
    case internalError
    case invalidArgument
    case invalidUTF8
    case malformedCommand
    case nullPointer
    case notConnected
    case panic
    case requestIDOverflow
    case unexpectedCommandResult
    case unknownStatus(UInt32)

    var errorDescription: String? {
        switch self {
        case .commandRejected(let code, let message):
            "The core rejected the command (\(code)): \(message)"
        case .cursorExpired:
            "The bridge event cursor expired."
        case .empty:
            "The bridge has no value available."
        case .internalError:
            "The Rust core reported an internal error."
        case .invalidArgument:
            "The bridge received an invalid argument."
        case .invalidUTF8:
            "The bridge received invalid UTF-8."
        case .malformedCommand:
            "The bridge command was malformed."
        case .nullPointer:
            "The bridge received a null pointer."
        case .notConnected:
            "The Rust core is not connected."
        case .panic:
            "The bridge contained an internal Rust panic."
        case .requestIDOverflow:
            "The bridge request ID counter overflowed."
        case .unexpectedCommandResult:
            "The core returned an unexpected command result."
        case .unknownStatus(let status):
            "The bridge returned unknown status \(status)."
        }
    }
}

nonisolated protocol BridgeTransport: Sendable {
    func open() async throws -> BridgeSnapshot
    func close() async
    func send(_ command: BridgeCommand) async throws -> BridgeCommandReceipt
    func snapshot() async throws -> BridgeSnapshot
    func events(after sequence: UInt64, limit: UInt32) async throws -> [BridgeEvent]
    func nextTerminalChunk() async throws -> BridgeTerminalChunk?
    func writeTerminalInput(terminalID: UInt64, bytes: Data) async throws
    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) async throws
}

nonisolated private struct EventPayload: Decodable {
    let kind: BridgeEvent.Kind

    private enum CodingKeys: String, CodingKey {
        case folders
        case exitCode
        case message
        case requestID = "requestId"
        case result
        case signal
        case terminalID = "terminalId"
        case type
    }

    private enum EventType: String, Decodable {
        case applicationReady
        case commandCompleted
        case foldersChanged
        case terminalExited
        case terminalFailed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .applicationReady:
            kind = .applicationReady
        case .commandCompleted:
            kind = .commandCompleted(
                requestID: try container.decode(UInt64.self, forKey: .requestID),
                result: try container.decode(CommandResultPayload.self, forKey: .result).result
            )
        case .foldersChanged:
            kind = .foldersChanged(try container.decode(BridgeFolderState.self, forKey: .folders))
        case .terminalExited:
            kind = .terminalExited(
                terminalID: try container.decode(UInt64.self, forKey: .terminalID),
                exit: BridgeTerminalExit(
                    exitCode: try container.decode(UInt32.self, forKey: .exitCode),
                    signal: try container.decodeIfPresent(String.self, forKey: .signal)
                )
            )
        case .terminalFailed:
            kind = .terminalFailed(
                terminalID: try container.decode(UInt64.self, forKey: .terminalID),
                message: try container.decode(String.self, forKey: .message)
            )
        }
    }
}

nonisolated private struct CommandResultPayload: Decodable {
    let result: BridgeCommandResult

    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminalId"
        case type
    }

    private enum ResultType: String, Decodable {
        case pong
        case terminalStarted
        case terminalClosed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ResultType.self, forKey: .type) {
        case .pong:
            result = .pong
        case .terminalStarted:
            result = .terminalStarted(
                terminalID: try container.decode(UInt64.self, forKey: .terminalID)
            )
        case .terminalClosed:
            result = .terminalClosed(
                terminalID: try container.decode(UInt64.self, forKey: .terminalID)
            )
        }
    }
}
