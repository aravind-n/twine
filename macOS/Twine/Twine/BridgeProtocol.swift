import Foundation

nonisolated enum BridgeCommand: Sendable {
    case ping
    case openFolder(path: String)
    /// Closes the open folder, so the window shows the start page.
    case closeFolder
    case closeFolderIfOpen(path: String)
    case removeRecentFolder(path: String)
    case refreshGitBranch(folder: String)
    case createSession(folder: String, name: String)
    case renameSession(sessionID: UInt64, name: String)
    case selectSession(sessionID: UInt64)
    case deleteSession(sessionID: UInt64)
    /// `roles` names one agent each, in order; only `agents` workflows have them.
    case createWorkflow(
        folder: String, sessionID: UInt64? = nil, kind: BridgeWorkflow.Kind, roles: [String] = [],
        size: BridgeTerminalSize)
    case activateWorkflow(workflowID: UInt64)
    case nameDraftWorkflow(workflowID: UInt64, name: String)
    case closeWorkflow(workflowID: UInt64)
    case startAgent(workflowID: UInt64, harness: BridgeHarness, prompt: String, size: BridgeTerminalSize)
    case cancelAgent(workflowID: UInt64)
    case startWorkflowRun(
        workflowID: UInt64, workflowType: BridgeWorkflowType.Reference, prompt: String,
        roles: [BridgeRoleLaunch], size: BridgeTerminalSize)
    case completeWorkflowRole(workflowID: UInt64, agentID: UInt64, generation: UInt64, signal: BridgeCompletionSignal)
    case cancelWorkflowRun(workflowID: UInt64)
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
    var traces: [BridgeTraceSummary] = []
    var workflowTypes: [BridgeWorkflowType]?
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
    var currentBranch: String?
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
        case traceChanged(BridgeTraceSummary)
        case workflowsChanged(BridgeWorkflowState)
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
    case sessionCreated(sessionID: UInt64)
    case sessionRenamed(sessionID: UInt64)
    case sessionSelected(sessionID: UInt64)
    case sessionDeleted(sessionID: UInt64)
    case workflowCreated(workflowID: UInt64)
    case workflowActivated(workflowID: UInt64)
    case workflowClosed(workflowID: UInt64)
    case agentStarted(workflowID: UInt64)
    case agentCancelled(workflowID: UInt64)
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
        case summary
        case workflows
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
        case traceChanged
        case commandCompleted
        case foldersChanged
        case workflowsChanged
        case workflowChanged
        case terminalClosed
        case terminalExited
        case terminalFailed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .traceChanged:
            kind = .traceChanged(try container.decode(BridgeTraceSummary.self, forKey: .summary))
        case .applicationReady:
            kind = .applicationReady
        case .commandCompleted:
            kind = .commandCompleted(
                requestID: try container.decode(UInt64.self, forKey: .requestID),
                result: try container.decode(CommandResultPayload.self, forKey: .result).result
            )
        case .workflowsChanged:
            kind = .workflowsChanged(try container.decode(BridgeWorkflowState.self, forKey: .workflows))
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
        case sessionID = "sessionId"
        case workflowID = "workflowId"
        case terminalID = "terminalId"
        case type
    }

    private enum ResultType: String, Decodable {
        case sessionCreated, sessionRenamed, sessionSelected, sessionDeleted
        case pong
        case workflowCreated
        case workflowActivated
        case workflowClosed
        case agentStarted
        case agentCancelled
        case terminalStarted
        case terminalClosed
    }

    private static func workflowResult(_ type: ResultType, workflowID: UInt64) throws -> BridgeCommandResult {
        switch type {
        case .workflowCreated: .workflowCreated(workflowID: workflowID)
        case .workflowActivated: .workflowActivated(workflowID: workflowID)
        case .workflowClosed: .workflowClosed(workflowID: workflowID)
        case .agentStarted: .agentStarted(workflowID: workflowID)
        case .agentCancelled: .agentCancelled(workflowID: workflowID)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "\(type) is not a workflow result"))
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ResultType.self, forKey: .type)
        switch type {
        case .sessionCreated:
            result = .sessionCreated(sessionID: try container.decode(UInt64.self, forKey: .sessionID))
        case .sessionRenamed:
            result = .sessionRenamed(sessionID: try container.decode(UInt64.self, forKey: .sessionID))
        case .sessionSelected:
            result = .sessionSelected(sessionID: try container.decode(UInt64.self, forKey: .sessionID))
        case .sessionDeleted:
            result = .sessionDeleted(sessionID: try container.decode(UInt64.self, forKey: .sessionID))
        case .workflowCreated, .workflowActivated, .workflowClosed, .agentStarted, .agentCancelled:
            result = try Self.workflowResult(type, workflowID: try container.decode(UInt64.self, forKey: .workflowID))
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

// Trace metadata was added after the original state protocol; tolerate snapshots without it.
extension BridgeSnapshot {
    nonisolated private enum CodingKeys: String, CodingKey {
        case sequence, state, config, folders, terminals, workflows, traces, workflowTypes
    }
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sequence: try container.decode(UInt64.self, forKey: .sequence),
            state: try container.decode(BridgeApplicationState.self, forKey: .state),
            config: try container.decode(BridgeConfig.self, forKey: .config),
            folders: try container.decode(BridgeFolderState.self, forKey: .folders),
            terminals: try container.decodeIfPresent([BridgeTerminalState].self, forKey: .terminals) ?? [],
            workflows: try container.decodeIfPresent(BridgeWorkflowState.self, forKey: .workflows) ?? .init(),
            traces: try container.decodeIfPresent([BridgeTraceSummary].self, forKey: .traces) ?? [],
            workflowTypes: try container.decodeIfPresent([BridgeWorkflowType].self, forKey: .workflowTypes))
    }
}
