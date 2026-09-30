import SwiftUI

/// A running workflow keeps the core's pinned definition. Inspection offers no type selector.
struct WorkflowTypeInspector: View {
    @Environment(\.dismiss) private var dismiss
    let type: BridgeWorkflowType
    let run: BridgeWorkflowRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NewTabLayout.sectionSpacing) {
                HStack {
                    Text("WORKFLOW TYPE").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                    Spacer()
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.mini)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("closeWorkflowType")
                }
                HStack {
                    Text(type.definition.name).font(.headline)
                    if let version = type.reference.user?.version {
                        Text("Version \(version)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(run.status == .running ? "Running" : run.status.rawValue.capitalized)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(type.definition.description).font(.caption).foregroundStyle(.secondary)
                WorkflowGraph(type: type, run: run)
            }
            .padding(NewTabLayout.padding)
        }
        .frame(
            width: 480,
            height: min(
                600,
                WorkflowGraphLayout(
                    definition: type.definition, width: 480, compact: false
                ).size.height + 160)
        )
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.panel).stroke(.hairline, lineWidth: Surface.hairlineWidth)
        }
        .accessibilityIdentifier("workflowTypeInspector")
    }
}
