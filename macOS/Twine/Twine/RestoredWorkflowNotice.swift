import SwiftUI

/// Explains process state while the saved terminal output is restored.
struct RestoredWorkflowNotice: View {
    @Environment(TraceTerminalNavigation.self) private var navigation
    let workflow: CoreWorkflow

    var body: some View {
        HStack {
            Label(message, systemImage: "arrow.clockwise")
                .lineLimit(1)
                .help(message)
                .accessibilityIdentifier("restoredWorkflowNotice")
            Spacer(minLength: 0)
            if workflow.kind == .singleAgent && workflow.status != .running {
                ResumeAgentButton(workflow: workflow)
            }
            if let history = workflow.terminalHistory, !history.isEmpty {
                Menu("Saved output", systemImage: "clock.arrow.circlepath") {
                    ForEach(Array(history.enumerated()), id: \.element.terminalID) { index, entry in
                        Button("\(title(for: entry)) · \(index + 1)") {
                            navigation.target = TraceTerminalTarget(
                                workflowID: workflow.id, agentID: entry.agentID,
                                anchor: .init(terminalID: entry.terminalID, byteOffset: 0),
                                timestamp: 0, message: title(for: entry), readToCurrentEnd: true)
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("savedTerminalOutput")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: RestoredNoticeLayout.height)
    }

    private var message: String {
        if workflow.kind == .singleAgent {
            if workflow.status == .running { return "Agent session resumed. Saved output is available." }
            return switch workflow.status {
            case .cancelled: "Saved output · Agent cancelled"
            case .exited, .completed: "Saved output · Agent exited"
            case .failed: "Saved output · Agent failed"
            default: "Saved output · Agent interrupted"
            }
        }
        if workflow.run != nil {
            return workflow.status == .running
                ? "Agent sessions resumed. Saved output is available."
                : "Saved output restored. Agents are stopped."
        }
        let hasAgents = workflow.kind == .agents
        if workflow.terminalIDs.isEmpty {
            return hasAgents
                ? "Restored tab — the shells couldn't restart." : "Restored tab — the shell couldn't restart."
        }
        return hasAgents
            ? "Saved output restored. New shells started."
            : "Saved output restored. New shell started."
    }

    private func title(for entry: CoreWorkflowTerminal) -> String {
        workflow.agents.first { $0.id == entry.agentID }?.role ?? workflow.name
    }
}

extension CoreWorkflow {
    var showsRestoredNotice: Bool {
        restored || (kind == .singleAgent && status != .running)
    }
}
