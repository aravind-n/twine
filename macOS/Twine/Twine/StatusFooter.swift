import SwiftUI

struct StatusFooter: View {
    let branch: String?
    let workflow: CoreWorkflow?

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
                    if let message = state.message {
                        separator
                        Text(message)
                            .foregroundStyle(Color.statusNeedsAttention)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(message)
                            .accessibilityIdentifier("workflowMessage")
                            .layoutPriority(-1)
                    }
                }
                Spacer(minLength: 0)
                #if DEBUG
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                    if let version, let buildNumber {
                        Text("\(version) (\(buildNumber))")
                            .monospacedDigit()
                            .accessibilityIdentifier("buildNumber")
                            .fixedSize()
                    }
                #endif
            }
            .footerStyle()
            .padding(.horizontal, FooterLayout.horizontalPadding)
            .frame(height: FooterLayout.height)
        }
    }

    private var separator: some View {
        Divider().frame(height: FooterLayout.dividerHeight)
    }

    private func statusColor(for workflow: CoreWorkflow) -> Color {
        switch workflow.status {
        case .running: workflow.kind == .draft ? .secondary : .statusRunning
        case .failed, .interrupted: .statusNeedsAttention
        case .completed, .exited, .cancelled, .closed: .statusComplete
        }
    }
}
