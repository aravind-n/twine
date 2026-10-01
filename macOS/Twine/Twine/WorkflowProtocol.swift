import Foundation

nonisolated struct CoreWorkflowState: Decodable, Equatable, Sendable {
    var sessionsInitialized = false
    var session: CoreSession?
    var sessions: [CoreSession] = []
    var workflows: [CoreWorkflow] = []
}

nonisolated struct CoreSession: Decodable, Equatable, Identifiable, Sendable {
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
nonisolated enum CoreHarness: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claudeCode
    case piAgent = "pi"
    case antigravity
    case omp
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .piAgent: "pi"
        case .antigravity: "Antigravity"
        case .omp: "OMP"
        case .opencode: "OpenCode"
        }
    }
}

nonisolated struct CoreWorkflow: Decodable, Equatable, Identifiable, Sendable {
    let workflowID: UInt64
    let sessionID: UInt64
    let name: String
    let kind: Kind
    var harness: CoreHarness?
    /// The workflow's own shell. Zero when it couldn't restart, and for agents workflows, whose agents
    /// have the terminals instead.
    let terminalID: UInt64
    /// In role order. Empty unless the kind is `agents`.
    var agents: [CoreAgent] = []
    let status: Status
    let startedAt: UInt64
    let endedAt: UInt64?
    var restored = false
    var terminalHistory: [CoreWorkflowTerminal]?
    var run: CoreWorkflowRun?

    var id: UInt64 { workflowID }

    /// Only workflows with more than one agent show agent subtabs.
    var showsAgentSubtabs: Bool { agents.count > 1 }

    /// Agents workflows with subtabs or a run get the strip at the top of the terminal panel.
    var showsTerminalStrip: Bool { kind == .agents && (showsAgentSubtabs || run != nil) }

    /// The workflow's live shells: its agents' in an agents workflow, and otherwise its own.
    var terminalIDs: [UInt64] {
        if restored && (kind == .singleAgent || run != nil) { return [] }
        return (kind == .agents ? agents.map(\.terminalID) : [terminalID]).filter { $0 != 0 }
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
        case name, kind, harness, agents, status, startedAt, endedAt, restored, run, terminalHistory
    }
}

nonisolated struct CoreWorkflowTerminal: Decodable, Equatable, Sendable {
    let terminalID: UInt64
    let agentID: UInt64?

    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminalId"
        case agentID = "agentId"
    }
}

/// One process filling one role in a workflow, shown as one of its subtabs.
nonisolated struct CoreAgent: Decodable, Equatable, Identifiable, Sendable {
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

extension CoreWorkflow {
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
