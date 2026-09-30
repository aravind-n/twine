import SwiftUI

/// An agents workflow's panel: subtabs when there is more than one agent, over every agent's live
/// terminal in the workflow's layout. The layout, including the agent with the keyboard, is kept for
/// each workflow across relaunch.
struct AgentWorkflowSurface: View {
    @Environment(WorkflowLayouts.self) private var layouts
    let folder: String
    let workflow: BridgeWorkflow
    let isSelected: Bool

    var body: some View {
        let layout = Binding(
            get: { layouts.layout(for: workflow.id, in: folder) },
            set: { layouts.setLayout($0, for: workflow.id, in: folder) }
        )
        VStack(spacing: 0) {
            if workflow.showsAgentSubtabs {
                AgentSubtabs(
                    agents: workflow.agents,
                    selectedID: layout.wrappedValue.focusedAgent(in: workflow.agents)?.id,
                    mode: layout.mode, showsLayoutPicker: isSelected
                ) { layout.wrappedValue.focus($0, in: workflow.agents) }
            }
            // Under subtabs, the run controls and notice join the strip, which Bento panes also sit on.
            if let run = workflow.run {
                WorkflowRunControls(
                    workflowID: workflow.id, run: run,
                    selectedAgentID: layout.wrappedValue.focusedAgent(in: workflow.agents)?.id
                )
                .background(workflow.showsAgentSubtabs ? Color.workflowTint : .clear)
            }
            if workflow.restored {
                RestoredWorkflowNotice(workflow: workflow)
                    .background(workflow.showsAgentSubtabs ? Color.workflowTint : .clear)
            }
            AgentPanes(workflow: workflow, layout: layout, isSelected: isSelected)
        }
    }
}
