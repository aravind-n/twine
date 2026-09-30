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
    let terminalID: UInt64
    let status: Status
    let startedAt: UInt64
    let endedAt: UInt64?
    var restored = false

    var id: UInt64 { workflowID }

    enum Kind: String, Codable, Sendable {
        case draft
        case terminal
        case singleAgent
    }

    enum Status: String, Decodable, Sendable {
        case running
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
        case name, kind, harness, status, startedAt, endedAt, restored
    }
}

extension BridgeWorkflow {
    var tabSymbol: String {
        switch kind {
        case .draft: "square.dashed"
        case .terminal: "terminal"
        case .singleAgent: "person"
        }
    }

    var isRunningAgent: Bool { kind == .singleAgent && status == .running }
}
