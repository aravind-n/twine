import SwiftUI

/// Native drawing shared by catalog previews, launch forms, and the pinned live workflow type.
struct WorkflowGraph: View {
    let type: CoreWorkflowType
    var counts: [String: Int] = [:]
    var run: CoreWorkflowRun?
    var compact = false

    private var instanceCounts: [String: Int] {
        guard let run else { return counts }
        return run.agents.reduce(into: [:]) { counts, agent in
            if let role = agent.role { counts[role, default: 0] += 1 }
        }
    }

    private var height: CGFloat {
        WorkflowGraphLayout(definition: type.definition, counts: instanceCounts, width: 0, compact: compact).size.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NewTabLayout.spacing) {
            GeometryReader { geometry in
                let layout = WorkflowGraphLayout(
                    definition: type.definition, counts: instanceCounts, width: geometry.size.width, compact: compact)
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        WorkflowGraphConnections(layout: layout, compact: compact)
                            .accessibilityRepresentation {
                                Text(layout.handoffDescriptions.joined(separator: " "))
                                    .accessibilityIdentifier("graphHandoffs")
                            }
                        ForEach(layout.rows) { row in
                            stageTitle(row)
                                .position(x: layout.size.width / 2, y: row.titleY)
                            ForEach(row.nodes) { node in
                                roleNode(node)
                                    .frame(width: node.frame.width, height: node.frame.height)
                                    .position(x: node.frame.midX, y: node.frame.midY)
                            }
                        }
                    }
                    .frame(width: layout.size.width, height: layout.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(height: height)
            ForEach(Array(type.definition.reviewLoops.enumerated()), id: \.offset) { _, loop in
                let from = type.definition.stages.first { $0.id == loop.reviewStage }?.name ?? loop.reviewStage
                let destination = type.definition.stages.first { $0.id == loop.backTo }?.name ?? loop.backTo
                Label(
                    "\(from) → \(destination) · up to \(loop.maxRounds) rounds",
                    systemImage: "arrow.uturn.backward"
                )
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("workflowGraph-\(type.id)")
    }

    private func isCurrent(_ stageID: String) -> Bool {
        run?.status == .running && run?.stageID == stageID
    }

    private func stageTitle(_ row: WorkflowGraphLayout.Row) -> some View {
        HStack(spacing: 4) {
            if isCurrent(row.id) { Image(systemName: "circle.fill").font(.system(size: 5)) }
            Text(row.stage.name)
            if row.nodes.count > 1 { Text("· parallel").foregroundStyle(.secondary) }
        }
        .font(.caption2.weight(isCurrent(row.id) ? .semibold : .medium))
        .foregroundStyle(isCurrent(row.id) ? Color.statusRunning : .secondary)
        .padding(.horizontal, 3)
        .background(compact ? Color.workflowChoiceBackground : Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("graphStage-\(row.id)")
        .accessibilityValue(isCurrent(row.id) ? "Current stage" : "")
        .help(row.stage.completion.rule == .allRolesDone ? "Every role must finish" : "The reviewer decides")
    }

    private func roleNode(_ node: WorkflowGraphLayout.Node) -> some View {
        let style = RoleStyle(role: node.role.name)
        let agent = run?.agents.first { $0.role == node.role.id && $0.instance == node.instance }
        let current = isCurrent(node.stageID)
        return VStack(spacing: 3) {
            HStack(spacing: 4) {
                if !compact { Image(systemName: style.symbol) }
                Text(node.label).lineLimit(2)
                if current && agent?.done == true { Image(systemName: "checkmark") }
            }
            .font(compact ? .system(size: 10, weight: .medium) : .caption.weight(.semibold))
            if !compact, let agent { Text(agent.harness.displayName).font(.caption2).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(style.color)
        .background(style.color.opacity(current ? 0.22 : 0.10), in: .rect(cornerRadius: CornerRadius.choiceTile))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.choiceTile)
                .stroke(style.color.opacity(current ? 1 : 0.35), lineWidth: current ? 2 : Surface.hairlineWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("graphNode-\(node.id)")
        .accessibilityValue(current ? (agent?.done == true ? "Done" : "Running") : "")
    }
}

private struct WorkflowGraphConnections: View {
    let layout: WorkflowGraphLayout
    let compact: Bool

    var body: some View {
        Canvas { context, _ in
            for edge in layout.edges {
                let from = edge.from.frame
                let destination = edge.destination.frame
                var path = Path()
                let end: CGPoint
                let previous: CGPoint
                if let lane = edge.laneX {
                    path.move(to: CGPoint(x: from.minX, y: from.midY))
                    path.addLine(to: CGPoint(x: lane, y: from.midY))
                    path.addLine(to: CGPoint(x: lane, y: destination.midY))
                    end = CGPoint(x: destination.minX - 2, y: destination.midY)
                    previous = CGPoint(x: lane, y: destination.midY)
                    path.addLine(to: end)
                } else {
                    let start = CGPoint(x: from.midX, y: from.maxY)
                    end = CGPoint(x: destination.midX, y: destination.minY - 2)
                    previous = CGPoint(x: end.x, y: (start.y + end.y) / 2)
                    path.move(to: start)
                    path.addCurve(
                        to: end, control1: CGPoint(x: start.x, y: previous.y), control2: previous)
                }
                let color = RoleStyle(role: edge.from.role.name).color.opacity(0.65)
                context.stroke(
                    path, with: .color(color),
                    style: StrokeStyle(lineWidth: 1, dash: edge.content == .feedback ? [3, 3] : []))
                let angle = atan2(end.y - previous.y, end.x - previous.x)
                var arrow = Path()
                arrow.move(to: CGPoint(x: end.x - 4 * cos(angle - .pi / 6), y: end.y - 4 * sin(angle - .pi / 6)))
                arrow.addLine(to: end)
                arrow.addLine(to: CGPoint(x: end.x - 4 * cos(angle + .pi / 6), y: end.y - 4 * sin(angle + .pi / 6)))
                context.stroke(arrow, with: .color(color), lineWidth: 1)
            }
            for row in layout.rows {
                let outgoing = layout.edges.filter { $0.from.stageID == row.id && $0.laneX == nil }
                let labels = Set(outgoing.map { $0.content.rawValue.capitalized }).sorted().joined(separator: " · ")
                if !labels.isEmpty, let node = row.nodes.first {
                    context.draw(
                        Text(labels).font(.system(size: compact ? 8 : 10)).foregroundStyle(.secondary),
                        at: CGPoint(x: layout.size.width / 2, y: node.frame.maxY + (compact ? 10 : 14)))
                }
            }
        }
    }
}

#Preview("Catalog graphs") {
    @Previewable @State var types: [CoreWorkflowType] = []
    @Previewable @State var failure: String?
    ScrollView {
        VStack {
            ForEach(types) { WorkflowTypeChoiceTile(type: $0) }
            if let failure { Text(failure).font(.caption) }
        }
        .padding()
    }
    .frame(width: 340, height: 600)
    .task {
        let worker = CoreWorker(dataDirectory: .temporaryDirectory.appending(path: "TwineGraphPreview"))
        do {
            types = try await worker.open().workflowTypes ?? []
            await worker.close()
        } catch {
            failure = error.localizedDescription
            await worker.close()
        }
    }
}
