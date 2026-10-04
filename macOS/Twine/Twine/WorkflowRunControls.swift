import SwiftUI

/// Workflow-wide follow-up mode and run actions, shared by the Tabs and Bento terminal strips.
struct WorkflowRunControls: View {
    @Environment(CoreClient.self) private var client
    let workflowID: UInt64
    let run: CoreWorkflowRun
    let selectedAgentID: UInt64?
    /// The selected agent's role, named in Mark done's tooltip.
    var selectedRole: String?
    let reportFailure: (String) -> Void
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
            if run.agents.count > 1 {
                Button {
                    Task {
                        do {
                            try await client.setWorkflowIndividualMode(
                                workflowID: workflowID, individualMode: !run.individualMode)
                        } catch { reportFailure(error.localizedDescription) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person")
                        Text("Individual mode")
                        Divider().frame(height: 12)
                        Text(run.individualMode ? "On" : "Off").fontWeight(.semibold)
                    }
                    .font(.caption)
                }
                .disabled(!run.canChangeIndividualMode || client.workflowModeChanges[workflowID] != nil)
                .help(
                    !run.canChangeIndividualMode
                        ? "Individual mode is available after the workflow finishes."
                        : run.individualMode
                            ? "On: follow up with each agent individually. Turn Off to allow another workflow cycle."
                            : "Off: a follow-up to a first-stage agent can start another workflow cycle. "
                                + "Turn On to work with agents individually."
                )
                .accessibilityLabel("Individual mode")
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
                .popover(isPresented: $showsGraph) {
                    WorkflowTypeInspector(type: type, run: run)
                        .appZoom()
                }
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
            if run.status == .running || hasLiveAgents {
                Button {
                    Task {
                        do { try await client.cancelWorkflowRun(workflowID: workflowID) } catch {
                            reportFailure(error.localizedDescription)
                        }
                    }
                } label: {
                    Label("Cancel workflow", systemImage: "xmark")
                }
                .help("Cancel workflow")
                .accessibilityIdentifier("workflowCancel")
            }
        }
        .labelStyle(.iconOnly)
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
        selectedAgentID: 1, reportFailure: { _ in }
    )
    .environment(CoreClient(transport: CoreWorker(dataDirectory: .temporaryDirectory)))
    .frame(width: 650)
}
