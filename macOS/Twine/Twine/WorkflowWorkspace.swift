import OSLog
import SwiftUI

private let workflowLogger = Logger(subsystem: "com.twineproject.Twine", category: "workflows")

/// Every workflow stays mounted, including its output pump and terminal emulator, until it closes.
struct WorkflowWorkspace: View {
    @Environment(BridgeClient.self) private var bridgeClient
    let folder: String
    @State private var selection = WorkflowTabSelection()
    @State private var failureMessage: String?

    private var workflows: [BridgeWorkflow] {
        guard let state = bridgeClient.snapshot?.workflows, state.session?.folder == folder else { return [] }
        return state.workflows
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkflowTabs(
                workflows: workflows,
                selectedID: selection.selectedID,
                select: { selection.selectedID = $0 },
                close: close,
                create: { Task { await create() } }
            )
            ZStack {
                if workflows.isEmpty {
                    ContentUnavailableView(
                        "No Open Tabs", systemImage: "terminal",
                        description: Text("Open a Terminal workflow with + or ⌘T.")
                    )
                }
                ForEach(workflows) { workflow in
                    let isSelected = workflow.id == selection.selectedID
                    TerminalSurface(workflow: workflow, isSelected: isSelected)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.terminalBackground)
            .clipShape(panelShape)
            .overlay(panelShape.stroke(.hairline, lineWidth: Surface.hairlineWidth))
            .terminalPanelShadow()
        }
        .task {
            selection.reconcile(previous: [], current: workflows.map(\.id))
            if workflows.isEmpty { await create() }
        }
        .onChange(of: workflows.map(\.id)) { previous, current in
            selection.reconcile(previous: previous, current: current)
        }
        .focusedSceneValue(
            \.workflowActions,
            WorkflowActions(
                create: { Task { await create() } },
                close: selection.selectedID.map { id in { close(id) } }
            )
        )
        .alert(
            "Workflow Couldn't Start",
            isPresented: Binding(
                get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("OK") { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: CornerRadius.panel) }

    private func create() async {
        do {
            let id = try await bridgeClient.createWorkflow(folder: folder)
            if Task.isCancelled {
                try await bridgeClient.closeWorkflow(workflowID: id)
            } else {
                selection.selectedID = id
            }
        } catch {
            if Task.isCancelled || bridgeClient.snapshot?.folders.openFolder != folder { return }
            failureMessage = error.localizedDescription
            workflowLogger.error("Could not create workflow: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func close(_ id: UInt64) {
        Task {
            do {
                try await bridgeClient.closeWorkflow(workflowID: id)
            } catch {
                if !workflows.contains(where: { $0.id == id }) { return }
                failureMessage = error.localizedDescription
                workflowLogger.error("Could not close workflow: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
