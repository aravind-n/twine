import CoreGraphics
import Foundation

/// Stages run left to right, one column each, with one node per role instance stacked in its column.
/// A handoff to the next stage turns at a trunk in the gap between the columns, so fan-out and fan-in
/// share one line. Review feedback runs along a lane under the columns and never crosses a node.
nonisolated struct WorkflowGraphLayout {
    static let nodeHeight: CGFloat = 40
    static let titleHeight: CGFloat = 26
    private static let minimumNodeWidth: CGFloat = 120
    private static let maximumNodeWidth: CGFloat = 180
    private static let nodeSpacing: CGFloat = 12
    private static let columnGap: CGFloat = 88
    /// Keeps outlines and the running ring clear of the edges.
    private static let inset: CGFloat = 4
    /// How far a lane's vertical runs beside a column when a node sits below its endpoint.
    private static let sideOffset: CGFloat = 14
    private static let firstLaneOffset: CGFloat = 26
    private static let laneSpacing: CGFloat = 24
    private static let labelSpacing: CGFloat = 22
    /// Room under the last lane for its label.
    private static let bottomInset: CGFloat = 10

    struct Node: Identifiable {
        let stageID: String
        let role: CoreWorkflowType.Role
        let instance: Int
        let count: Int
        let frame: CGRect
        var id: String { "\(stageID)-\(role.id)-\(instance)" }
        var label: String { count > 1 ? "\(role.name) \(instance)" : role.name }
    }

    struct Column: Identifiable {
        let stage: CoreWorkflowType.Stage
        let nodes: [Node]
        let midX: CGFloat
        /// The widest a title can be without reaching the next column's.
        let titleWidth: CGFloat
        var id: String { stage.id }
    }

    /// One handoff between two role instances.
    struct Edge {
        let from: Node
        let destination: Node
        let content: CoreWorkflowType.HandoffContent
        let rounds: Int?
    }

    /// The lines one handoff draws, each ending at a destination node.
    struct Connector: Identifiable {
        let id: Int
        let destinationStageID: String
        let lines: [[CGPoint]]
    }

    /// Handoffs of the same kind across one gap share a label.
    struct Label: Identifiable {
        let id: String
        let text: String
        let center: CGPoint
        let destinationStageID: String
    }

    private struct Instance {
        let role: CoreWorkflowType.Role
        let number: Int
        let count: Int
    }

    let columns: [Column]
    let edges: [Edge]
    let connectors: [Connector]
    let labels: [Label]
    let size: CGSize

    var handoffDescriptions: [String] {
        edges.map { edge in
            let source = columns.first { $0.id == edge.from.stageID }?.stage.name ?? edge.from.stageID
            let destination =
                columns.first { $0.id == edge.destination.stageID }?.stage.name ?? edge.destination.stageID
            let rounds = edge.rounds.map { " Up to \($0) rounds." } ?? ""
            return "\(edge.from.label) in \(source) sends \(edge.content.rawValue) "
                + "to \(edge.destination.label) in \(destination).\(rounds)"
        }
    }

    init(definition: CoreWorkflowType.Definition, counts: [String: Int] = [:], width: CGFloat) {
        let instances = Self.instances(of: definition, counts: counts)
        let hasLanes = definition.handoffs.contains { !Self.isForward($0, in: definition.stages) }
        let inset = hasLanes ? Self.sideOffset + Self.inset : Self.inset
        let stageCount = CGFloat(max(1, definition.stages.count))
        let gaps = (stageCount - 1) * Self.columnGap
        let nodeWidth = min(
            Self.maximumNodeWidth, max(Self.minimumNodeWidth, (width - gaps - 2 * inset) / stageCount))
        let graphWidth = stageCount * nodeWidth + gaps
        let contentWidth = max(width, graphWidth + 2 * inset)
        let maxNodes = CGFloat(instances.map(\.count).max() ?? 1)
        let stackHeight = maxNodes * Self.nodeHeight + (maxNodes - 1) * Self.nodeSpacing
        let midY = Self.titleHeight + stackHeight / 2
        let columns = zip(definition.stages, instances).enumerated().map { index, pair in
            let left = (contentWidth - graphWidth) / 2 + CGFloat(index) * (nodeWidth + Self.columnGap)
            return Self.column(pair.0, roles: pair.1, left: left, width: nodeWidth, midY: midY)
        }

        var router = Router(
            definition: definition, columns: columns, midY: midY, stackBottom: Self.titleHeight + stackHeight)
        for (id, handoff) in definition.handoffs.enumerated() {
            router.add(handoff, id: id)
        }
        self.columns = columns
        edges = router.edges
        connectors = router.connectors
        labels = router.labels
        let laneHeight =
            router.lanes == 0
            ? Self.inset : Self.firstLaneOffset + CGFloat(router.lanes - 1) * Self.laneSpacing + Self.bottomInset
        size = CGSize(width: contentWidth, height: router.stackBottom + laneHeight)
    }

    /// Whether a handoff goes to the very next stage.
    private static func isForward(_ handoff: CoreWorkflowType.Handoff, in stages: [CoreWorkflowType.Stage]) -> Bool {
        guard let from = stages.firstIndex(where: { $0.id == handoff.from.stage }) else { return false }
        return stages.firstIndex { $0.id == handoff.destination.stage } == from + 1
    }

    /// Turns each handoff into its edges, lines, and label.
    private struct Router {
        let definition: CoreWorkflowType.Definition
        let columns: [Column]
        let midY: CGFloat
        let stackBottom: CGFloat
        var edges: [Edge] = []
        var connectors: [Connector] = []
        var labels: [Label] = []
        var lanes = 0

        mutating func add(_ handoff: CoreWorkflowType.Handoff, id: Int) {
            guard let fromIndex = columns.firstIndex(where: { $0.id == handoff.from.stage }),
                let destinationIndex = columns.firstIndex(where: { $0.id == handoff.destination.stage })
            else { return }
            let from = columns[fromIndex].nodes.filter { $0.role.id == handoff.from.role }
            let destination = columns[destinationIndex].nodes.filter { $0.role.id == handoff.destination.role }
            guard !from.isEmpty, !destination.isEmpty else { return }
            let rounds = definition.reviewLoops.first {
                $0.reviewStage == handoff.from.stage && $0.backTo == handoff.destination.stage
            }?.maxRounds
            edges += from.flatMap { source in
                destination.map { Edge(from: source, destination: $0, content: handoff.content, rounds: rounds) }
            }
            let lines =
                destinationIndex == fromIndex + 1
                ? addTrunk(handoff, gapIndex: fromIndex, from: from, to: destination)
                : addLane(handoff, id: id, rounds: rounds, from: from, to: destination)
            connectors.append(Connector(id: id, destinationStageID: handoff.destination.stage, lines: lines))
        }

        /// Separate handoffs across one gap each get their own trunk, so none reads as another's.
        private mutating func addTrunk(
            _ handoff: CoreWorkflowType.Handoff, gapIndex: Int, from: [Node], to destination: [Node]
        ) -> [[CGPoint]] {
            let gap = definition.handoffs.filter {
                $0.from.stage == handoff.from.stage && WorkflowGraphLayout.isForward($0, in: definition.stages)
            }
            let gapLeft = from.first?.frame.maxX ?? 0
            let slot = CGFloat(gap.firstIndex(of: handoff) ?? 0)
            let trunkX = gapLeft + columnGap * (slot + 1) / CGFloat(gap.count + 1)
            let contents = gap.map(\.content).reduce(into: [CoreWorkflowType.HandoffContent]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            let labelID = "\(gapIndex)-\(handoff.content.rawValue)"
            if !labels.contains(where: { $0.id == labelID }) {
                let row = CGFloat(contents.firstIndex(of: handoff.content) ?? 0)
                let top = midY - CGFloat(contents.count - 1) * labelSpacing / 2
                labels.append(
                    Label(
                        id: labelID, text: handoff.content.rawValue.capitalized,
                        center: CGPoint(x: gapLeft + columnGap / 2, y: top + row * labelSpacing),
                        destinationStageID: handoff.destination.stage))
            }
            return WorkflowGraphLayout.trunk(from: from, to: destination, trunkX: trunkX)
        }

        private mutating func addLane(
            _ handoff: CoreWorkflowType.Handoff, id: Int, rounds: Int?, from: [Node], to destination: [Node]
        ) -> [[CGPoint]] {
            let laneY = stackBottom + firstLaneOffset + CGFloat(lanes) * laneSpacing
            lanes += 1
            let lowest = Set(columns.compactMap { $0.nodes.last?.id })
            let text = handoff.content.rawValue.capitalized + (rounds.map { " · up to \($0) rounds" } ?? "")
            let centerX = ((from.last?.frame.midX ?? 0) + (destination.last?.frame.midX ?? 0)) / 2
            labels.append(
                Label(
                    id: "lane-\(id)", text: text, center: CGPoint(x: centerX, y: laneY),
                    destinationStageID: handoff.destination.stage))
            return from.flatMap { source in
                destination.map { target in
                    WorkflowGraphLayout.lane(
                        from: source, isLowest: lowest.contains(source.id), to: target,
                        isLowestTarget: lowest.contains(target.id), laneY: laneY)
                }
            }
        }
    }

    private static func instances(of definition: CoreWorkflowType.Definition, counts: [String: Int]) -> [[Instance]] {
        definition.stages.map { stage in
            stage.roles.compactMap { id in definition.roles.first { $0.id == id } }.flatMap { role in
                let count = min(role.instances.max, max(role.instances.min, counts[role.id] ?? role.instances.min))
                return (1...max(1, count)).map { Instance(role: role, number: $0, count: count) }
            }
        }
    }

    /// Stacks a stage's role instances in one column, centered on the graph's middle.
    private static func column(
        _ stage: CoreWorkflowType.Stage, roles: [Instance], left: CGFloat, width: CGFloat, midY: CGFloat
    ) -> Column {
        let count = CGFloat(roles.count)
        let top = midY - (count * nodeHeight + (count - 1) * nodeSpacing) / 2
        let nodes = roles.enumerated().map { row, item in
            Node(
                stageID: stage.id, role: item.role, instance: item.number, count: item.count,
                frame: CGRect(
                    x: left, y: top + CGFloat(row) * (nodeHeight + nodeSpacing), width: width, height: nodeHeight))
        }
        return Column(stage: stage, nodes: nodes, midX: left + width / 2, titleWidth: width + columnGap - 12)
    }

    /// Lines from each source's right edge to each destination's left edge, turning at one trunk.
    private static func trunk(from: [Node], to destination: [Node], trunkX: CGFloat) -> [[CGPoint]] {
        from.flatMap { source in
            destination.map { target in
                polyline([
                    CGPoint(x: source.frame.maxX, y: source.frame.midY),
                    CGPoint(x: trunkX, y: source.frame.midY),
                    CGPoint(x: trunkX, y: target.frame.midY),
                    CGPoint(x: target.frame.minX - 1, y: target.frame.midY),
                ])
            }
        }
    }

    /// Down from the source, along the lane, and up into the destination. An endpoint with nodes below it
    /// leaves or enters from the side, so the line runs beside its column instead of through it.
    private static func lane(
        from source: Node, isLowest: Bool, to target: Node, isLowestTarget: Bool, laneY: CGFloat
    ) -> [CGPoint] {
        let start =
            isLowest
            ? [CGPoint(x: source.frame.midX, y: source.frame.maxY), CGPoint(x: source.frame.midX, y: laneY)]
            : [
                CGPoint(x: source.frame.maxX, y: source.frame.midY),
                CGPoint(x: source.frame.maxX + sideOffset, y: source.frame.midY),
                CGPoint(x: source.frame.maxX + sideOffset, y: laneY),
            ]
        let end =
            isLowestTarget
            ? [CGPoint(x: target.frame.midX, y: laneY), CGPoint(x: target.frame.midX, y: target.frame.maxY + 1)]
            : [
                CGPoint(x: target.frame.minX - sideOffset, y: laneY),
                CGPoint(x: target.frame.minX - sideOffset, y: target.frame.midY),
                CGPoint(x: target.frame.minX - 1, y: target.frame.midY),
            ]
        return polyline(start + end)
    }

    /// Drops repeated and straight-through points, so every remaining corner is a real turn.
    private static func polyline(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points where point != result.last {
            if result.count >= 2 {
                let (first, second) = (result[result.count - 2], result[result.count - 1])
                let vertical = first.x == second.x && second.x == point.x
                let horizontal = first.y == second.y && second.y == point.y
                if vertical || horizontal { result.removeLast() }
            }
            result.append(point)
        }
        return result
    }
}

/// How far a run has reached each stage.
nonisolated enum WorkflowStageState: Equatable {
    case idle, done, current, pending

    static func of(_ stageID: String, in definition: CoreWorkflowType.Definition, run: CoreWorkflowRun?) -> Self {
        guard let run, let index = definition.stages.firstIndex(where: { $0.id == stageID }) else { return .idle }
        let current = definition.stages.firstIndex { $0.id == run.stageID }
        switch run.status {
        case .running:
            guard let current else { return .idle }
            return index < current ? .done : index == current ? .current : .pending
        case .completed:
            return .done
        case .limitReached, .cancelled, .failed, .interrupted:
            guard let current else { return .idle }
            return index < current ? .done : .idle
        }
    }
}

extension CoreWorkflowRun {
    /// How many agents the run has for each role.
    var roleCounts: [String: Int] {
        agents.reduce(into: [:]) { counts, agent in
            if let role = agent.role { counts[role, default: 0] += 1 }
        }
    }
}
