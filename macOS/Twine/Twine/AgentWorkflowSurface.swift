import SwiftUI

/// An agents workflow's panel: subtabs when there is more than one agent, over every agent's live
/// terminal in the workflow's layout. The layout, including the agent with the keyboard, is kept for
/// each workflow across relaunch.
struct AgentWorkflowSurface: View {
    @Environment(WorkflowLayouts.self) private var layouts
    @Environment(TraceTerminalNavigation.self) private var navigation
    let folder: String
    let workflow: CoreWorkflow
    let isSelected: Bool
    let reportFailure: (String) -> Void
    /// Whether Bento panes are tiled, with headers that name their agents.
    @State private var panesAreTiled = false
    private var destination: TraceTerminalTarget? {
        navigation.destination.flatMap { $0.workflowID == workflow.id ? $0 : nil }
    }

    var body: some View {
        let layout = Binding(
            get: { layouts.layout(for: workflow.id, in: folder) },
            set: { layouts.setLayout($0, for: workflow.id, in: folder) }
        )
        let focused = layout.wrappedValue.focusedAgent(in: workflow.agents)
        VStack(spacing: 0) {
            if workflow.showsTerminalStrip {
                AgentSubtabs(
                    agents: workflow.agents, selectedID: focused?.id,
                    workingIDs: Set(workflow.run?.agents.filter(\.isWorking).map(\.id) ?? []),
                    harnesses: workflow.run?.agents.reduce(into: [:]) { $0[$1.id] = $1.harness.displayName } ?? [:],
                    mode: layout.mode, showsSubtabs: workflow.showsAgentSubtabs && !panesAreTiled,
                    showsLayoutPicker: isSelected
                ) {
                    layout.wrappedValue.focus($0, in: workflow.agents)
                    navigation.target = nil
                    navigation.scrollTarget = nil
                } actions: {
                    if let run = workflow.run {
                        WorkflowRunControls(
                            workflowID: workflow.id, run: run, selectedAgentID: focused?.id,
                            selectedRole: focused?.role, reportFailure: reportFailure)
                    }
                }
            }
            if workflow.restored {
                RestoredWorkflowNotice(workflow: workflow)
                    .background(workflow.showsTerminalStrip ? Color.workflowTint : .clear)
            }
            AgentPanes(workflow: workflow, layout: layout, isSelected: isSelected) { panesAreTiled = $0 }
        }
        .onChange(of: destination, initial: true) {
            guard let history = destination else { return }
            let id = history.agentID ?? workflow.agents.first(where: { $0.terminalID == history.anchor.terminalID })?.id
            if let id { layout.wrappedValue.focus(id, in: workflow.agents) }
        }
        .onAppear {
            let active = workflow.run?.agents.filter(\.active).map(\.id) ?? []
            layout.wrappedValue.openOnFirstStage(activeAgentIDs: active, in: workflow.agents)
        }
    }
}
