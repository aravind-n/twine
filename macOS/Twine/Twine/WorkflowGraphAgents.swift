import Foundation

/// Expand older worker groups into the individual agents shown by the editor and preview.
nonisolated enum WorkflowGraphAgents {
    static func expanded(_ original: CoreWorkflowType.Definition) -> CoreWorkflowType.Definition {
        guard var graph = original.graph,
            original.roles.contains(where: { $0.instances.min != 1 || $0.instances.max != 1 })
        else { return original }
        var definition = original
        var endpoints: [String: [String]] = [:]
        var roles: [CoreWorkflowType.Role] = []
        var roleIDs = Set(original.roles.map(\.id))
        var positions = graph.positions
        var receive: [String: CoreWorkflowType.Receive] = [:]
        var reviewers: [String] = []
        for role in original.roles {
            let count = max(1, role.instances.min)
            let center =
                graph.positions[role.id]
                ?? WorkflowEditorLayout.defaultPosition(for: role.id, roles: original.roles)
            let firstY = min(max(0, center.y - (count - 1) * 80), max(0, 4000 - (count - 1) * 160))
            for index in 0..<count {
                var agent = role
                if index > 0 { agent.id = uniqueID("\(role.id)-\(index + 1)", reserved: &roleIDs) }
                if count > 1 { agent.name = "\(role.name) \(index + 1)" }
                agent.instances = .init(min: 1, max: 1)
                roles.append(agent)
                endpoints[role.id, default: []].append(agent.id)
                positions[agent.id] = .init(x: center.x, y: firstY + index * 160)
                if let rule = graph.receive[role.id] { receive[agent.id] = rule }
                if graph.reviewsWork(role.id) { reviewers.append(agent.id) }
            }
        }
        var edgeIDs = Set(graph.edges.map(\.id))
        graph.edges = graph.edges.flatMap { edge in
            let sources = endpoints[edge.from] ?? [edge.from]
            let destinations = endpoints[edge.to] ?? [edge.to]
            var edges: [CoreWorkflowType.Edge] = []
            for source in sources {
                for destination in destinations {
                    var link = edge
                    if !edges.isEmpty { link.id = uniqueID("\(edge.id)-\(edges.count + 1)", reserved: &edgeIDs) }
                    link.from = source
                    link.to = destination
                    edges.append(link)
                }
            }
            return edges
        }
        graph.positions = positions
        graph.receive = receive
        graph.reviewAgents = reviewers
        definition.roles = roles
        definition.graph = graph
        return definition
    }

    private static func uniqueID(_ base: String, reserved: inout Set<String>) -> String {
        var id = base
        var suffix = 2
        while reserved.contains(id) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        reserved.insert(id)
        return id
    }
}
