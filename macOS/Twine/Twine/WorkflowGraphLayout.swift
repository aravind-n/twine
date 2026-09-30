import CoreGraphics
import Foundation

/// One row per ordered stage, with one node per role instance. Handoffs expand between instances;
/// feedback takes a lane beside the rows, so a loop never crosses a role node.
nonisolated struct WorkflowGraphLayout {
    struct Node: Identifiable {
        let stageID: String
        let role: BridgeWorkflowType.Role
        let instance: Int
        let count: Int
        let frame: CGRect
        var id: String { "\(stageID)-\(role.id)-\(instance)" }
        var label: String { count > 1 ? "\(role.name) \(instance)" : role.name }
    }

    struct Row: Identifiable {
        let stage: BridgeWorkflowType.Stage
        let nodes: [Node]
        let titleY: CGFloat
        var id: String { stage.id }
    }

    struct Edge {
        let from: Node
        let destination: Node
        let content: BridgeWorkflowType.HandoffContent
        let laneX: CGFloat?
    }

    let rows: [Row]
    let edges: [Edge]
    let size: CGSize

    var handoffDescriptions: [String] {
        edges.map { edge in
            let source = rows.first { $0.id == edge.from.stageID }?.stage.name ?? edge.from.stageID
            let destination = rows.first { $0.id == edge.destination.stageID }?.stage.name ?? edge.destination.stageID
            return "\(edge.from.label) in \(source) sends \(edge.content.rawValue) "
                + "to \(edge.destination.label) in \(destination)."
        }
    }

    init(definition: BridgeWorkflowType.Definition, counts: [String: Int] = [:], width: CGFloat, compact: Bool) {
        let spacing: CGFloat = compact ? 6 : 12
        let nodeWidth: CGFloat = compact ? 72 : 132
        let nodeHeight: CGFloat = compact ? 28 : 50
        let titleHeight: CGFloat = compact ? 16 : 22
        let gap: CGFloat = compact ? 24 : 36
        let backward = definition.handoffs.filter { handoff in
            let from = definition.stages.firstIndex { $0.id == handoff.from.stage } ?? 0
            let destination = definition.stages.firstIndex { $0.id == handoff.destination.stage } ?? 0
            return from >= destination
        }
        let laneWidth: CGFloat = compact ? 10 : 18
        let inset: CGFloat = 4
        let left = inset + CGFloat(backward.count) * laneWidth
        let stageRoles = definition.stages.map { stage in
            stage.roles.compactMap { id in definition.roles.first { $0.id == id } }
        }
        let instances = stageRoles.map { roles in
            roles.flatMap { role in
                let count = min(role.instances.max, max(role.instances.min, counts[role.id] ?? role.instances.min))
                return (1...max(1, count)).map { (role, $0, count) }
            }
        }
        let maxNodes = instances.map(\.count).max() ?? 1
        let contentWidth = max(width, left + CGFloat(maxNodes) * (nodeWidth + spacing) - spacing + inset)
        let rowHeight = titleHeight + nodeHeight + gap
        rows = zip(definition.stages, instances).enumerated().map { index, pair in
            let (stage, roles) = pair
            let totalWidth = CGFloat(roles.count) * (nodeWidth + spacing) - spacing
            let startX = left + (contentWidth - left - inset - totalWidth) / 2
            let titleY = CGFloat(index) * rowHeight + titleHeight / 2
            let nodes = roles.enumerated().map { column, item in
                Node(
                    stageID: stage.id, role: item.0, instance: item.1, count: item.2,
                    frame: CGRect(
                        x: startX + CGFloat(column) * (nodeWidth + spacing),
                        y: CGFloat(index) * rowHeight + titleHeight, width: nodeWidth, height: nodeHeight))
            }
            return Row(stage: stage, nodes: nodes, titleY: titleY)
        }
        edges = Self.connections(
            handoffs: definition.handoffs, nodes: rows.flatMap(\.nodes),
            backward: backward, laneWidth: laneWidth, inset: inset)
        size = CGSize(width: contentWidth, height: max(0, CGFloat(rows.count) * rowHeight - gap + inset))
    }

    private static func connections(
        handoffs: [BridgeWorkflowType.Handoff], nodes: [Node], backward: [BridgeWorkflowType.Handoff],
        laneWidth: CGFloat, inset: CGFloat
    ) -> [Edge] {
        handoffs.flatMap { handoff in
            let from = nodes.filter { $0.stageID == handoff.from.stage && $0.role.id == handoff.from.role }
            let destination = nodes.filter {
                $0.stageID == handoff.destination.stage && $0.role.id == handoff.destination.role
            }
            let lane = backward.firstIndex(of: handoff).map { inset + CGFloat($0) * laneWidth }
            return from.flatMap { source in
                destination.map { target in
                    Edge(from: source, destination: target, content: handoff.content, laneX: lane)
                }
            }
        }
    }
}
