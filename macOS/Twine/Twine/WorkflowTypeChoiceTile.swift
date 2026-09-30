import SwiftUI

struct WorkflowTypeChoiceTile: View {
    let type: CoreWorkflowType

    var body: some View {
        ChoiceTile(symbol: "flowchart", title: type.definition.name, detail: type.definition.description)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(type.definition.name)
            .accessibilityValue(
                type.definition.stages.map { stage in
                    let roles = stage.roles.compactMap { id in type.definition.roles.first { $0.id == id }?.name }
                    return "\(stage.name): \(roles.joined(separator: ", "))"
                }.joined(separator: "; ") + "; "
                    + WorkflowGraphLayout(definition: type.definition, width: 0)
                    .handoffDescriptions.joined(separator: " "))
    }
}
