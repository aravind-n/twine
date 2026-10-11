import SwiftUI

struct StatusFooter: View {
    let branch: String?
    let workflow: CoreWorkflow?
    let folder: String
    @State private var showsPath = false

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
                Button {
                    showsPath.toggle()
                } label: {
                    Text((folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .frame(height: FooterLayout.height)
                .contentShape(Rectangle())
                .help(folder)
                .accessibilityLabel("Folder location")
                .accessibilityValue(folder)
                .accessibilityIdentifier("folderLocation")
                .layoutPriority(-1)
                .contextMenu { copyPath }
                .popover(isPresented: $showsPath) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Folder location").font(.headline)
                        Text(folder).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        copyPath
                    }
                    .padding().frame(maxWidth: 440).appZoom()
                }
            }
            .footerStyle()
            .padding(.horizontal, FooterLayout.horizontalPadding)
            .frame(height: FooterLayout.height)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("statusFooter")
        }
    }

    private var copyPath: some View {
        Button("Copy Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder, forType: .string)
        }
        .accessibilityIdentifier("copyFolderPath")
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
