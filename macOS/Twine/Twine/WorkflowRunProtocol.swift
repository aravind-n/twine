import Foundation

nonisolated struct BridgeRoleLaunch: Codable, Equatable, Sendable {
    let role: String
    let harness: BridgeHarness
}

nonisolated struct BridgeCompletionSignal: Codable, Equatable, Sendable {
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

nonisolated struct BridgeWorkflowRun: Decodable, Equatable, Sendable {
    let generation: UInt64
    let stage: String
    let status: Status
    let message: String?
    let agents: [Agent]
    var stageID: String?
    var workflowType: BridgeWorkflowType?

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
        let harness: BridgeHarness
        let targets: [Target]
        var role: String?
        var instance: Int?
        var id: UInt64 { agentId }
    }

    struct Target: Decodable, Equatable, Identifiable, Sendable {
        let role: String
        let instance: Int
        let label: String
        var id: String { "\(role)-\(instance)" }
    }

}

nonisolated struct BridgeUserWorkflowVersion: Codable, Equatable, Sendable {
    let typeID: UInt64
    let version: UInt32
    private enum CodingKeys: String, CodingKey {
        case typeID = "type_id"
        case version
    }
}
