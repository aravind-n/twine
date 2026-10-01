import SwiftUI

/// A workflow type drawn as a left-to-right pipeline, used by the launch form and the live run inspector.
struct WorkflowGraph: View {
    let type: CoreWorkflowType
    var counts: [String: Int] = [:]
    var run: CoreWorkflowRun?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stages a running workflow hasn't reached yet.
    static let pendingOpacity: Double = 0.4

    private var instanceCounts: [String: Int] { run?.roleCounts ?? counts }

    private var height: CGFloat {
        WorkflowGraphLayout(definition: type.definition, counts: instanceCounts, width: 0).size.height
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = WorkflowGraphLayout(
                definition: type.definition, counts: instanceCounts, width: geometry.size.width)
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    WorkflowGraphConnectors(
                        connectors: layout.connectors,
                        dimmed: Set(layout.columns.map(\.id).filter { state(of: $0) == .pending })
                    )
                    .accessibilityRepresentation {
                        Text(layout.handoffDescriptions.joined(separator: " "))
                            .accessibilityIdentifier("graphHandoffs")
                    }
                    ForEach(layout.labels) { label in
                        handoffLabel(label.text, isPending: state(of: label.destinationStageID) == .pending)
                            .position(label.center)
                    }
                    ForEach(layout.columns) { column in
                        stageTitle(column)
                            .frame(maxWidth: column.titleWidth)
                            .position(x: column.midX, y: WorkflowGraphLayout.titleHeight / 2 - 2)
                        ForEach(column.nodes) { node in
                            roleNode(node)
                                .frame(width: node.frame.width, height: node.frame.height)
                                .position(x: node.frame.midX, y: node.frame.midY)
                        }
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .smooth, value: run)
        .accessibilityIdentifier("workflowGraph-\(type.id)")
    }

    private func state(of stageID: String) -> WorkflowStageState {
        .of(stageID, in: type.definition, run: run)
    }

    /// The fill stays opaque when pending, so the line under the label never shows through its text.
    private func handoffLabel(_ label: String, isPending: Bool) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isPending ? .tertiary : .secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(.workflowChoiceBackground, in: .capsule)
            .overlay {
                Capsule().stroke(
                    .hairline.opacity(isPending ? Self.pendingOpacity : 1), lineWidth: Surface.hairlineWidth)
            }
            .accessibilityHidden(true)
    }

    private func stageTitle(_ column: WorkflowGraphLayout.Column) -> some View {
        let current = state(of: column.id) == .current
        return HStack(spacing: 5) {
            if current { Circle().fill(Color.statusRunning).frame(width: 5, height: 5) }
            Text(column.stage.name.uppercased())
            if column.nodes.count > 1 { Text("· \(column.nodes.count)") }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(current ? Color.statusRunning : .secondary)
        .opacity(state(of: column.id) == .pending ? Self.pendingOpacity : 1)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(column.stage.name)
        .accessibilityIdentifier("graphStage-\(column.id)")
        .accessibilityValue(current ? "Current stage" : "")
        .help(column.stage.completion.rule == .allRolesDone ? "Every role must finish" : "The reviewer decides")
    }

    private func roleNode(_ node: WorkflowGraphLayout.Node) -> some View {
        let style = RoleStyle(role: node.role.name)
        let agent = run?.agents.first { $0.role == node.role.id && $0.instance == node.instance }
        let stage = state(of: node.stageID)
        let done = stage == .done || (stage == .current && agent?.done == true)
        let running = stage == .current && !done
        return HStack(spacing: 8) {
            ZStack {
                if running { PulseRing(color: style.color) }
                Circle().fill(style.color.gradient)
                Image(systemName: style.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.label).font(.caption.weight(.medium))
                if let agent {
                    Text(agent.harness.displayName).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.statusRunning)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.workflowChoiceBackground, in: .rect(cornerRadius: CornerRadius.graphNode))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.graphNode)
                .stroke(running ? style.color : Color.hairline, lineWidth: running ? 1.5 : Surface.hairlineWidth)
        }
        .opacity(stage == .pending ? Self.pendingOpacity : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("graphNode-\(node.id)")
        .accessibilityValue(done ? "Done" : running ? "Running" : "")
    }
}

/// Handoff lines in one neutral color, with rounded corners and filled arrowheads.
private struct WorkflowGraphConnectors: View {
    let connectors: [WorkflowGraphLayout.Connector]
    let dimmed: Set<String>
    private let arrowLength: CGFloat = 6
    private let cornerRadius: CGFloat = 8

    var body: some View {
        Canvas { context, _ in
            for isDimmed in [false, true] {
                var lines = Path()
                var arrows = Path()
                for connector in connectors where dimmed.contains(connector.destinationStageID) == isDimmed {
                    for points in connector.lines {
                        add(points, lines: &lines, arrows: &arrows)
                    }
                }
                // One stroke per group, so shared trunks don't darken where lines overlap.
                context.opacity = isDimmed ? WorkflowGraph.pendingOpacity : 1
                context.stroke(
                    lines, with: .style(.tertiary),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                context.fill(arrows, with: .style(.tertiary))
            }
        }
    }

    private func add(_ points: [CGPoint], lines: inout Path, arrows: inout Path) {
        guard points.count >= 2, let tip = points.last else { return }
        let previous = points[points.count - 2]
        let length = hypot(tip.x - previous.x, tip.y - previous.y)
        guard length > 0 else { return }
        let direction = CGPoint(x: (tip.x - previous.x) / length, y: (tip.y - previous.y) / length)
        let base = CGPoint(x: tip.x - direction.x * arrowLength, y: tip.y - direction.y * arrowLength)

        lines.move(to: points[0])
        for index in 1..<(points.count - 1) {
            let corner = points[index]
            let radius = min(
                cornerRadius,
                hypot(corner.x - points[index - 1].x, corner.y - points[index - 1].y) / 2,
                hypot(points[index + 1].x - corner.x, points[index + 1].y - corner.y) / 2)
            lines.addArc(tangent1End: corner, tangent2End: points[index + 1], radius: radius)
        }
        lines.addLine(to: base)

        let normal = CGPoint(x: -direction.y * 3.5, y: direction.x * 3.5)
        arrows.move(to: tip)
        arrows.addLine(to: CGPoint(x: base.x + normal.x, y: base.y + normal.y))
        arrows.addLine(to: CGPoint(x: base.x - normal.x, y: base.y - normal.y))
        arrows.closeSubpath()
    }
}

/// An expanding ring behind a running role's avatar. It holds still when Reduce Motion is on.
private struct PulseRing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .scaleEffect(reduceMotion ? 1.3 : expanded ? 1.7 : 1)
            .opacity(reduceMotion ? 0.5 : expanded ? 0 : 0.8)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expanded = true }
            }
    }
}

#Preview("Workflow graphs") {
    @Previewable @State var types: [CoreWorkflowType] = []
    @Previewable @State var failure: String?
    ScrollView {
        VStack(spacing: 24) {
            ForEach(types) { WorkflowGraph(type: $0, counts: ["worker": 3]) }
            if let failure { Text(failure).font(.caption) }
        }
        .padding()
    }
    .frame(width: 700, height: 500)
    .background(.workflowChoicesBackground)
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
