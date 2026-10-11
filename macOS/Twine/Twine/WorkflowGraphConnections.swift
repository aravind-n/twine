import SwiftUI

/// Nodes and links share one settings selection so only one popover can be open.
enum WorkflowGraphSelection: Equatable {
    case node(String)
    case edge(String)
}

struct WorkflowGraphConnections: View {
    let model: WorkflowDesignerModel
    @Binding var selection: WorkflowGraphSelection?
    let source: String?
    let pointer: CGPoint?
    let target: String?
    var startsAtInput = false
    let point: (String) -> CGPoint

    private var edges: [CoreWorkflowType.Edge] { model.definition.graph?.agentEdges ?? [] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            drawing
            ForEach(edges) { edge in
                Button {
                    selection = .edge(edge.id)
                } label: {
                    HStack(spacing: 4) {
                        Text(edge.event.title)
                        MenuChevron()
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(WorkflowEditorStyle.card, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(WorkflowEditorStyle.border) }
                }
                .buttonStyle(.plain)
                .fixedSize()
                .popover(isPresented: presentation(edge.id)) {
                    WorkflowLinkPopover(model: model, edge: edge) { selection = nil }.appZoom()
                }
                .position(labelPoint(edge))
                .help("Edit this link")
                .accessibilityIdentifier("graphLink-\(edge.id)")
                .accessibilityLabel(linkTitle(edge))
            }

        }
    }

    private var drawing: some View {
        ZStack(alignment: .topLeading) {
            ForEach(edges) { edge in
                WorkflowConnectionShape(
                    from: point(edge.from), destination: point(edge.to), feedback: edge.event == .feedback,
                    lane: WorkflowEditorLayout.returnLane(for: edge, edges: edges, point: point)
                )
                .stroke(
                    selection == .edge(edge.id) ? Color.accentColor : linkColor(edge.from),
                    style: .init(
                        lineWidth: 1.5, lineCap: .round, lineJoin: .round,
                        dash: edge.event == .feedback ? [5, 4] : []))
            }
            if let source, let pointer {
                WorkflowConnectionShape(
                    from: startsAtInput ? (target.map(point) ?? pointer) : point(source),
                    destination: startsAtInput ? point(source) : (target.map(point) ?? pointer),
                    atPort: startsAtInput || target != nil,
                    sourceAtPort: !startsAtInput || target != nil
                )
                .stroke(Color.accentColor, style: .init(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }

    private func linkColor(_ source: String) -> Color {
        (model.definition.roles.first { $0.id == source }?.color?.tint ?? .secondary).opacity(0.65)
    }

    func linkTitle(_ edge: CoreWorkflowType.Edge) -> String {
        func name(_ id: String) -> String {
            model.definition.roles.first { $0.id == id }?.name ?? id.capitalized
        }
        return "\(name(edge.from)) to \(name(edge.to)): \(edge.event.title)"
    }

    func labelPoint(_ edge: CoreWorkflowType.Edge) -> CGPoint {
        let from = point(edge.from)
        let destination = point(edge.to)
        if let lane = WorkflowEditorLayout.returnLane(for: edge, edges: edges, point: point) {
            return CGPoint(
                x: (from.x + destination.x) / 2,
                y: lane)
        }
        let siblings = edges.filter {
            ($0.from == edge.from && $0.to == edge.to) || ($0.from == edge.to && $0.to == edge.from)
        }
        let index = siblings.firstIndex(where: { $0.id == edge.id }) ?? 0
        let offset = (CGFloat(index) - CGFloat(siblings.count - 1) / 2) * 30
        return CGPoint(x: (from.x + destination.x) / 2, y: (from.y + destination.y) / 2 + offset)
    }

    private func presentation(_ id: String) -> Binding<Bool> {
        Binding(get: { selection == .edge(id) }, set: { if !$0 && selection == .edge(id) { selection = nil } })
    }
}

/// Vector paths can extend beyond the saved graph bounds while a node is dragged.
nonisolated struct WorkflowConnectionShape: Shape {
    let from: CGPoint
    let destination: CGPoint
    var atPort = true
    var feedback = false
    var sourceAtPort = true
    var lane: CGFloat?

    func path(in rect: CGRect) -> Path {
        let start = CGPoint(
            x: from.x + (sourceAtPort ? WorkflowEditorLayout.cardSize.width / 2 : 0), y: from.y)
        let end = CGPoint(x: destination.x - (atPort ? WorkflowEditorLayout.cardSize.width / 2 : 0), y: destination.y)
        let bend = max(56, abs(end.x - start.x) / 2)
        var path = Path()
        path.move(to: start)
        if sourceAtPort && atPort && (feedback || destination.x <= from.x) {
            let lane = lane ?? max(from.y, destination.y) + WorkflowEditorLayout.cardSize.height / 2 + 56
            path.addCurve(
                to: CGPoint(x: start.x, y: lane),
                control1: CGPoint(x: start.x + 56, y: start.y), control2: CGPoint(x: start.x + 56, y: lane))
            path.addLine(to: CGPoint(x: end.x, y: lane))
            path.addCurve(
                to: end, control1: CGPoint(x: end.x - 56, y: lane),
                control2: CGPoint(x: end.x - 56, y: end.y))
        } else {
            path.addCurve(
                to: end, control1: CGPoint(x: start.x + bend, y: start.y),
                control2: CGPoint(x: end.x - bend, y: end.y))
        }
        path.move(to: CGPoint(x: end.x - 6, y: end.y - 3))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - 6, y: end.y + 3))
        return path
    }
}

struct WorkflowGraphConnectionMenu: View {
    let model: WorkflowDesignerModel
    let source: String
    var connected: () -> Void = {}

    private var destinations: [String] {
        model.definition.roles.map(\.id).filter { model.canConnect(from: source, to: $0) }
    }

    var body: some View {
        Menu("Connect to…") {
            ForEach(destinations, id: \.self) { destination in
                Button(model.definition.roles.first { $0.id == destination }?.name ?? "Agent") {
                    model.connect(from: source, to: destination)
                    connected()
                }
            }
        }.disabled(destinations.isEmpty)
    }
}
