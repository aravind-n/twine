import Foundation

nonisolated struct BridgeWorkflowType: Decodable, Equatable, Identifiable, Sendable {
    let reference: Reference
    let definition: Definition
    var id: String { reference.builtin ?? "custom-\(reference.user?.typeID ?? 0)-\(reference.user?.version ?? 0)" }

    struct Reference: Codable, Equatable, Sendable {
        var builtin: String?
        var user: BridgeUserWorkflowVersion?
    }

    struct Definition: Decodable, Equatable, Sendable {
        let name: String
        let description: String
        let roles: [Role]
    }

    struct Role: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let instances: Instances
    }

    struct Instances: Decodable, Equatable, Sendable {
        let min: Int
        let max: Int
    }
}

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

    enum Status: String, Decodable, Sendable { case running, completed, limitReached, cancelled, failed, interrupted }

    struct Agent: Decodable, Equatable, Identifiable, Sendable {
        let agentId: UInt64
        let active: Bool
        let done: Bool
        let reviewer: Bool
        let harness: BridgeHarness
        let targets: [Target]
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
