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

    init(requestID: UInt64, command: CoreCommand) {
        self.requestID = requestID
        self.command = CommandPayload(command)
    }
}

nonisolated private struct CommandPayload: Encodable {
    var definition: CoreWorkflowType.Definition?
    var source: CoreWorkflowType.Reference?
    var type: String
    var path: String?
    var folder: String?
    var kind: CoreWorkflow.Kind?
    var roles: [String]?
    var sessionID: UInt64?
    var workflowID: UInt64?
    var name: String?
    var harness: CoreHarness?
    var model: String?
    var effort: String?
    var yolo: Bool?
    var workflowType: CoreWorkflowType.Reference?
    var roleLaunches: [CoreRoleLaunch]?
    var agentID: UInt64?
    var generation: UInt64?
    var individualMode: Bool?
    var modeRevision: UInt64?
    var signal: CoreCompletionSignal?
    var workingDirectory: String?
    var size: CoreTerminalSize?
    var terminalID: UInt64?
    var session: String?

    private enum CodingKeys: String, CodingKey {
        case definition, source, session
        case path, folder, kind, roles, size, type, workingDirectory, name, harness, model, effort, yolo
        case terminalID = "terminalId"
        case workflowID = "workflowId"
        case sessionID = "sessionId"
        case workflowType, generation, signal, individualMode, modeRevision
        case roleLaunches = "roleLaunches"
        case agentID = "agentId"
    }

    init(_ command: CoreCommand) {
        switch command {
        case .validateWorkflowType(let definition):
            type = "validateWorkflowType"
            self.definition = definition
        case .saveWorkflowType(let source, let definition):
            type = "saveWorkflowType"
            self.source = source
            self.definition = definition
        case .ping:
            type = "ping"
        case .openFolder, .closeFolder, .closeFolderIfOpen, .removeRecentFolder, .refreshGitBranch:
            type = ""
            configureFolder(command)
        case .createSession, .renameSession, .selectSession, .deleteSession:
            type = ""
            configureSession(command)
        case .createWorkflow, .activateWorkflow, .nameDraftWorkflow, .closeWorkflow, .startAgent, .resumeAgent,
            .cancelAgent:
            type = ""
            configureWorkflow(command)
        case .startWorkflowRun, .completeWorkflowRole, .continueWorkflowRun, .setWorkflowIndividualMode,
            .cancelWorkflowRun:
            type = ""
            configureRun(command)
        case .startTerminal(let workingDirectory, let size):
            type = "startTerminal"
            self.workingDirectory = workingDirectory
            self.size = size
        case .closeTerminal(let terminalID):
            type = "closeTerminal"
            self.terminalID = terminalID
        }
    }

    private mutating func configureFolder(_ command: CoreCommand) {
        switch command {
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
        default: break
        }
    }

    private mutating func configureRun(_ command: CoreCommand) {
        switch command {
        case .startWorkflowRun(let workflowID, let workflowType, let roles, let size):
            type = "startWorkflowRun"
            self.workflowID = workflowID
            self.workflowType = workflowType
            self.roleLaunches = roles
            self.size = size
        case .completeWorkflowRole(let workflowID, let agentID, let generation, let signal):
            type = "completeWorkflowRole"
            self.workflowID = workflowID
            self.agentID = agentID
            self.generation = generation
            self.signal = signal
        case .continueWorkflowRun(let workflowID, let agentID, let generation, let modeRevision):
            type = "continueWorkflowRun"
            self.workflowID = workflowID
            self.agentID = agentID
            self.generation = generation
            self.modeRevision = modeRevision
        case .setWorkflowIndividualMode(let workflowID, let generation, let modeRevision, let individualMode):
            type = "setWorkflowIndividualMode"
            self.workflowID = workflowID
            self.generation = generation
            self.modeRevision = modeRevision
            self.individualMode = individualMode
        case .cancelWorkflowRun(let workflowID):
            type = "cancelWorkflowRun"
            self.workflowID = workflowID
        default: break
        }
    }

    private mutating func configureSession(_ command: CoreCommand) {
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

    private mutating func configureWorkflow(_ command: CoreCommand) {
        switch command {
        case .createWorkflow(let folder, let sessionID, let kind, let roles, let size):
            self.sessionID = sessionID
            type = "createWorkflow"
            self.folder = folder
            self.kind = kind
            self.roles = roles.isEmpty ? nil : roles
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
        case .startAgent(let workflowID, let choice, let size):
            type = "startAgent"
            self.workflowID = workflowID
            self.harness = choice.harness
            self.model = choice.model
            self.effort = choice.effort
            self.yolo = choice.yolo ? true : nil
            self.size = size
        case .resumeAgent(let workflowID, let session):
            type = "resumeAgent"
            self.workflowID = workflowID
            self.session = session
        case .cancelAgent(let workflowID):
            type = "cancelAgent"
            self.workflowID = workflowID
        default:
            break
        }
    }
}
