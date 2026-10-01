import SwiftUI

/// A run's actions in the terminal strip, as icon buttons: the workflow graph, Mark done for the
/// selected agent, and Cancel. The run's messages appear in the status footer.
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
                    workflowID: workflowID, generation: run.generation, agent: agent, needsTask: run.needsTask)
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
