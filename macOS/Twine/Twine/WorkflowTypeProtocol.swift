import Foundation

nonisolated struct BridgeWorkflowType: Decodable, Equatable, Identifiable, Sendable {
    let reference: Reference
    let definition: Definition
    var id: String { reference.builtin ?? "custom-\(reference.user?.typeID ?? 0)-\(reference.user?.version ?? 0)" }
    /// Form choices belong to a type, including when a custom type gets a new version.
    var preferenceKey: String { reference.builtin ?? "custom-\(reference.user?.typeID ?? 0)" }

    struct Reference: Codable, Equatable, Sendable {
        var builtin: String?
        var user: BridgeUserWorkflowVersion?
    }

    struct Definition: Decodable, Equatable, Sendable {
        let name: String
        let description: String
        let roles: [Role]
        var stages: [Stage] = []
        var handoffs: [Handoff] = []
        var reviewLoops: [ReviewLoop] = []

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

    struct Stage: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let roles: [String]
        let completion: Completion
    }

    struct Completion: Decodable, Equatable, Sendable {
        let rule: CompletionRule
        var reviewer: String?
    }

    enum CompletionRule: String, Decodable, Sendable {
        case allRolesDone = "all_roles_done"
        case reviewDecision = "review_decision"
    }

    struct Endpoint: Decodable, Equatable, Sendable {
        let stage: String
        let role: String
    }

    struct Handoff: Decodable, Equatable, Sendable {
        let from: Endpoint
        let destination: Endpoint
        let content: HandoffContent
    }

    enum HandoffContent: String, Decodable, Sendable { case result, feedback, assignment }

    struct ReviewLoop: Decodable, Equatable, Sendable {
        let reviewStage: String
        let backTo: String
        let maxRounds: Int
    }
}

extension BridgeWorkflowType.Definition {
    private enum CodingKeys: String, CodingKey {
        case name, description, roles, stages, handoffs
        case reviewLoops = "review_loops"
    }
}

extension BridgeWorkflowType.Handoff {
    private enum CodingKeys: String, CodingKey {
        case from, content
        case destination = "to"
    }
}

extension BridgeWorkflowType.ReviewLoop {
    private enum CodingKeys: String, CodingKey {
        case reviewStage = "review_stage"
        case backTo = "back_to"
        case maxRounds = "max_rounds"
    }
}
