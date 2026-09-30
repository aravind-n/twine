import OSLog
import SwiftUI

private let workflowLogger = Logger(subsystem: "com.twineproject.Twine", category: "workflows")

/// Every workflow stays mounted, including its output pump and terminal emulator, until it closes.
struct WorkflowWorkspace: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(WorkflowLayouts.self) private var layouts
    let folder: String
    @Binding var selection: WorkflowTabSelection
    var isVisible = true
    @State private var failureMessage: String?

    private var allWorkflows: [CoreWorkflow] {
        guard coreClient.snapshot?.folders.openFolder == folder else { return [] }
        return coreClient.snapshot?.workflows.workflows ?? []
    }

    private var sessionID: UInt64? { coreClient.snapshot?.workflows.session?.sessionID }
    private var workflows: [CoreWorkflow] { allWorkflows.filter { $0.sessionID == sessionID } }
    private var selectionKey: [UInt64] { [sessionID ?? 0] + workflows.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            WorkflowTabs(
                workflows: workflows,
                selectedID: selection.selectedID,
                select: { selection.selectedID = $0 },
                close: close,
                cancelAgent: cancelAgent,
                create: { Task { await create() } }
            )
            .zIndex(1)
            ZStack {
                if workflows.isEmpty {
                    ContentUnavailableView(
                        "No Open Tabs", systemImage: "terminal",
                        description: Text("Open a workflow with + or ⌘T.")
                    )
                }
                ForEach(allWorkflows) { workflow in
                    let isSelected = isVisible && workflow.sessionID == sessionID && workflow.id == selection.selectedID
                    WorkflowTerminalSurface(
                        folder: folder, workflow: workflow, isSelected: isSelected,
                        reportFailure: { failureMessage = $0 }
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.terminalBackground)
            .clipShape(panelShape)
            .overlay {
                panelShape.stroke(.hairline, lineWidth: Surface.hairlineWidth)
                    .mask { Rectangle().padding(.top, Surface.hairlineWidth) }
                    .allowsHitTesting(false)
            }
            .terminalPanelShadow()
        }
        .task {
            selection.reconcile(sessionID: sessionID, current: workflows.map(\.id))
            if coreClient.snapshot?.workflows.sessionsInitialized == false { await create() }
        }
        .onChange(of: selectionKey) {
            selection.reconcile(sessionID: sessionID, current: workflows.map(\.id))
        }
        .onChange(of: allWorkflows.map(\.id), initial: true) {
            layouts.removeClosedWorkflows(in: folder, state: coreClient.snapshot?.workflows)
        }
        .focusedSceneValue(
            \.workflowActions,
            WorkflowActions(
                create: { Task { await create() } },
                createAgents: { roles in Task { await create(kind: .agents, roles: roles) } },
                close: selection.selectedID.map { id in { close(id) } },
                cancelAgent: workflows.first(where: { $0.id == selection.selectedID && $0.isRunningAgent })
                    .map { workflow in { cancelAgent(workflow.id) } },
                // Not while a file covers the workflow, whose agents the keys would switch unseen.
                layoutMode: isVisible ? selectedWorkflow.flatMap(layoutMode(for:)) : nil,
                moveFocus: isVisible ? selectedWorkflow.flatMap(focusMover(for:)) : nil
            )
        )
        .alert(
            "Workflow Error",
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

    private var selectedWorkflow: CoreWorkflow? { workflows.first { $0.id == selection.selectedID } }

    /// The workflow's layout mode, when it has agents to arrange.
    private func layoutMode(for workflow: CoreWorkflow) -> Binding<WorkflowLayout.Mode>? {
        guard workflow.showsAgentSubtabs else { return nil }
        return Binding(
            get: { layouts.layout(for: workflow.id, in: folder).mode },
            set: { mode in
                var layout = layouts.layout(for: workflow.id, in: folder)
                layout.mode = mode
                layouts.setLayout(layout, for: workflow.id, in: folder)
            })
    }

    /// Moves the keyboard between the workflow's agents, when it has more than one.
    private func focusMover(for workflow: CoreWorkflow) -> ((Int) -> Void)? {
        guard workflow.showsAgentSubtabs else { return nil }
        return { offset in
            var layout = layouts.layout(for: workflow.id, in: folder)
            layout.moveFocus(by: offset, in: workflow.agents)
            layouts.setLayout(layout, for: workflow.id, in: folder)
        }
    }

    private func create(kind: CoreWorkflow.Kind = .draft, roles: [String] = []) async {
        do {
            let targetSession = sessionID
            let id = try await coreClient.createWorkflow(
                folder: folder, sessionID: targetSession, kind: kind, roles: roles)
            if Task.isCancelled {
                try await coreClient.closeWorkflow(workflowID: id)
            } else if targetSession == sessionID || targetSession == nil {
                selection.selectedID = id
            }
        } catch {
            if Task.isCancelled || coreClient.snapshot?.folders.openFolder != folder { return }
            failureMessage = error.localizedDescription
            workflowLogger.error("Could not create workflow: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelAgent(_ id: UInt64) {
        Task {
            do {
                try await coreClient.cancelAgent(workflowID: id)
            } catch {
                // The agent can end on its own just as Cancel is chosen.
                if (error as? CoreFailure)?.isAgentNotRunning == true { return }
                if !workflows.contains(where: { $0.id == id && $0.isRunningAgent }) { return }
                failureMessage = error.localizedDescription
                workflowLogger.error("Could not cancel agent: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func close(_ id: UInt64) {
        Task {
            do {
                try await coreClient.closeWorkflow(workflowID: id)
            } catch {
                if !workflows.contains(where: { $0.id == id }) { return }
                failureMessage = error.localizedDescription
                workflowLogger.error("Could not close workflow: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
