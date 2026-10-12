import AppKit
import Foundation

extension WorkflowDesignerModel {
    /// Turn an ordered definition into explicit agent links when the user edits a copy.
    func enableGraph() {
        if var graph = definition.graph {
            graph.reviewAgents = definition.roles.filter { graph.reviewsWork($0.id) }.map(\.id)
            var candidate = graph
            candidate.edges = graph.agentEdges
            let preservesStarts = definition.roles.allSatisfy {
                graph.startsAgent($0.id) == candidate.startsAgent($0.id)
            }
            let preservesResults = definition.roles.allSatisfy {
                graph.returnsResult($0.id) == candidate.returnsResult($0.id)
            }
            // Keep older explicit routing when a cycle cannot infer its entry or final result.
            // The canvas still renders only agents and agent-to-agent links.
            if preservesStarts && preservesResults { graph.edges = candidate.edges }
            graph.positions.removeValue(forKey: "task")
            graph.positions.removeValue(forKey: "finish")
            definition.graph = graph
            definition = WorkflowGraphAgents.expanded(definition)
            assignColors()
            return
        }
        var graph = CoreWorkflowType.Graph()
        let original = definition
        let endpoints = convertRoles(original)
        graph.edges = convertEdges(original, endpoints: endpoints)
        graph.reviewAgents = original.stages.compactMap { stage in
            stage.completion.reviewer.flatMap { endpoints["\(stage.id):\($0)"] }
        }
        graph.maxActivations = original.reviewLoops.map { $0.maxRounds + 1 }.max() ?? 32
        addAssignmentRules(original, endpoints: endpoints)
        for stage in original.stages where stage.roles.count == 1 {
            if let role = stage.roles.first, let id = endpoints["\(stage.id):\(role)"] {
                graph.receive[id] = .all
            }
        }
        for (index, role) in definition.roles.enumerated() {
            graph.positions[role.id] = .init(x: 240 + (index % 3) * 300, y: 220 + (index / 3) * 180)
        }
        definition.graph = graph
        definition.stages = []
        definition.handoffs = []
        definition.reviewLoops = []
        definition = WorkflowGraphAgents.expanded(definition)
        assignColors()
        if let notice = conversionNotice { definition.description += " " + notice }
    }

    private func convertRoles(_ original: CoreWorkflowType.Definition) -> [String: String] {
        var roles: [CoreWorkflowType.Role] = []
        var endpoints: [String: String] = [:]
        for stage in original.stages {
            for id in stage.roles {
                guard var role = original.roles.first(where: { $0.id == id }) else { continue }
                if original.stages.filter({ $0.roles.contains(id) }).count > 1 {
                    role.id = "\(stage.id)-\(id)"
                    role.name = "\(role.name) · \(stage.name)"
                    role.instructions += "\nPerform only the \(stage.name) responsibility for this agent."
                }
                role.instances.max = role.instances.min
                endpoints["\(stage.id):\(id)"] = role.id
                roles.append(role)
            }
        }
        if !original.stages.isEmpty { definition.roles = roles }
        return endpoints
    }

    private func convertEdges(
        _ original: CoreWorkflowType.Definition,
        endpoints: [String: String]
    ) -> [CoreWorkflowType.Edge] {
        var edges: [CoreWorkflowType.Edge] = []
        for handoff in original.handoffs {
            guard let source = endpoints["\(handoff.from.stage):\(handoff.from.role)"],
                let destination = endpoints["\(handoff.destination.stage):\(handoff.destination.role)"]
            else { continue }
            edges.append(
                .init(
                    id: UUID().uuidString, from: source, to: destination,
                    event: handoff.content == .feedback ? .feedback : .done))
        }
        return edges
    }

    private func addAssignmentRules(_ original: CoreWorkflowType.Definition, endpoints: [String: String]) {
        for handoff in original.handoffs where handoff.content == .assignment {
            let source = endpoints["\(handoff.from.stage):\(handoff.from.role)"]
            let index = definition.roles.firstIndex { $0.id == source }
            if let index {
                definition.roles[index].instructions +=
                    "\nReturn one plan in summary."
                    + " Include a sub-task and owned files for each numbered worker."
                    + " Each worker receives the plan and selects its own sub-task."
            }
        }
    }

    @discardableResult
    func addGraphRole(from source: String? = nil, at location: CoreWorkflowType.Position? = nil) -> String {
        let id = UUID().uuidString
        let index = definition.roles.count
        let position = location ?? WorkflowEditorLayout.nextRolePosition(in: definition)
        definition.roles.append(
            .init(
                id: id, name: "Agent \(index + 1)", instances: .init(min: 1, max: 1),
                instructions: "Complete the incoming task. Send the complete result when the work is done.",
                color: agentColor(at: index)))
        definition.graph?.positions[id] = position
        if let source { connect(from: source, to: id) }
        return id
    }

    @discardableResult
    func duplicateGraphAgent(_ id: String) -> String? {
        guard var agent = definition.roles.first(where: { $0.id == id }) else { return nil }
        let originalName = agent.name
        let names = Set(definition.roles.map(\.name))
        agent.name = "\(originalName) copy"
        var suffix = 2
        while names.contains(agent.name) {
            agent.name = "\(originalName) copy \(suffix)"
            suffix += 1
        }
        agent.id = UUID().uuidString
        agent.instances = .init(min: 1, max: 1)
        let original =
            definition.graph?.positions[id]
            ?? WorkflowEditorLayout.defaultPosition(for: id, roles: definition.roles)
        let position = WorkflowEditorLayout.nextRolePosition(
            in: definition, near: .init(x: min(4000, original.x + 260), y: original.y))
        let reviews = definition.graph?.reviewsWork(id) == true
        let receive = definition.graph?.receive[id]
        definition.roles.append(agent)
        definition.graph?.positions[agent.id] = position
        definition.graph?.receive[agent.id] = receive
        if reviews { definition.graph?.reviewAgents.append(agent.id) }
        return agent.id
    }

    func setGraphReview(_ id: String, enabled: Bool) {
        guard var graph = definition.graph else { return }
        graph.reviewAgents.removeAll { $0 == id }
        if enabled {
            graph.reviewAgents.append(id)
            let approved = Set(graph.edges.filter { $0.from == id && $0.event == .approved }.map(\.to))
            graph.edges.removeAll { $0.from == id && $0.event == .done && approved.contains($0.to) }
            for index in graph.edges.indices where graph.edges[index].from == id && graph.edges[index].event == .done {
                graph.edges[index].event = .approved
            }
        }
        definition.graph = graph
    }

    func canConnect(from source: String, to destination: String, event: CoreWorkflowType.GraphEvent? = nil) -> Bool {
        guard let graph = definition.graph, source != destination,
            definition.roles.contains(where: { $0.id == source }),
            definition.roles.contains(where: { $0.id == destination })
        else { return false }
        let event = event ?? (graph.reviewsWork(source) ? .approved : .done)
        guard event != .task else { return false }
        return !graph.edges.contains { $0.from == source && $0.to == destination && $0.event == event }
    }

    func connect(from: String, to destination: String, event: CoreWorkflowType.GraphEvent? = nil) {
        guard canConnect(from: from, to: destination, event: event) else { return }
        let event = event ?? (definition.graph?.reviewsWork(from) == true ? .approved : .done)
        definition.graph?.edges.append(
            .init(id: UUID().uuidString, from: from, to: destination, event: event))
        if event == .feedback || event == .approved { setGraphReview(from, enabled: true) }
    }

    private func agentColor(at index: Int) -> CoreWorkflowType.AgentColor {
        let palette: [CoreWorkflowType.AgentColor] = [.blue, .orange, .green, .purple, .teal]
        return palette[index % palette.count]
    }

    private func assignColors() {
        for index in definition.roles.indices where definition.roles[index].color == nil {
            definition.roles[index].color = agentColor(at: index)
        }
    }

    func removeGraphRole(_ id: String) {
        definition.roles.removeAll { $0.id == id }
        definition.graph?.edges.removeAll { $0.from == id || $0.to == id }
        definition.graph?.positions.removeValue(forKey: id)
        definition.graph?.receive.removeValue(forKey: id)
        definition.graph?.reviewAgents.removeAll { $0 == id }
    }
}
