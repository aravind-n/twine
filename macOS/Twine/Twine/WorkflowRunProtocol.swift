import Foundation

nonisolated struct CoreRoleLaunch: Codable, Equatable, Sendable {
    let role: String
    let harness: CoreHarness
}

nonisolated struct CoreCompletionSignal: Codable, Equatable, Sendable {
    var decision: Decision
    var summary: String
    var assignments: [Assignment] = []

    enum Decision: String, Codable, Sendable { case done, approve, requestChanges }
    struct Assignment: Codable, Equatable, Sendable {
        let role: String
        let instance: Int
        let task: String
        let files: [String]
    }
}

nonisolated struct CoreWorkflowRun: Decodable, Equatable, Sendable {
    let generation: UInt64
    let stage: String
    let status: Status
    let message: String?
    let agents: [Agent]
    var stageID: String?
    var workflowType: CoreWorkflowType?

    private enum CodingKeys: String, CodingKey {
        case generation, stage, status, message, agents, workflowType
        case stageID = "stageId"
    }

    enum Status: String, Decodable, Sendable { case running, completed, limitReached, cancelled, failed, interrupted }

    struct Agent: Decodable, Equatable, Identifiable, Sendable {
        let agentId: UInt64
        let active: Bool
        let done: Bool
        let reviewer: Bool
        let harness: CoreHarness
        let targets: [Target]
        var role: String?
        var instance: Int?
        var status: AgentStatus?
        var id: UInt64 { agentId }
    }

    enum AgentStatus: String, Decodable, Sendable {
        case waiting, running, completed, exited, failed, cancelled, interrupted
    }

    struct Target: Decodable, Equatable, Identifiable, Sendable {
        let role: String
        let instance: Int
        let label: String
        var id: String { "\(role)-\(instance)" }
    }

}

nonisolated struct CoreUserWorkflowVersion: Codable, Equatable, Sendable {
    let typeID: UInt64
    let version: UInt32
    private enum CodingKeys: String, CodingKey {
        case typeID = "type_id"
        case version
    }
}
