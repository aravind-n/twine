import SwiftUI

struct WorkflowTypeChoiceTile: View {
    let type: CoreWorkflowType
    let choose: () -> Void
    var delete: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            ChoiceTile(
                symbol: "flowchart", title: type.definition.name, detail: type.definition.description,
                trailingSpace: delete == nil ? 0 : 20)
        }
        .buttonStyle(.plain)
        .help(type.definition.description)
        .accessibilityLabel(type.definition.name)
        .accessibilityValue(
            type.definition.stages.map { stage in
                let roles = stage.roles.compactMap { id in type.definition.roles.first { $0.id == id }?.name }
                return "\(stage.name): \(roles.joined(separator: ", "))"
            }.joined(separator: "; ") + "; "
                + WorkflowGraphLayout(definition: type.definition, width: 0).handoffDescriptions.joined(separator: " ")
        )
        .accessibilityIdentifier(
            type.reference.builtin == nil ? "workflowChoice-\(type.id)" : "workflowChoice-\(type.definition.name)"
        )
        .overlay(alignment: .topTrailing) {
            if let delete {
                Button("Delete \(type.definition.name)", systemImage: "xmark", action: delete)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: .circle)
                    .contentShape(.circle)
                    .buttonStyle(.plain)
                    .help("Delete workflow")
                    .padding(4)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                    .accessibilityHidden(!isHovered)
                    .accessibilityIdentifier("workflowDelete-\(type.id)")
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            if let delete { Button("Delete Workflow…", role: .destructive, action: delete) }
        }
    }
}
