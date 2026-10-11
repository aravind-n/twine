import SwiftUI

/// Workflow-wide follow-up mode and run actions in the native window toolbar.
struct WorkflowRunControls<LayoutControl: View>: View {
    @Environment(CoreClient.self) private var client
    let workflowID: UInt64
    let run: CoreWorkflowRun
    let selectedAgentID: UInt64?
    /// The selected agent's role, named in Mark done's tooltip.
    var selectedRole: String?
    var compact = false
    let reportFailure: (String) -> Void
    @ViewBuilder var layoutControl: LayoutControl
    @State private var showsCompletion = false
    @State private var showsGraph = false

    private var agent: CoreWorkflowRun.Agent? { run.agents.first { $0.id == selectedAgentID } }
    private var hasLiveAgents: Bool {
        client.snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.terminalIDs.contains {
            client.terminalStatus(for: $0) == .running
        } == true
    }

    var body: some View {
        HStack(spacing: AgentSubtabLayout.actionSpacing) {
            Menu {
                if compact {
                    layoutControl
                    Divider()
                }
                if run.agents.count > 1 {
                    Button {
                        Task {
                            do {
                                try await client.setWorkflowIndividualMode(
                                    workflowID: workflowID, individualMode: !run.individualMode)
                            } catch { reportFailure(error.localizedDescription) }
                        }
                    } label: {
                        Label("Individual mode: \(run.individualMode ? "On" : "Off")", systemImage: "person")
                    }
                    .disabled(!run.canChangeIndividualMode || client.workflowModeChanges[workflowID] != nil)
                    .help(
                        !run.canChangeIndividualMode
                            ? "Individual mode is available after the workflow finishes."
                            : run.individualMode
                                ? "On: follow up with each agent individually. Turn Off to allow a new workflow cycle."
                                : "Off: a follow-up to a first-stage agent can start another workflow cycle. "
                                    + "Turn On to work with agents individually."
                    )
                    .accessibilityLabel("Individual mode: \(run.individualMode ? "On" : "Off")")
                    .accessibilityValue(run.individualMode ? "On" : "Off")
                    .accessibilityIdentifier("workflowIndividualMode")
                }
                if let type = run.workflowType {
                    Button {
                        showsGraph.toggle()
                    } label: {
                        Label(type.definition.name, systemImage: "flowchart")
                    }
                    .help("\(type.definition.name) workflow")
                    .accessibilityLabel("Show \(type.definition.name) workflow graph")
                    .accessibilityIdentifier("inspectWorkflowType")
                }
                if let agent, agent.active && !agent.done {
                    Button {
                        showsCompletion = true
                    } label: {
                        Label("Mark done…", systemImage: "checkmark")
                    }
                    .help(selectedRole.map { "Mark \($0) done…" } ?? "Mark done…")
                    .accessibilityIdentifier("workflowMarkDone")
                }
            } label: {
                Label("Workflow", systemImage: "ellipsis.circle")
            }
            .labelStyle(compact ? WorkspaceToolbarLabelStyle.icon : WorkspaceToolbarLabelStyle.title)
            .menuIndicator(compact ? .hidden : .visible)
            .frame(width: compact ? 26 : nil)
            .accessibilityIdentifier("workflowActionsMenu")
            .popover(isPresented: $showsGraph) {
                if let type = run.workflowType {
                    WorkflowTypeInspector(type: type, run: run).appZoom()
                }
            }
            if !compact { layoutControl }
            if run.status == .running || hasLiveAgents {
                Button {
                    Task {
                        do { try await client.cancelWorkflowRun(workflowID: workflowID) } catch {
                            reportFailure(error.localizedDescription)
                        }
                    }
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .labelStyle(compact ? WorkspaceToolbarLabelStyle.icon : WorkspaceToolbarLabelStyle.titleAndIcon)
                .frame(width: compact ? 26 : nil)
                .accessibilityLabel("Cancel workflow")
                .help("Cancel workflow")
                .accessibilityIdentifier("workflowCancel")
            }
        }
        .controlSize(.small)
        .sheet(isPresented: $showsCompletion) {
            if let agent {
                WorkflowCompletionForm(
                    workflowID: workflowID, generation: run.generation, agent: agent, needsTask: run.needsTask
                )
                .appZoom()
            }
        }
        .onChange(of: run.generation) { showsCompletion = false }
        .onChange(of: run.status) { if run.status != .running { showsCompletion = false } }
        .onChange(of: selectedAgentID) { showsCompletion = false }
    }
}

#Preview {
    WorkflowRunControls(
        workflowID: 1,
        run: .init(
            generation: 1, stage: "Review", status: .running, message: nil, needsTask: false,
            agents: [.init(agentId: 1, active: true, done: false, reviewer: true, harness: .codex, targets: [])]),
        selectedAgentID: 1, reportFailure: { _ in }, layoutControl: {}
    )
    .environment(CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory)))
    .frame(width: 650)
}
