import SwiftUI

/// Explains that a workflow restored after relaunch runs fresh shells, without its old output.
struct RestoredWorkflowNotice: View {
    let workflow: CoreWorkflow

    var body: some View {
        Label(message, systemImage: "arrow.clockwise")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("restoredWorkflowNotice")
    }

    private var message: String {
        if workflow.run != nil {
            return "Restored workflow — agents are stopped. Previous terminal contents aren't restored."
        }
        let hasAgents = workflow.kind == .agents
        if workflow.terminalIDs.isEmpty {
            return hasAgents
                ? "Restored tab — the shells couldn't restart." : "Restored tab — the shell couldn't restart."
        }
        return hasAgents
            ? "Restored tab — started fresh shells. Previous terminal contents aren't restored."
            : "Restored tab — started a fresh shell. Previous terminal contents aren't restored."
    }
}
