import SwiftUI

/// Shared card geometry keeps agent cards and link hit areas in the same coordinates.
nonisolated enum WorkflowEditorLayout {
    static let cardSize = CGSize(width: 216, height: 108)
    static let portHitSize: CGFloat = 28
    static let canvasMargin: CGFloat = 52

    static func defaultPosition(for id: String, roles: [CoreWorkflowType.Role]) -> CoreWorkflowType.Position {
        let index = roles.firstIndex { $0.id == id } ?? 0
        return .init(x: 330 + (index % 3) * 300, y: 220 + (index / 3) * 180)
    }

    static func nextRolePosition(
        in definition: CoreWorkflowType.Definition, near preferred: CoreWorkflowType.Position? = nil
    ) -> CoreWorkflowType.Position {
        let occupied = positions(for: definition)
        var position = preferred ?? CoreWorkflowType.Position(x: 480, y: 220)
        let step = position.y + (occupied.count + 1) * 176 <= 4000 ? 176 : -176
        while occupied.contains(where: {
            abs(CGFloat($0.x - position.x)) < cardSize.width + 32
                && abs(CGFloat($0.y - position.y)) < cardSize.height + 32
        }) {
            position.y += step
        }
        return position
    }

    static func fitScale(for definition: CoreWorkflowType.Definition, viewport: CGSize) -> CGFloat {
        let size = canvasSize(for: definition)
        return min(1, max(1, viewport.width - 24) / size.width, max(1, viewport.height - 24) / size.height)
    }

    private static func positions(for definition: CoreWorkflowType.Definition) -> [CoreWorkflowType.Position] {
        let nodes = definition.roles.map(\.id)
        return nodes.map { definition.graph?.positions[$0] ?? defaultPosition(for: $0, roles: definition.roles) }
    }

    static func returnLane(
        for edge: CoreWorkflowType.Edge, edges: [CoreWorkflowType.Edge], point: (String) -> CGPoint
    ) -> CGFloat? {
        let from = point(edge.from)
        let destination = point(edge.to)
        guard edge.event == .feedback || destination.x <= from.x else { return nil }
        let siblings = edges.filter {
            (($0.from == edge.from && $0.to == edge.to) || ($0.from == edge.to && $0.to == edge.from))
                && ($0.event == .feedback || point($0.to).x <= point($0.from).x)
        }
        let index = siblings.firstIndex { $0.id == edge.id } ?? 0
        return max(from.y, destination.y) + cardSize.height / 2 + 56 + CGFloat(index) * 30
    }

    private static func point(_ id: String, in definition: CoreWorkflowType.Definition) -> CGPoint {
        let position = definition.graph?.positions[id] ?? defaultPosition(for: id, roles: definition.roles)
        return CGPoint(x: position.x, y: position.y)
    }

    static func originOffset(for definition: CoreWorkflowType.Definition) -> CGSize {
        let positions = positions(for: definition)
        guard !positions.isEmpty else { return .zero }
        let edges = definition.graph?.agentEdges ?? []
        let hasReturn = edges.contains {
            returnLane(for: $0, edges: edges, point: { point($0, in: definition) }) != nil
        }
        return CGSize(
            width: max(
                0, cardSize.width / 2 + canvasMargin + (hasReturn ? 56 : 0) - CGFloat(positions.map(\.x).min() ?? 0)),
            height: max(0, cardSize.height / 2 + canvasMargin - CGFloat(positions.map(\.y).min() ?? 0)))
    }

    static func canvasSize(for definition: CoreWorkflowType.Definition) -> CGSize {
        let positions = positions(for: definition)
        let offset = originOffset(for: definition)
        let edges = definition.graph?.agentEdges ?? []
        let returns = edges.compactMap { edge -> (x: CGFloat, y: CGFloat)? in
            guard let lane = returnLane(for: edge, edges: edges, point: { point($0, in: definition) }) else {
                return nil
            }
            return (point(edge.from, in: definition).x + cardSize.width / 2 + 56, lane + 14)
        }
        return CGSize(
            width: max(
                960,
                max(positions.map { CGFloat($0.x) + cardSize.width / 2 }.max() ?? 0, returns.map(\.x).max() ?? 0)
                    + canvasMargin + offset.width),
            height: max(
                440,
                max(positions.map { CGFloat($0.y) + cardSize.height / 2 }.max() ?? 0, returns.map(\.y).max() ?? 0)
                    + canvasMargin + offset.height))
    }
}

/// Interface surfaces use system colors and remain opaque over the draft terminal.
enum WorkflowEditorStyle {
    static var canvas: Color { Color(nsColor: .underPageBackgroundColor) }
    static var card: Color { Color(nsColor: .windowBackgroundColor) }
    static var border: Color { Color.primary.opacity(0.14) }
    static var grid: Color { Color.primary.opacity(0.16) }
}

struct WorkflowGraphCard: View {
    let title: String
    var emphasized = false
    var tint: Color?
    var startsHere = false
    var returnsResult = false
    var reviewsWork = false
    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Circle().fill(tint ?? .secondary).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
            }
            Spacer(minLength: 8)
            WorkflowAgentBadges(startsHere: startsHere, returnsResult: returnsResult, reviewsWork: reviewsWork)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .frame(
            width: WorkflowEditorLayout.cardSize.width, height: WorkflowEditorLayout.cardSize.height,
            alignment: .topLeading
        )
        .background(WorkflowEditorStyle.card, in: .rect(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11).stroke(
                emphasized
                    ? Color.accentColor
                    : (tint?.opacity(contrast == .increased ? 0.85 : (hovered ? 0.6 : 0.4))
                        ?? WorkflowEditorStyle.border),
                lineWidth: emphasized ? 2 : 1)
        }
        .shadow(color: .black.opacity(hovered ? 0.12 : 0.06), radius: hovered ? 6 : 3, y: 2)
        .contentShape(.rect).onHover { hovered = $0 }
    }
}

struct WorkflowAgentBadges: View {
    let startsHere: Bool
    let returnsResult: Bool
    var reviewsWork = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { badges }
            VStack(alignment: .leading, spacing: 4) { badges }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var badges: some View {
        if startsHere { badge("Starts here", symbol: "arrow.right.circle") }
        if returnsResult {
            badge(reviewsWork ? "Result on approval" : "Returns result", symbol: "checkmark.circle")
        }
        if !startsHere && !returnsResult { badge("Receives work", symbol: "arrow.down.circle") }
    }

    private func badge(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 4)).fixedSize()
    }
}

struct WorkflowCanvasGrid: View {
    let zoom: Double

    var body: some View {
        Canvas { context, canvasSize in
            let spacing = max(12, 24 * zoom)
            var dots = Path()
            for horizontal in stride(from: spacing / 2, through: canvasSize.width, by: spacing) {
                for vertical in stride(from: spacing / 2, through: canvasSize.height, by: spacing) {
                    dots.addEllipse(in: CGRect(x: horizontal, y: vertical, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(WorkflowEditorStyle.grid))
        }.accessibilityHidden(true).allowsHitTesting(false)
    }

}

struct WorkflowFirstRoleAction: View {
    let addRole: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Add an agent to start").font(.headline)
            Text("Double-click to add an agent. Right-click for canvas tools.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add your first agent", systemImage: "plus", action: addRole)
                .buttonStyle(.borderedProminent).controlSize(.regular)
        }
        .frame(width: WorkflowEditorLayout.cardSize.width)
    }
}
