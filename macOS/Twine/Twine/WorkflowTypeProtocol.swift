import Foundation

nonisolated struct CoreWorkflowType: Codable, Equatable, Identifiable, Sendable {
    let reference: Reference
    let definition: Definition
    var id: String { reference.builtin ?? "custom-\(reference.user?.typeID ?? 0)-\(reference.user?.version ?? 0)" }
    /// Form choices belong to a type, including when a custom type gets a new version.
    var preferenceKey: String { reference.builtin ?? "custom-\(reference.user?.typeID ?? 0)" }

    struct Reference: Codable, Equatable, Sendable {
        var builtin: String?
        var user: CoreUserWorkflowVersion?
    }

    struct Definition: Codable, Hashable, Sendable {
        var name: String
        var description: String
        var roles: [Role]
        var stages: [Stage] = []
        var handoffs: [Handoff] = []
        var reviewLoops: [ReviewLoop] = []

    }

    struct Role: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var name: String
        var instances: Instances
        var instructions: String = ""
    }

    struct Instances: Codable, Hashable, Sendable {
        var min: Int
        var max: Int
    }

    struct Stage: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var name: String
        var roles: [String]
        var completion: Completion
    }

    struct Completion: Codable, Hashable, Sendable {
        var rule: CompletionRule
        var reviewer: String?
    }

    enum CompletionRule: String, Codable, Sendable {
        case allRolesDone = "all_roles_done"
        case reviewDecision = "review_decision"
    }

    struct Endpoint: Codable, Hashable, Sendable {
        var stage: String
        var role: String
    }

    struct Handoff: Codable, Hashable, Sendable {
        var from: Endpoint
        var destination: Endpoint
        var content: HandoffContent
    }

    enum HandoffContent: String, Codable, Sendable { case result, feedback, assignment }

    struct ReviewLoop: Codable, Hashable, Sendable {
        var reviewStage: String
        var backTo: String
        var maxRounds: Int
    }
}

extension CoreWorkflowType.Definition {
    private enum CodingKeys: String, CodingKey {
        case name, description, roles, stages, handoffs
        case reviewLoops = "review_loops"
    }
}

extension CoreWorkflowType.Handoff {
    private enum CodingKeys: String, CodingKey {
        case from, content
        case destination = "to"
    }
}

extension CoreWorkflowType.ReviewLoop {
    private enum CodingKeys: String, CodingKey {
        case reviewStage = "review_stage"
        case backTo = "back_to"
        case maxRounds = "max_rounds"
    }
}
