import Foundation

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
    var sessionID: UInt64?
    var workflowID: UInt64?
    var name: String?
    var workingDirectory: String?
    var size: BridgeTerminalSize?
    var terminalID: UInt64?

    private enum CodingKeys: String, CodingKey {
        case path, folder, kind, size, type, workingDirectory, name
        case terminalID = "terminalId"
        case workflowID = "workflowId"
        case sessionID = "sessionId"
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
        case .refreshGitBranch(let folder):
            type = "refreshGitBranch"
            self.folder = folder
        case .createSession, .renameSession, .selectSession, .deleteSession:
            type = ""
            configureSession(command)
        case .createWorkflow, .activateWorkflow, .nameDraftWorkflow, .closeWorkflow:
            type = ""
            configureWorkflow(command)
        case .startTerminal(let workingDirectory, let size):
            type = "startTerminal"
            self.workingDirectory = workingDirectory
            self.size = size
        case .closeTerminal(let terminalID):
            type = "closeTerminal"
            self.terminalID = terminalID
        }
    }

    private mutating func configureSession(_ command: BridgeCommand) {
        switch command {
        case .createSession(let folder, let name):
            type = "createSession"
            self.folder = folder
            self.name = name
        case .renameSession(let sessionID, let name):
            type = "renameSession"
            self.sessionID = sessionID
            self.name = name
        case .selectSession(let sessionID):
            type = "selectSession"
            self.sessionID = sessionID
        case .deleteSession(let sessionID):
            type = "deleteSession"
            self.sessionID = sessionID
        default:
            break
        }
    }

    private mutating func configureWorkflow(_ command: BridgeCommand) {
        switch command {
        case .createWorkflow(let folder, let sessionID, let kind, let size):
            self.sessionID = sessionID
            type = "createWorkflow"
            self.folder = folder
            self.kind = kind
            self.size = size
        case .activateWorkflow(let workflowID):
            type = "activateWorkflow"
            self.workflowID = workflowID
        case .nameDraftWorkflow(let workflowID, let name):
            type = "nameDraftWorkflow"
            self.workflowID = workflowID
            self.name = name
        case .closeWorkflow(let workflowID):
            type = "closeWorkflow"
            self.workflowID = workflowID
        default:
            break
        }
    }
}
