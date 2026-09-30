import SwiftUI

struct WorkflowTypeChoiceTile: View {
    let type: CoreWorkflowType

    var body: some View {
        VStack(alignment: .leading, spacing: NewTabLayout.spacing) {
            Label(type.definition.name, systemImage: "flowchart")
                .font(.caption.weight(.semibold))
            Text(type.definition.description)
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(2)
            WorkflowGraph(type: type, compact: true)
                .accessibilityHidden(true)
        }
        .padding(NewTabLayout.choicePadding)
        .frame(maxWidth: .infinity, minHeight: NewTabLayout.minimumChoiceHeight, alignment: .topLeading)
        .background(.workflowChoiceBackground, in: .rect(cornerRadius: CornerRadius.choiceTile))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.choiceTile).stroke(.hairline, lineWidth: Surface.hairlineWidth)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(type.definition.name)
        .accessibilityValue(
            type.definition.stages.map { stage in
                let roles = stage.roles.compactMap { id in type.definition.roles.first { $0.id == id }?.name }
                return "\(stage.name): \(roles.joined(separator: ", "))"
            }.joined(separator: "; ") + "; "
                + WorkflowGraphLayout(definition: type.definition, width: 0, compact: true)
                .handoffDescriptions.joined(separator: " "))
    }
}
