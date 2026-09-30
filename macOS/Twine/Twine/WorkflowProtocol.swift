import Foundation

nonisolated struct BridgeWorkflowState: Decodable, Equatable, Sendable {
    var sessionsInitialized = false
    var session: BridgeSession?
    var sessions: [BridgeSession] = []
    var workflows: [BridgeWorkflow] = []
}

nonisolated struct BridgeSession: Decodable, Equatable, Identifiable, Sendable {
    var id: UInt64 { sessionID }
    let sessionID: UInt64
    let name: String
    let folder: String
    let status: Status
    let startedAt: UInt64
    let endedAt: UInt64?

    enum Status: String, Decodable, Sendable {
        case active
        case closed
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case name, folder, status, startedAt, endedAt
    }
}

/// A built-in harness, named as the core's protocol names it.
nonisolated enum BridgeHarness: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claudeCode
    case piAgent = "pi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .piAgent: "pi"
        }
    }
}

nonisolated struct BridgeWorkflow: Decodable, Equatable, Identifiable, Sendable {
    let workflowID: UInt64
    let sessionID: UInt64
    let name: String
    let kind: Kind
    var harness: BridgeHarness?
    /// The workflow's own shell. Zero when it couldn't restart, and for agents workflows, whose agents
    /// have the terminals instead.
    let terminalID: UInt64
    /// In role order. Empty unless the kind is `agents`.
    var agents: [BridgeAgent] = []
    let status: Status
    let startedAt: UInt64
    let endedAt: UInt64?
    var restored = false
    var run: BridgeWorkflowRun?

    var id: UInt64 { workflowID }

    /// Only workflows with more than one agent show agent subtabs.
    var showsAgentSubtabs: Bool { agents.count > 1 }

    /// The workflow's live shells: its agents' in an agents workflow, and otherwise its own.
    var terminalIDs: [UInt64] {
        (kind == .agents ? agents.map(\.terminalID) : [terminalID]).filter { $0 != 0 }
    }

    /// The agent whose terminal shows: the selected one while it exists, otherwise the first.
    func shownAgent(selectedID: UInt64?) -> BridgeAgent? {
        agents.first { $0.id == selectedID } ?? agents.first
    }

    enum Kind: String, Codable, Sendable {
        case draft
        case terminal
        case singleAgent
        case agents
    }

    enum Status: String, Decodable, Sendable {
        case running
        case completed
        case exited
        case failed
        case cancelled
        case interrupted
        case closed
    }

    private enum CodingKeys: String, CodingKey {
        case workflowID = "workflowId"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
        case name, kind, harness, agents, status, startedAt, endedAt, restored, run
    }
}

/// One process filling one role in a workflow, shown as one of its subtabs.
nonisolated struct BridgeAgent: Decodable, Equatable, Identifiable, Sendable {
    let agentID: UInt64
    let role: String
    /// Zero when the agent's shell couldn't restart.
    let terminalID: UInt64

    var id: UInt64 { agentID }

    private enum CodingKeys: String, CodingKey {
        case agentID = "agentId"
        case terminalID = "terminalId"
        case role
    }
}

extension BridgeWorkflow {
    var tabSymbol: String {
        switch kind {
        case .draft: "square.dashed"
        case .terminal: "terminal"
        case .singleAgent: "person"
        case .agents: "person.2"
        }
    }

    var isRunningAgent: Bool { (kind == .singleAgent || run != nil) && status == .running }
}
