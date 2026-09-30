import SwiftUI

struct WorkflowRunControls: View {
    @Environment(BridgeClient.self) private var client
    let workflowID: UInt64
    let run: BridgeWorkflowRun
    let selectedAgentID: UInt64?
    @State private var showsCompletion = false
    @State private var failure: String?

    private var agent: BridgeWorkflowRun.Agent? { run.agents.first { $0.id == selectedAgentID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.stage).fontWeight(.semibold)
                if let agent { Text(agent.harness.displayName).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
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
    .environment(BridgeClient(transport: BridgeWorker(dataDirectory: .temporaryDirectory)))
    .frame(width: 650)
}
