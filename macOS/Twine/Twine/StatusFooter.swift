import SwiftUI

struct StatusFooter: View {
    let branch: String?
    let workflow: BridgeWorkflow?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: workflow?.status != .running)) { context in
            HStack(spacing: FooterLayout.spacing) {
                if let branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(branch)
                        .accessibilityIdentifier("gitBranch")
                        .layoutPriority(-1)
                }

                if let workflow {
                    let state = WorkflowFooterState(workflow: workflow, now: context.date)
                    if branch != nil { separator }
                    Text(state.status)
                        .foregroundStyle(statusColor(for: workflow))
                        .accessibilityIdentifier("workflowStatus")
                        .fixedSize()
                    Text(state.elapsed)
                        .monospacedDigit()
                        .accessibilityIdentifier("workflowElapsed")
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .footerStyle()
            .padding(.horizontal, FooterLayout.horizontalPadding)
            .frame(height: FooterLayout.height)
        }
    }

    private var separator: some View {
        Divider().frame(height: FooterLayout.dividerHeight)
    }

    private func statusColor(for workflow: BridgeWorkflow) -> Color {
        switch workflow.status {
        case .running: workflow.kind == .draft ? .secondary : .statusRunning
        case .failed: .statusNeedsAttention
        case .exited, .closed: .statusComplete
        }
    }
}
