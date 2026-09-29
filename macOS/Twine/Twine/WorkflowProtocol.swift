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

nonisolated struct BridgeWorkflow: Decodable, Equatable, Identifiable, Sendable {
    let workflowID: UInt64
    let sessionID: UInt64
    let name: String
    let kind: Kind
    let terminalID: UInt64
    let status: Status
    let startedAt: UInt64
    let endedAt: UInt64?
    var restored = false

    var id: UInt64 { workflowID }

    enum Kind: String, Codable, Sendable {
        case draft
        case terminal
    }

    enum Status: String, Decodable, Sendable {
        case running
        case exited
        case failed
        case closed
    }

    private enum CodingKeys: String, CodingKey {
        case workflowID = "workflowId"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
        case name, kind, status, startedAt, endedAt, restored
    }
}
