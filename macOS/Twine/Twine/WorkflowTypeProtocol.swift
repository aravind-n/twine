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
        var graph: Graph?

    }

    struct Graph: Codable, Hashable, Sendable {
        var edges: [Edge] = []
        var receive: [String: Receive] = [:]
        var reviewAgents: [String] = []
        var positions: [String: Position] = [:]
        var finish: Finish = .all
        var maxActivations = 32

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            edges = try values.decodeIfPresent([Edge].self, forKey: .edges) ?? []
            receive = try values.decodeIfPresent([String: Receive].self, forKey: .receive) ?? [:]
            reviewAgents = try values.decodeIfPresent([String].self, forKey: .reviewAgents) ?? []
            positions = try values.decodeIfPresent([String: Position].self, forKey: .positions) ?? [:]
            finish = try values.decodeIfPresent(Finish.self, forKey: .finish) ?? .all
            maxActivations = try values.decodeIfPresent(Int.self, forKey: .maxActivations) ?? 32
        }
    }

    struct Edge: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var from: String
        // swiftlint:disable:next identifier_name
        var to: String
        var event: GraphEvent
    }

    struct Position: Codable, Hashable, Sendable {
        // swiftlint:disable:next identifier_name
        var x: Int
        // swiftlint:disable:next identifier_name
        var y: Int
    }
    enum Receive: String, Codable, CaseIterable, Sendable { case any, all }
    enum Finish: String, Codable, CaseIterable, Sendable { case all, choose, timed }
    enum GraphEvent: String, Codable, CaseIterable, Sendable {
        case task, done, feedback, approved
        case pieceReady = "piece_ready"
        var title: String {
            switch self {
            case .task: "Task"
            case .done: "Work complete"
            case .pieceReady: "Item ready"
            case .feedback: "Changes requested"
            case .approved: "Approved"
            }
        }
    }

    struct Role: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var name: String
        var instances: Instances
        var instructions: String = ""
        var color: AgentColor?
        var agentDefaults: AgentDefaults?
    }

    enum AgentColor: String, Codable, CaseIterable, Hashable, Sendable {
        case blue, teal, green, yellow, orange, red, pink, purple
    }

    struct AgentDefaults: Codable, Hashable, Sendable {
        var harness: CoreHarness
        var model: String?
        var effort: String?
        var yolo = false

        var choice: HarnessChoice { .init(harness: harness, model: model, effort: effort, yolo: yolo) }

        init(choice: HarnessChoice) {
            harness = choice.harness
            model = choice.model
            effort = choice.effort
            yolo = choice.yolo
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            harness = try values.decode(CoreHarness.self, forKey: .harness)
            model = try values.decodeIfPresent(String.self, forKey: .model)
            effort = try values.decodeIfPresent(String.self, forKey: .effort)
            yolo = try values.decodeIfPresent(Bool.self, forKey: .yolo) ?? false
        }
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
        case name, description, roles, stages, handoffs, graph
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

extension CoreWorkflowType.Graph {
    enum CodingKeys: String, CodingKey {
        case edges, receive, positions, finish
        case reviewAgents = "review_agents"
        case maxActivations = "max_activations"
    }
}

extension CoreWorkflowType.Role {
    enum CodingKeys: String, CodingKey {
        case id, name, instances, instructions, color
        case agentDefaults = "agent_defaults"
    }
}

extension CoreWorkflowType.Graph {
    nonisolated var agentEdges: [CoreWorkflowType.Edge] { edges.filter { $0.from != "task" && $0.to != "finish" } }

    nonisolated func startsAgent(_ id: String) -> Bool {
        if edges.contains(where: { $0.from == "task" }) {
            return edges.contains { $0.from == "task" && $0.to == id }
        }
        return !edges.contains { $0.to == id && $0.event != .feedback }
    }

    nonisolated func returnsResult(_ id: String) -> Bool {
        if edges.contains(where: { $0.to == "finish" }) {
            return edges.contains { $0.from == id && $0.to == "finish" }
        }
        return !edges.contains { $0.from == id && $0.event != .feedback }
    }

    nonisolated func reviewsWork(_ id: String) -> Bool {
        reviewAgents.contains(id)
            || edges.contains { $0.from == id && ($0.event == .feedback || $0.event == .approved) }
    }
}
