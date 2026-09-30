import SwiftUI

struct WorkflowRunControls: View {
    @Environment(CoreClient.self) private var client
    let workflowID: UInt64
    let run: CoreWorkflowRun
    let selectedAgentID: UInt64?
    @State private var showsCompletion = false
    @State private var failure: String?
    @State private var showsGraph = false

    private var agent: CoreWorkflowRun.Agent? { run.agents.first { $0.id == selectedAgentID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.stage).fontWeight(.semibold)
                if let agent { Text(agent.harness.displayName).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                if let type = run.workflowType {
                    Button {
                        showsGraph.toggle()
                    } label: {
                        Label(type.definition.name, systemImage: "flowchart")
                    }
                    .accessibilityIdentifier("inspectWorkflowType")
                    .popover(isPresented: $showsGraph) {
                        WorkflowTypeInspector(type: type, run: run)
                    }
                }
                if let agent, agent.active && !agent.done {
                    Button("Mark done…") { showsCompletion = true }
                        .accessibilityIdentifier("workflowMarkDone")
                }
                if run.status == .running {
                    Button("Cancel workflow") {
                        Task {
                            do { try await client.cancelWorkflowRun(workflowID: workflowID) } catch {
                                failure = error.localizedDescription
                            }
                        }
                    }.accessibilityIdentifier("workflowCancel")
                }
            }
            if let message = failure ?? run.message {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .font(.caption).controlSize(.small).padding(.horizontal, 18).padding(.vertical, 6)
        .sheet(isPresented: $showsCompletion) {
            if let agent {
                WorkflowCompletionForm(workflowID: workflowID, generation: run.generation, agent: agent)
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
            generation: 1, stage: "Review", status: .running, message: nil,
            agents: [.init(agentId: 1, active: true, done: false, reviewer: true, harness: .codex, targets: [])]),
        selectedAgentID: 1
    )
    .environment(CoreClient(transport: CoreWorker(dataDirectory: .temporaryDirectory)))
    .frame(width: 650)
}
