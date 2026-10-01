import Foundation

nonisolated enum CoreCommand: Sendable {
    case ping
    case validateWorkflowType(definition: CoreWorkflowType.Definition)
    case saveWorkflowType(source: CoreWorkflowType.Reference?, definition: CoreWorkflowType.Definition)
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
        folder: String, sessionID: UInt64? = nil, kind: CoreWorkflow.Kind, roles: [String] = [],
        size: CoreTerminalSize)
    case activateWorkflow(workflowID: UInt64)
    case nameDraftWorkflow(workflowID: UInt64, name: String)
    case closeWorkflow(workflowID: UInt64)
    /// The agent starts without a prompt and waits for the user in its terminal.
    case startAgent(workflowID: UInt64, choice: HarnessChoice, size: CoreTerminalSize)
    case resumeAgent(workflowID: UInt64, session: String)
    case cancelAgent(workflowID: UInt64)
    /// The first stage's agents ask the user for the task and report it when they finish.
    case startWorkflowRun(
        workflowID: UInt64, workflowType: CoreWorkflowType.Reference, roles: [CoreRoleLaunch],
        size: CoreTerminalSize)
    case completeWorkflowRole(workflowID: UInt64, agentID: UInt64, generation: UInt64, signal: CoreCompletionSignal)
    case cancelWorkflowRun(workflowID: UInt64)
    case startTerminal(workingDirectory: String, size: CoreTerminalSize)
    case closeTerminal(terminalID: UInt64)
}

nonisolated struct CoreTerminalSize: Codable, Equatable, Sendable {
    let rows: UInt16
    let columns: UInt16
    let pixelWidth: UInt16
    let pixelHeight: UInt16
}

nonisolated struct CoreCommandReceipt: Decodable, Equatable, Sendable {
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

nonisolated struct CoreSnapshot: Decodable, Equatable, Sendable {
    var sequence: UInt64
    var state: CoreApplicationState
    let config: CoreConfig
    var folders: CoreFolderState
    var terminals: [CoreTerminalState] = []
    var workflows = CoreWorkflowState()
    var traces: [CoreTraceSummary] = []
    var workflowTypes: [CoreWorkflowType]?
}

nonisolated struct CoreApplicationState: Decodable, Equatable, Sendable {
    var status: Status

    enum Status: String, Decodable, Sendable {
        case ready
    }
}

/// The open folder and the recent folders the start page lists.
nonisolated struct CoreFolderState: Decodable, Equatable, Sendable {
    var currentBranch: String?
    /// The folder the window shows, or `nil` while it shows the start page.
    var openFolder: String?
    /// Recently opened folders, most recent first.
    var recentFolders: [CoreRecentFolder]
    /// A folder that just failed to open, so the start page can say why it's showing.
    var unavailableFolder: CoreUnavailableFolder?
}

nonisolated struct CoreRecentFolder: Decodable, Equatable, Identifiable, Sendable {
    let path: String
    /// Whether nothing, or something other than a folder, is at `path` now. Missing folders stay
    /// listed until removed.
    let isMissing: Bool

    var id: String { path }
}

nonisolated struct CoreUnavailableFolder: Decodable, Equatable, Sendable {
    let path: String
    let reason: Reason

    enum Reason: String, Decodable, Sendable {
        /// Nothing is at the path, or something other than a folder is.
        case missing
        /// The folder can't be read, for example because Twine doesn't have permission.
        case inaccessible
    }
}

nonisolated struct CoreEventBatch: Decodable, Sendable {
    let events: [CoreEvent]
}

nonisolated struct CoreEvent: Decodable, Equatable, Sendable {
    let sequence: UInt64
    let event: Kind

    enum Kind: Equatable, Sendable {
        case applicationReady
        case workflowTypesChanged([CoreWorkflowType])
        case traceChanged(CoreTraceSummary)
        case workflowsChanged(CoreWorkflowState)
        case workflowChanged(CoreWorkflow)
        case commandCompleted(requestID: UInt64, result: CoreCommandResult)
        case foldersChanged(CoreFolderState)
        case terminalClosed(terminalID: UInt64)
        case terminalExited(terminalID: UInt64, exit: CoreTerminalExit)
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

nonisolated enum CoreCommandResult: Equatable, Sendable {
    case workflowTypeValidated(issues: [CoreWorkflowValidationIssue])
    case workflowTypeSaved(reference: CoreWorkflowType.Reference)
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

nonisolated struct CoreCommandCompletion: Equatable, Sendable {
    let requestID: UInt64
    let result: CoreCommandResult
}

nonisolated struct CoreTerminalChunk: Equatable, Sendable {
    let terminalID: UInt64
    let offset: UInt64
    let bytes: Data
}

nonisolated struct CoreTerminalExit: Decodable, Equatable, Sendable {
    let exitCode: UInt32
    let signal: String?
}

nonisolated struct CoreTerminalState: Decodable, Equatable, Sendable {
    let terminalID: UInt64
    let status: Status

    enum Status: Equatable, Sendable {
        case running
        case exited(CoreTerminalExit)
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
                CoreTerminalExit(
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
    let kind: CoreEvent.Kind

    private enum CodingKeys: String, CodingKey {
        case folders
        case workflowTypes
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
        case workflowTypesChanged
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
            kind = .traceChanged(try container.decode(CoreTraceSummary.self, forKey: .summary))
        case .workflowTypesChanged:
            kind = .workflowTypesChanged(try container.decode([CoreWorkflowType].self, forKey: .workflowTypes))
        case .applicationReady:
            kind = .applicationReady
        case .commandCompleted:
            kind = .commandCompleted(
                requestID: try container.decode(UInt64.self, forKey: .requestID),
                result: try container.decode(CommandResultPayload.self, forKey: .result).result
            )
        case .workflowsChanged:
            kind = .workflowsChanged(try container.decode(CoreWorkflowState.self, forKey: .workflows))
        case .workflowChanged:
            kind = .workflowChanged(try container.decode(CoreWorkflow.self, forKey: .workflow))
        case .foldersChanged:
            kind = .foldersChanged(try container.decode(CoreFolderState.self, forKey: .folders))
        case .terminalClosed:
            kind = .terminalClosed(terminalID: try container.decode(UInt64.self, forKey: .terminalID))
        case .terminalExited:
            kind = .terminalExited(
                terminalID: try container.decode(UInt64.self, forKey: .terminalID),
                exit: CoreTerminalExit(
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
    let result: CoreCommandResult

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case workflowID = "workflowId"
        case terminalID = "terminalId"
        case type, issues, reference
    }

    private enum ResultType: String, Decodable {
        case sessionCreated, sessionRenamed, sessionSelected, sessionDeleted
        case pong, workflowTypeValidated, workflowTypeSaved
        case workflowCreated
        case workflowActivated
        case workflowClosed
        case agentStarted
        case agentCancelled
        case terminalStarted
        case terminalClosed
    }

    private static func workflowResult(_ type: ResultType, workflowID: UInt64) throws -> CoreCommandResult {
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
        case .workflowTypeValidated:
            result = .workflowTypeValidated(
                issues: try container.decode([CoreWorkflowValidationIssue].self, forKey: .issues))
        case .workflowTypeSaved:
            result = .workflowTypeSaved(
                reference: try container.decode(CoreWorkflowType.Reference.self, forKey: .reference))
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
extension CoreSnapshot {
    nonisolated private enum CodingKeys: String, CodingKey {
        case sequence, state, config, folders, terminals, workflows, traces, workflowTypes
    }
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sequence: try container.decode(UInt64.self, forKey: .sequence),
            state: try container.decode(CoreApplicationState.self, forKey: .state),
            config: try container.decode(CoreConfig.self, forKey: .config),
            folders: try container.decode(CoreFolderState.self, forKey: .folders),
            terminals: try container.decodeIfPresent([CoreTerminalState].self, forKey: .terminals) ?? [],
            workflows: try container.decodeIfPresent(CoreWorkflowState.self, forKey: .workflows) ?? .init(),
            traces: try container.decodeIfPresent([CoreTraceSummary].self, forKey: .traces) ?? [],
            workflowTypes: try container.decodeIfPresent([CoreWorkflowType].self, forKey: .workflowTypes))
    }
}
