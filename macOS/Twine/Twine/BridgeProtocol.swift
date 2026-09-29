import Foundation

nonisolated enum BridgeCommand: Sendable {
    case ping
    case openFolder(path: String)
    /// Closes the open folder, so the window shows the start page.
    case closeFolder
    case closeFolderIfOpen(path: String)
    case removeRecentFolder(path: String)
    case createWorkflow(folder: String, kind: BridgeWorkflow.Kind, size: BridgeTerminalSize)
    case activateWorkflow(workflowID: UInt64)
    case closeWorkflow(workflowID: UInt64)
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
    var workflows = BridgeWorkflowState()
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
        case sessionChanged(BridgeSession)
        case workflowChanged(BridgeWorkflow)
        case commandCompleted(requestID: UInt64, result: BridgeCommandResult)
        case foldersChanged(BridgeFolderState)
        case terminalClosed(terminalID: UInt64)
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
    case workflowCreated(workflowID: UInt64)
    case workflowActivated(workflowID: UInt64)
    case workflowClosed(workflowID: UInt64)
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

nonisolated private struct EventPayload: Decodable {
    let kind: BridgeEvent.Kind

    private enum CodingKeys: String, CodingKey {
        case folders
        case session
        case workflow
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
        case sessionChanged
        case workflowChanged
        case terminalClosed
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
        case .sessionChanged:
            kind = .sessionChanged(try container.decode(BridgeSession.self, forKey: .session))
        case .workflowChanged:
            kind = .workflowChanged(try container.decode(BridgeWorkflow.self, forKey: .workflow))
        case .foldersChanged:
            kind = .foldersChanged(try container.decode(BridgeFolderState.self, forKey: .folders))
        case .terminalClosed:
            kind = .terminalClosed(terminalID: try container.decode(UInt64.self, forKey: .terminalID))
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
        case workflowID = "workflowId"
        case terminalID = "terminalId"
        case type
    }

    private enum ResultType: String, Decodable {
        case pong
        case workflowCreated
        case workflowActivated
        case workflowClosed
        case terminalStarted
        case terminalClosed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ResultType.self, forKey: .type) {
        case .workflowCreated:
            result = .workflowCreated(workflowID: try container.decode(UInt64.self, forKey: .workflowID))
        case .workflowActivated:
            result = .workflowActivated(workflowID: try container.decode(UInt64.self, forKey: .workflowID))
        case .workflowClosed:
            result = .workflowClosed(workflowID: try container.decode(UInt64.self, forKey: .workflowID))
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

/// A command as the core's JSON protocol expects it, tagged with the request ID its completion event
/// carries.
nonisolated struct CommandEnvelope: Encodable {
    private let requestID: UInt64
    private let command: CommandPayload

    private enum CodingKeys: String, CodingKey {
        case command
        case requestID = "requestId"
    }

    init(requestID: UInt64, command: BridgeCommand) {
        self.requestID = requestID
        self.command = CommandPayload(command)
    }
}

nonisolated private struct CommandPayload: Encodable {
    var type: String
    var path: String?
    var folder: String?
    var kind: BridgeWorkflow.Kind?
    var workflowID: UInt64?
    var workingDirectory: String?
    var size: BridgeTerminalSize?
    var terminalID: UInt64?

    private enum CodingKeys: String, CodingKey {
        case path, folder, kind, size, type, workingDirectory
        case terminalID = "terminalId"
        case workflowID = "workflowId"
    }

    init(_ command: BridgeCommand) {
        switch command {
        case .ping:
            type = "ping"
        case .openFolder(let path):
            type = "openFolder"
            self.path = path
        case .closeFolder:
            type = "closeFolder"
        case .closeFolderIfOpen(let path):
            type = "closeFolderIfOpen"
            self.path = path
        case .removeRecentFolder(let path):
            type = "removeRecentFolder"
            self.path = path
        case .createWorkflow(let folder, let kind, let size):
            type = "createWorkflow"
            self.folder = folder
            self.kind = kind
            self.size = size
        case .activateWorkflow(let workflowID):
            type = "activateWorkflow"
            self.workflowID = workflowID
        case .closeWorkflow(let workflowID):
            type = "closeWorkflow"
            self.workflowID = workflowID
        case .startTerminal(let workingDirectory, let size):
            type = "startTerminal"
            self.workingDirectory = workingDirectory
            self.size = size
        case .closeTerminal(let terminalID):
            type = "closeTerminal"
            self.terminalID = terminalID
        }
    }
}
